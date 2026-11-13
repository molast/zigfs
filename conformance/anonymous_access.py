#!/usr/bin/env python3
"""Anonymous prefix access rules against an isolated ZigFS server."""
import base64
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from urllib.error import HTTPError


def run():
    binary = Path('zigfs/zig-out/bin/zigfs').resolve()
    names = ['ZIGFS_ACCESS_KEY', 'ZIGFS_SECRET_KEY', 'ZIGFS_ROOT_USER', 'ZIGFS_ROOT_PASSWORD']
    with tempfile.TemporaryDirectory(prefix='zigfs-root-') as directory:
        root = Path(directory)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        access, secret = 'YamlAccessKey123456', '0123456789012345678901234567890123456789'
        config = root / '.env'
        config.write_text(f'''ZIGFS_ACCESS_KEY={access}
ZIGFS_SECRET_KEY={secret}
ZIGFS_ROOT_USER=file-root
ZIGFS_ROOT_PASSWORD=file-root-password
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_METRICS_ENABLED=false
ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS=1
ZIGFS_DATA_ROOT={root}/data
''')
        process, token = None, ''
        output = (root / 'process.log').open('w')
        base_env = {key: value for key, value in os.environ.items() if not key.startswith('ZIGFS_')}

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        def start(overrides=None, expected_error=None):
            nonlocal process
            process = subprocess.Popen([str(binary), '--env-file', str(config)], env={**base_env, **(overrides or {})}, stdout=output, stderr=output)
            if expected_error:
                assert process.wait(timeout=15) != 0
                assert expected_error in (root / 'process.log').read_text()
                return
            for _ in range(200):
                assert process.poll() is None, 'server unexpectedly exited'
                try:
                    urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close()
                    return
                except OSError:
                    time.sleep(.05)
            raise AssertionError('readiness timeout')

        def api(path, value=None, method=None, bearer=None):
            req = urllib.request.Request(endpoint + '/_admin/v1/' + path, data=None if value is None else json.dumps(value).encode(), headers={'Content-Type':'application/json', 'Authorization':'Bearer ' + (token if bearer is None else bearer)}, method=method)
            with urllib.request.urlopen(req, timeout=10) as response:
                data = response.read()
                return json.loads(data) if data else None

        def login(user, password):
            return api('auth/login', {'username':user, 'password':password}, bearer='')['token']

        def reject(call, status):
            try:
                call()
            except HTTPError as error:
                assert error.code == status
            else:
                raise AssertionError('request unexpectedly succeeded')

        def s3(method, path, key=access, password=secret, payload=b'', extra=None, with_headers=False):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            date, host = stamp[:8], f'127.0.0.1:{port}'
            digest = hashlib.sha256(payload).hexdigest()
            sign_headers = {'host':host,'x-amz-content-sha256':digest,'x-amz-date':stamp,**(extra or {})}
            signed = ';'.join(sorted(sign_headers))
            canonical_headers = ''.join(f'{k}:{sign_headers[k]}\n' for k in sorted(sign_headers))
            parsed = urllib.parse.urlsplit(path)
            query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)), quote_via=urllib.parse.quote)
            canonical = f'{method}\n{parsed.path}\n{query}\n{canonical_headers}\n{signed}\n{digest}'
            scope = f'{date}/us-east-1/s3/aws4_request'
            message = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
            signing = ('AWS4' + password).encode()
            for part in [date,'us-east-1','s3','aws4_request']:
                signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
            headers = {'Host':host,'x-amz-date':stamp,'x-amz-content-sha256':digest,'Authorization':f'AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={signed}, Signature={hmac.new(signing,message.encode(),hashlib.sha256).hexdigest()}'}
            headers.update(extra or {})
            req = urllib.request.Request(endpoint + path, method=method, data=payload if method in ('PUT','POST') else None, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as response:
                body = response.read()
                return (body, response.headers) if with_headers else body

        def anon(method, path, body=None, headers=None, with_headers=False):
            request = urllib.request.Request(endpoint + path, method=method, data=body, headers=headers or {})
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read()
                return (body, response.headers) if with_headers else body

        def policy(access_mode):
            actions = []
            if access_mode != 'writeonly': actions += ['s3:GetObject', 's3:GetObjectVersion']
            if access_mode != 'readonly': actions += ['s3:PutObject', 's3:DeleteObject', 's3:DeleteObjectVersion', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts']
            statements = [{'Effect':'Allow','Principal':'*','Action':actions,'Resource':'arn:aws:s3:::access-test/public/*'}]
            if access_mode != 'writeonly':
                statements.append({'Effect':'Allow','Principal':'*','Action':['s3:ListBucket'],'Resource':'arn:aws:s3:::access-test','Condition':{'StringLike':{'s3:prefix':['public/*']}}})
            if access_mode != 'readonly':
                statements.append({'Effect':'Allow','Principal':'*','Action':['s3:ListBucketMultipartUploads'],'Resource':'arn:aws:s3:::access-test','Condition':{'StringLike':{'s3:prefix':['public/*']}}})
            api('buckets/access-test/policy', {'document':json.dumps({'Version':'2012-10-17','Statement':statements})}, 'PUT')

        try:
            start()
            token = login('file-root', 'file-root-password')
            api('buckets', {'name':'access-test'})
            api('buckets/access-test/configuration', {'block_public_access':False}, 'PATCH')
            s3('PUT', '/access-test/public/file', payload=b'original')
            s3('PUT', '/access-test/private/file', payload=b'secret')
            for mode in ['readonly','writeonly','readwrite']:
                policy(mode)
                if mode != 'writeonly':
                    assert anon('GET','/access-test/public/file')
                    anon('HEAD','/access-test/public/file')
                    assert b'public/file' in anon('GET','/access-test?list-type=2&prefix=public%2F')
                else:
                    reject(lambda: anon('GET','/access-test/public/file'),403)
                    reject(lambda: anon('GET','/access-test?list-type=2&prefix=public%2F'),403)
                reject(lambda: anon('GET','/access-test?list-type=2'),403)
                reject(lambda: anon('GET','/access-test/private/file'),403)
                reject(lambda: anon('PUT','/access-test/private/new', b'bad'),403)
                reject(lambda: anon('DELETE','/access-test/private/file'),403)
                reject(lambda: anon('DELETE','/access-test'),403)
                reject(lambda: anon('PUT','/access-test/public/copied', b'', {'x-amz-copy-source':'/access-test/private/file'}),403)
                if mode != 'readonly':
                    anon('PUT','/access-test/public/new',b'created')
                    assert s3('GET','/access-test/public/new') == b'created'
                    anon('DELETE','/access-test/public/new')
                    reject(lambda: s3('GET','/access-test/public/new'),404)
                else:
                    reject(lambda: anon('PUT','/access-test/public/new',b'bad'),403)
                    reject(lambda: anon('DELETE','/access-test/public/file'),403)
            # Copy checks both source read and destination write permissions.
            anon('PUT','/access-test/public/copied',b'',{'x-amz-copy-source':'/access-test/public/file'})
            assert anon('GET','/access-test/public/copied') == b'original'
            reject(lambda: anon('PUT','/access-test/private/copied',b'',{'x-amz-copy-source':'/access-test/public/file'}),403)
            api('buckets', {'name':'copy-source'})
            s3('PUT','/copy-source/source',payload=b'cross bucket')
            source_policy = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':'*','Action':['s3:GetObject'],'Resource':'arn:aws:s3:::copy-source/source'}]}
            api('buckets/copy-source/policy',{'document':json.dumps(source_policy)},'PUT')
            reject(lambda: anon('PUT','/access-test/public/cross',b'',{'x-amz-copy-source':'/copy-source/source'}),403)
            api('buckets/copy-source/configuration',{'block_public_access':False},'PATCH')
            anon('PUT','/access-test/public/cross',b'',{'x-amz-copy-source':'/copy-source/source'})
            assert anon('GET','/access-test/public/cross') == b'cross bucket'
            source_policy['Statement'].append({'Effect':'Deny','Principal':'*','Action':'s3:GetObject','Resource':'arn:aws:s3:::copy-source/*'})
            api('buckets/copy-source/policy',{'document':json.dumps(source_policy)},'PUT')
            reject(lambda: anon('PUT','/access-test/public/cross',b'',{'x-amz-copy-source':'/copy-source/source'}),403)

            # Multipart lifecycle, source checks for UploadPartCopy and key binding.
            def create(key):
                body = anon('POST','/access-test/'+key+'?uploads=',b'')
                return ET.fromstring(body).find('{*}UploadId').text
            upload = create('public/multi')
            query = '?uploadId='+upload
            reject(lambda: anon('PUT','/access-test/private/multi'+query+'&partNumber=1',b'bad'),403)
            reject(lambda: anon('PUT','/access-test/public/wrong'+query+'&partNumber=1',b'bad'),404)
            _, headers = anon('PUT','/access-test/public/multi'+query+'&partNumber=1',b'multipart data',with_headers=True)
            assert b'<PartNumber>1</PartNumber>' in anon('GET','/access-test/public/multi'+query)
            assert upload.encode() in anon('GET','/access-test?uploads=&prefix=public%2F')
            reject(lambda: anon('GET','/access-test?uploads='),403)
            completion = ('<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>'+headers['ETag']+'</ETag></Part></CompleteMultipartUpload>').encode()
            policy('readonly')
            reject(lambda: anon('POST','/access-test/public/multi'+query,completion),403)
            reject(lambda: anon('POST','/access-test/public/denied?uploads=',b''),403)
            policy('readwrite')
            anon('POST','/access-test/public/multi'+query,completion)
            assert anon('GET','/access-test/public/multi') == b'multipart data'
            upload = create('public/part-copy')
            query = '?uploadId='+upload
            reject(lambda: anon('PUT','/access-test/public/part-copy'+query+'&partNumber=1',b'',{'x-amz-copy-source':'/access-test/private/file'}),403)
            copied = anon('PUT','/access-test/public/part-copy'+query+'&partNumber=1',b'',{'x-amz-copy-source':'/access-test/public/file'})
            etag = ET.fromstring(copied).find('{*}ETag').text
            completion = ('<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>'+etag+'</ETag></Part></CompleteMultipartUpload>').encode()
            anon('POST','/access-test/public/part-copy'+query,completion)
            assert anon('GET','/access-test/public/part-copy') == b'original'
            upload = create('public/abort')
            anon('DELETE','/access-test/public/abort?uploadId='+upload)
            reject(lambda: anon('GET','/access-test/public/abort?uploadId='+upload),404)

            # Bulk deletion reports authorization independently for every object.
            def bulk(bucket, entries, quiet=False, extra=None):
                body = ('<Delete>'+''.join('<Object><Key>'+key+'</Key>'+('<VersionId>'+version+'</VersionId>' if version is not None else '')+'</Object>' for key,version in entries)+('<Quiet>true</Quiet>' if quiet else '')+'</Delete>').encode()
                return ET.fromstring(anon('POST','/'+bucket+'?delete=',body,{'Content-MD5':base64.b64encode(hashlib.md5(body).digest()).decode(),**(extra or {})}))
            s3('PUT','/access-test/public/bulk',payload=b'delete')
            result = bulk('access-test',[('public/bulk',None),('private/file',None)])
            assert result.find('{*}Deleted/{*}Key').text == 'public/bulk'
            assert result.find('{*}Error/{*}Key').text == 'private/file'
            assert s3('GET','/access-test/private/file') == b'secret'
            policy('readonly')
            result = bulk('access-test',[('public/file',None)])
            assert result.find('{*}Error/{*}Code').text == 'AccessDenied'
            policy('readwrite')
            s3('PUT','/access-test?versioning=',payload=b'<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>')
            _, headers = s3('PUT','/access-test/public/version',payload=b'version',with_headers=True)
            version = headers['x-amz-version-id']
            result = bulk('access-test',[('public/version',version)])
            assert result.find('{*}Deleted/{*}VersionId').text == version
            reject(lambda: s3('GET','/access-test/public/version?versionId='+version),404)
            # Legal hold protects explicit version deletion, even with bypass headers.
            _, headers = s3('PUT','/access-test/public/held',payload=b'held',with_headers=True)
            version = headers['x-amz-version-id']
            api('buckets/access-test/legal-hold',{'key':'public/held','version_id':version,'enabled':True},'PATCH')
            result = bulk('access-test',[('public/held',version)],extra={'x-amz-bypass-governance-retention':'true'})
            assert result.find('{*}Error') is not None
            assert s3('GET','/access-test/public/held?versionId='+version) == b'held'
            # Explicit Deny is enforced per item and for copy/upload destinations.
            s3('PUT','/access-test/public/denied',payload=b'keep')
            saved_policy = json.loads(api('buckets/access-test/policy')['document'])
            saved_policy['Statement'].append({'Effect':'Deny','Principal':'*','Action':['s3:PutObject','s3:DeleteObject'],'Resource':'arn:aws:s3:::access-test/public/denied'})
            api('buckets/access-test/policy',{'document':json.dumps(saved_policy)},'PUT')
            reject(lambda: anon('PUT','/access-test/public/denied',b'',{'x-amz-copy-source':'/access-test/public/file'}),403)
            reject(lambda: anon('POST','/access-test/public/denied?uploads=',b''),403)
            result = bulk('access-test',[('public/denied',None),('public/missing',None)],quiet=True)
            assert result.find('{*}Deleted') is None
            assert result.find('{*}Error/{*}Key').text == 'public/denied'
            assert anon('GET','/access-test/public/denied') == b'keep'
            # Both retention modes protect versions from anonymous bulk bypass.
            for mode in ['GOVERNANCE','COMPLIANCE']:
                bucket = 'retained-'+mode.lower()
                api('buckets',{'name':bucket,'object_locking':True})
                api('buckets/'+bucket+'/configuration',{'retention_enabled':True,'retention_mode':mode,'retention_duration_seconds':3600,'block_public_access':False},'PATCH')
                doc = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':'*','Action':['s3:DeleteObjectVersion'],'Resource':'arn:aws:s3:::'+bucket+'/*'}]}
                api('buckets/'+bucket+'/policy',{'document':json.dumps(doc)},'PUT')
                _, headers = s3('PUT','/'+bucket+'/protected',payload=b'retained',with_headers=True)
                version = headers['x-amz-version-id']
                result = bulk(bucket,[('protected',version)],extra={'x-amz-bypass-governance-retention':'true'})
                assert result.find('{*}Error') is not None
                assert s3('GET','/'+bucket+'/protected?versionId='+version) == b'retained'
            # Authenticated bulk deletion still uses IAM and supports versions.
            _, headers = s3('PUT','/access-test/public/signed-bulk',payload=b'signed',with_headers=True)
            version = headers['x-amz-version-id']
            body = ('<Delete><Object><Key>public/signed-bulk</Key><VersionId>'+version+'</VersionId></Object></Delete>').encode()
            result = ET.fromstring(s3('POST','/access-test?delete=',payload=body,extra={'content-md5':base64.b64encode(hashlib.md5(body).digest()).decode()}))
            assert result.find('{*}Deleted/{*}VersionId').text == version
            stop()
            start()
            token = login('file-root', 'file-root-password')
            assert anon('GET','/access-test/public/file') == b'original'
            api('buckets/access-test/configuration', {'block_public_access':True}, 'PATCH')
            reject(lambda: anon('GET','/access-test/public/file'),403)
            reject(lambda: anon('PUT','/access-test/public/new',b'bad'),403)
            api('buckets/access-test/configuration', {'block_public_access':False}, 'PATCH')
            api('buckets/access-test/policy', {'document':json.dumps({'Version':'2012-10-17','Statement':[]})}, 'PUT')
            reject(lambda: anon('GET','/access-test/public/file'),403)
            reject(lambda: anon('PUT','/access-test/public/new',b'bad'),403)
            print('PASS anonymous readonly/writeonly/readwrite, prefix scoping, listing restrictions, copy/part-copy source authorization, multipart lifecycle, per-object bulk/version deletion, legal hold/retention, explicit Deny, authenticated bulk regression, restart, block public access and revocation')
        finally:
            stop()
            output.close()

if __name__ == '__main__':
    run()
