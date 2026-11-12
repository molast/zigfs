#!/usr/bin/env python3
"""Isolated segmented multipart durability, integrity and completion benchmark.
Requires boto3. Default payload 128 MiB; --mib 1024 benchmarks 1 GiB.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mib', type=int, default=128)
    parser.add_argument('--part-mib', type=int, default=8)
    parser.add_argument('--concurrency', type=int, default=1)
    parser.add_argument('--check-resume', action='store_true')
    parser.add_argument('--binary', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    args = parser.parse_args()
    assert args.part_mib >= 5 and args.mib >= args.part_mib and args.mib % args.part_mib == 0
    assert 1 <= args.concurrency <= 16
    with tempfile.TemporaryDirectory(prefix='zigfs-segments-') as directory:
        root = Path(directory)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config = root / '.env'
        config.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_ROOT_USER=test-admin
ZIGFS_ROOT_PASSWORD=test-admin-password
ZIGFS_ADMIN_SESSION_SECRET=segmented-test-session-secret-000000000000
''')
        log = (root / 'server.log').open('w')
        process = None
        token = ''

        def api(path, value=None, method=None, auth=True):
            headers = {'Content-Type': 'application/json'}
            if auth:
                headers['Authorization'] = 'Bearer ' + token
            request = urllib.request.Request(endpoint + '/_admin/v1/' + path, headers=headers, data=None if value is None else json.dumps(value).encode(), method=method)
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None

        def start():
            nonlocal process, token
            process = subprocess.Popen([str(args.binary.resolve()), '--env-file', str(config)], stdout=log, stderr=log)
            for _ in range(200):
                assert process.poll() is None, (root / 'server.log').read_text()
                try:
                    urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close()
                    break
                except OSError:
                    time.sleep(.05)
            else:
                raise AssertionError('readiness timeout')
            token = api('auth/login', {'username': 'test-admin', 'password': 'test-admin-password'}, auth=False)['token']

        def stop(kill=False):
            if process and process.poll() is None:
                process.kill() if kill else process.terminate()
                process.wait(timeout=15)

        def rejected(fn, code):
            try:
                fn()
            except ClientError as error:
                assert error.response['Error']['Code'] == code, error
            else:
                raise AssertionError('operation should fail: ' + code)

        try:
            start()
            credentials = api('access-keys', {'owner': 'compose'})
            s3 = boto3.client('s3', endpoint_url=endpoint, region_name='us-east-1', aws_access_key_id=credentials['access_key'], aws_secret_access_key=credentials['secret_key'], config=Config(signature_version='s3v4', retries={'max_attempts': 0}, request_checksum_calculation='when_required', response_checksum_validation='when_required', read_timeout=120))
            bucket = 'compose-test'
            s3.create_bucket(Bucket=bucket)
            s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status': 'Enabled'})
            block = b'abcdefgh' * (args.part_mib * 1024 * 1024 // 8)
            for encrypted in (False, True):
                key = 'encrypted' if encrypted else 'plain'
                count = 2 if encrypted else args.mib // args.part_mib
                upload = s3.create_multipart_upload(Bucket=bucket, Key=key, **({'ServerSideEncryption': 'AES256'} if encrypted else {}))['UploadId']
                upload_start = time.monotonic()
                def upload_part(index):
                    response = s3.upload_part(Bucket=bucket, Key=key, UploadId=upload, PartNumber=index + 1, Body=block)
                    return {'PartNumber': index + 1, 'ETag': response['ETag']}
                with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
                    parts = list(executor.map(upload_part, range(count)))
                upload_seconds = time.monotonic() - upload_start
                directory = root / 'data/multipart' / upload[:2] / upload
                source_files = list(directory.rglob('data'))
                before = {path.stat().st_ino for path in source_files}
                assert len(list(directory.rglob('part.meta'))) == count
                for path in directory.rglob('part.meta'):
                    raw = path.read_bytes()
                    assert raw[:8] == b'ZFPART01' and hashlib.sha256(raw[40:]).digest() == raw[8:40]
                # Upload records and checksums must survive abrupt shutdown.
                stop(kill=True)
                start()
                begin = time.monotonic()
                result = s3.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload, MultipartUpload={'Parts': parts})
                elapsed = time.monotonic() - begin
                version = result['VersionId']
                print(f'{key}: {count * args.part_mib} MiB, {count} parts, concurrency={args.concurrency}, upload={upload_seconds:.3f}s ({count * args.part_mib / upload_seconds:.1f} MiB/s) complete={elapsed:.3f}s', flush=True)
                published = [path for path in (root / 'data/objects').rglob('part-*') if path.is_file() and path.stat().st_ino in before]
                assert len(published) == count, 'completion must reuse the existing file inodes'
                assert not directory.exists(), 'completed upload temporary data should be cleaned'
                again = s3.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload, MultipartUpload={'Parts': parts})
                assert again['VersionId'] == version
                wrong = [dict(item) for item in parts]
                wrong[0]['ETag'] = '"00000000000000000000000000000000"'
                rejected(lambda: s3.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload, MultipartUpload={'Parts': wrong}), 'InvalidPart')
                stop(kill=True)
                start()
                again = s3.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload, MultipartUpload={'Parts': parts})
                assert again['VersionId'] == version
                versions = s3.list_object_versions(Bucket=bucket, Prefix=key)['Versions']
                assert len([v for v in versions if v['Key'] == key]) == 1
                start_byte = len(block) - 5
                response = s3.get_object(Bucket=bucket, Key=key, Range=f'bytes={start_byte}-{start_byte + 13}')
                assert response['Body'].read() == (block + block)[start_byte:start_byte + 14]
                if encrypted:
                    assert response['ServerSideEncryption'] == 'AES256'
                    for path in published:
                        assert block[:128] not in path.read_bytes()
                download_start = time.monotonic()
                read = s3.get_object(Bucket=bucket, Key=key)['Body']
                digest = hashlib.sha256()
                while chunk := read.read(1024 * 1024):
                    digest.update(chunk)
                expected = hashlib.sha256()
                for _ in range(count):
                    expected.update(block)
                assert digest.digest() == expected.digest()
                download_seconds = time.monotonic() - download_start
                if args.check_resume:
                    # Close a response mid-stream, then request the remainder
                    # from a non-part-aligned offset, retaining the version.
                    prefix_size = len(block) + 17
                    interrupted = s3.get_object(Bucket=bucket, Key=key, VersionId=version)['Body']
                    prefix = interrupted.read(prefix_size)
                    interrupted.close()
                    assert len(prefix) == prefix_size
                    resumed_start = time.monotonic()
                    resumed = s3.get_object(Bucket=bucket, Key=key, VersionId=version, Range=f'bytes={prefix_size}-')
                    assert resumed['ResponseMetadata']['HTTPStatusCode'] == 206
                    assert resumed['ContentRange'] == f'bytes {prefix_size}-{count * len(block) - 1}/{count * len(block)}'
                    assert resumed['ETag'] == result['ETag']
                    resumed_digest = hashlib.sha256(prefix)
                    resumed_bytes = 0
                    while chunk := resumed['Body'].read(1024 * 1024):
                        resumed_digest.update(chunk)
                        resumed_bytes += len(chunk)
                    resumed_seconds = time.monotonic() - resumed_start
                    assert resumed_bytes == count * len(block) - prefix_size
                    assert resumed_digest.digest() == expected.digest()
                    print(f'{key} download: full={count * len(block) / download_seconds / 1024**2:.1f} MiB/s, resumed={resumed_bytes / resumed_seconds / 1024**2:.1f} MiB/s, Range=206, content verified', flush=True)
                s3.copy_object(Bucket=bucket, Key=key + '-copy', CopySource={'Bucket': bucket, 'Key': key})
                assert s3.get_object(Bucket=bucket, Key=key + '-copy', Range='bytes=3-9')['Body'].read() == block[3:10]
                s3.delete_object(Bucket=bucket, Key=key, VersionId=version)
                assert s3.get_object(Bucket=bucket, Key=key + '-copy', Range='bytes=0-7')['Body'].read() == block[:8]
            # Corrupted metadata must fail completion and keep upload resumable.
            upload = s3.create_multipart_upload(Bucket=bucket, Key='corrupt')['UploadId']
            response = s3.upload_part(Bucket=bucket, Key='corrupt', UploadId=upload, PartNumber=1, Body=b'good')
            folder = root / 'data/multipart' / upload[:2] / upload
            meta = next(folder.rglob('part.meta'))
            meta.write_bytes(b'broken')
            rejected(lambda: s3.complete_multipart_upload(Bucket=bucket, Key='corrupt', UploadId=upload, MultipartUpload={'Parts': [{'PartNumber': 1, 'ETag': response['ETag']}]}), 'InternalError')
            assert len(s3.list_parts(Bucket=bucket, Key='corrupt', UploadId=upload)['Parts']) == 1
            s3.abort_multipart_upload(Bucket=bucket, Key='corrupt', UploadId=upload)
            print('PASS segments, shared inodes, restart, idempotence, Range, checksums, encryption, copy, deletion and metadata rejection', flush=True)
        except Exception:
            print((root / 'server.log').read_text()[-6000:])
            raise
        finally:
            stop()
            log.close()


if __name__ == '__main__':
    main()
