#!/usr/bin/env python3
"""SSE-S3 SDK regression, isolated data and credentials. Requires boto3.
Run after zig build: python conformance/sse_s3.py
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from user_access_keys import free_port


def main():
    with tempfile.TemporaryDirectory(prefix='zigfs-sse-s3-') as directory:
        root = Path(directory)
        port = free_port()
        endpoint = f'http://127.0.0.1:{port}'
        config = root / '.env'
        config.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_ROOT_USER=phase7-admin
ZIGFS_ROOT_PASSWORD=phase7-admin-password
ZIGFS_ADMIN_SESSION_SECRET=phase7-isolated-session-secret-000000000000
''')
        log = (root / 'server.log').open('w')
        process = None

        def start():
            nonlocal process
            process = subprocess.Popen([str(Path('zigfs/zig-out/bin/zigfs').resolve()), '--env-file', str(config)], stdout=log, stderr=log)
            for _ in range(200):
                assert process.poll() is None, 'server exited'
                try:
                    with urllib.request.urlopen(endpoint + '/health/ready', timeout=1) as response:
                        if response.status == 200:
                            return
                except OSError:
                    pass
                time.sleep(.05)
            raise AssertionError('readiness timeout')

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        def encrypted(response):
            assert response['ResponseMetadata']['HTTPHeaders'].get('x-amz-server-side-encryption') == 'AES256', response

        def rejected(code, operation, **kwargs):
            try:
                operation(**kwargs)
            except ClientError as error:
                assert error.response['Error']['Code'] == code, error
            else:
                raise AssertionError('unsupported request accepted')

        try:
            start()
            credentials = root / 'credentials.json'
            subprocess.run(['node', 'conformance/provision.mjs', endpoint, str(credentials)], check=True)
            credential = json.loads(credentials.read_text())
            s3 = boto3.client('s3', endpoint_url=endpoint, region_name='us-east-1',
                aws_access_key_id=credential['access_key'], aws_secret_access_key=credential['secret_key'],
                config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}, retries={'max_attempts': 0},
                              request_checksum_calculation='when_required', response_checksum_validation='when_required'))
            bucket = 'sse-compatibility'
            s3.create_bucket(Bucket=bucket)
            rejected('ServerSideEncryptionConfigurationNotFoundError', s3.get_bucket_encryption, Bucket=bucket)
            body = b'SSE-S3 plaintext must never appear on disk! ' * 130000
            encrypted(s3.put_object(Bucket=bucket, Key='explicit', Body=body, ServerSideEncryption='AES256'))
            encrypted(s3.head_object(Bucket=bucket, Key='explicit'))
            result = s3.get_object(Bucket=bucket, Key='explicit', Range='bytes=1048570-1048600')
            encrypted(result)
            assert result['Body'].read() == body[1048570:1048601]
            s3.put_bucket_encryption(Bucket=bucket, ServerSideEncryptionConfiguration={'Rules': [
                {'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}, 'BucketKeyEnabled': False}]})
            assert s3.get_bucket_encryption(Bucket=bucket)['ServerSideEncryptionConfiguration']['Rules'][0]['ApplyServerSideEncryptionByDefault']['SSEAlgorithm'] == 'AES256'
            rejected('AccessDenied', s3.get_bucket_encryption, Bucket=bucket, ExpectedBucketOwner='wrong-owner')
            url = s3.generate_presigned_url('get_bucket_encryption', Params={'Bucket': bucket})
            with urllib.request.urlopen(url) as response:
                assert b'AES256' in response.read()
            encrypted(s3.put_object(Bucket=bucket, Key='default', Body=body))
            encrypted(s3.copy_object(Bucket=bucket, Key='copy', CopySource={'Bucket': bucket, 'Key': 'explicit'}))
            encrypted(s3.copy_object(Bucket=bucket, Key='explicit', CopySource={'Bucket': bucket, 'Key': 'explicit'}, ServerSideEncryption='AES256', MetadataDirective='REPLACE'))
            upload = s3.create_multipart_upload(Bucket=bucket, Key='multipart')
            encrypted(upload)
            upload_id = upload['UploadId']
            part = s3.upload_part(Bucket=bucket, Key='multipart', UploadId=upload_id, PartNumber=1, Body=body)
            encrypted(part)
            last = s3.upload_part(Bucket=bucket, Key='multipart', UploadId=upload_id, PartNumber=2, Body=b'last-part')
            encrypted(last)
            encrypted(s3.list_parts(Bucket=bucket, Key='multipart', UploadId=upload_id))
            for path in (root / 'data').rglob('*.data'):
                assert body[:128] not in path.read_bytes(), f'plaintext at {path.relative_to(root)}'
            s3.delete_bucket_encryption(Bucket=bucket)
            stop()
            start()
            rejected('ServerSideEncryptionConfigurationNotFoundError', s3.get_bucket_encryption, Bucket=bucket)
            encrypted(s3.complete_multipart_upload(Bucket=bucket, Key='multipart', UploadId=upload_id,
                MultipartUpload={'Parts': [{'PartNumber': 1, 'ETag': part['ETag']}, {'PartNumber': 2, 'ETag': last['ETag']}]}))
            for key in ['explicit', 'default', 'copy', 'multipart']:
                result = s3.get_object(Bucket=bucket, Key=key)
                encrypted(result)
                assert result['Body'].read() == (body + b'last-part' if key == 'multipart' else body)
            encrypted(s3.put_object(Bucket=bucket, Key='empty', Body=b'', ServerSideEncryption='AES256'))
            empty = s3.get_object(Bucket=bucket, Key='empty')
            encrypted(empty)
            assert empty['Body'].read() == b''
            s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status': 'Enabled'})
            version = s3.put_object(Bucket=bucket, Key='versioned', Body=b'encrypted-version', ServerSideEncryption='AES256')['VersionId']
            s3.put_object(Bucket=bucket, Key='versioned', Body=b'plain-version')
            old = s3.get_object(Bucket=bucket, Key='versioned', VersionId=version)
            encrypted(old)
            assert old['Body'].read() == b'encrypted-version'
            assert 'ServerSideEncryption' not in s3.head_object(Bucket=bucket, Key='versioned')
            def invalid_read_header(request, **kwargs):
                request.headers['x-amz-server-side-encryption'] = 'AES256'
            s3.meta.events.register('before-sign.s3.GetObject', invalid_read_header)
            try:
                rejected('InvalidArgument', s3.get_object, Bucket=bucket, Key='explicit')
            finally:
                s3.meta.events.unregister('before-sign.s3.GetObject', invalid_read_header)
            result = s3.put_object(Bucket=bucket, Key='disabled', Body=b'plain')
            assert 'ServerSideEncryption' not in result
            upload = s3.create_multipart_upload(Bucket=bucket, Key='part-copy', ServerSideEncryption='AES256')
            encrypted(upload)
            copied = s3.upload_part_copy(Bucket=bucket, Key='part-copy', UploadId=upload['UploadId'], PartNumber=1,
                CopySource={'Bucket': bucket, 'Key': 'explicit'})
            encrypted(copied)
            encrypted(s3.complete_multipart_upload(Bucket=bucket, Key='part-copy', UploadId=upload['UploadId'],
                MultipartUpload={'Parts': [{'PartNumber': 1, 'ETag': copied['CopyPartResult']['ETag']}]}))
            rejected('ServiceUnavailable', s3.put_object, Bucket=bucket, Key='kms', Body=b'x', ServerSideEncryption='aws:kms')
            rejected('ServiceUnavailable', s3.put_bucket_encryption, Bucket=bucket, ServerSideEncryptionConfiguration={'Rules': [{'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'aws:kms'}}]})
            s3.delete_bucket_encryption(Bucket=bucket)
            rejected('NotImplemented', s3.put_object, Bucket=bucket, Key='customer', Body=b'x', SSECustomerAlgorithm='AES256', SSECustomerKey=b'x'*32)
            # A signed browser POST policy must cover the encryption field.
            post = s3.generate_presigned_post(bucket, 'form', Fields={'x-amz-server-side-encryption': 'AES256'},
                Conditions=[{'x-amz-server-side-encryption': 'AES256'}])
            boundary = 'zigfs-sse-test-boundary'
            form = bytearray()
            for name, value in post['fields'].items():
                form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
            form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.txt"\r\nContent-Type: text/plain\r\n\r\n'.encode())
            form.extend(b'form-encrypted-body\r\n' + f'--{boundary}--\r\n'.encode())
            with urllib.request.urlopen(urllib.request.Request(post['url'], data=form,
                headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})) as response:
                assert response.headers['x-amz-server-side-encryption'] == 'AES256'
            result = s3.get_object(Bucket=bucket, Key='form')
            encrypted(result)
            assert result['Body'].read() == b'form-encrypted-body'
            def management(path, payload, token=None):
                headers = {'Content-Type': 'application/json'}
                if token:
                    headers['Authorization'] = 'Bearer ' + token
                with urllib.request.urlopen(urllib.request.Request(endpoint + '/_admin/v1' + path,
                        data=json.dumps(payload).encode(), headers=headers)) as response:
                    return json.load(response)
            token = management('/auth/login', {'username': 'phase7-admin', 'password': 'phase7-admin-password'})['token']
            restricted = management('/access-keys', {'owner': credential['owner'], 'policy_document': json.dumps({
                'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': 's3:GetEncryptionConfiguration',
                    'Resource': 'arn:aws:s3:::' + bucket}]})}, token)
            reader = boto3.client('s3', endpoint_url=endpoint, region_name='us-east-1',
                aws_access_key_id=restricted['access_key'], aws_secret_access_key=restricted['secret_key'],
                config=Config(signature_version='s3v4', retries={'max_attempts': 0}))
            rejected('ServerSideEncryptionConfigurationNotFoundError', reader.get_bucket_encryption, Bucket=bucket)
            rejected('AccessDenied', reader.delete_bucket_encryption, Bucket=bucket)
            rejected('AccessDenied', reader.put_bucket_encryption, Bucket=bucket,
                ServerSideEncryptionConfiguration={'Rules': [{'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}}]})
            print('PASS: SSE-S3 bucket API, PUT/HEAD/GET/Range, copy, multipart, encrypted staging, restart, POST policy, presigning, IAM/owner checks, unconfigured KMS/SSE-C rejection')
        finally:
            stop()
            log.close()


if __name__ == '__main__':
    main()
