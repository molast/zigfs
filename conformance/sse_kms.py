#!/usr/bin/env python3
"""Isolated SSE-KMS SDK regression. Requires boto3; Vault HTTP contract fixture included."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.request
from urllib.error import HTTPError
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

class Vault(BaseHTTPRequestHandler):
    values = {}
    managed = {}
    version = 1
    requests = []
    unavailable = False
    def log_message(self, *args): pass
    def do_DELETE(self): self.handle_request(None)
    def do_GET(self): self.handle_request(None)
    def do_POST(self): self.handle_request(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
    def handle_request(self, body):
        Vault.requests.append(self.path)
        assert self.headers['X-Vault-Token'] == 'isolated-vault-token'
        assert self.headers['X-Vault-Namespace'] == 'test'
        if Vault.unavailable:
            self.send_response(503); self.end_headers(); return
        if self.path.startswith('/v1/transit/encrypt/'):
            ciphertext = 'vault:v1:' + secrets.token_hex(24)
            Vault.values[ciphertext] = body['plaintext']
            data = {'ciphertext': ciphertext}
        elif self.path.startswith('/v1/transit/decrypt/'):
            data = {'plaintext': Vault.values[body['ciphertext']]}
        elif self.path.startswith('/v1/transit/keys'):
            parts=self.path.split('?')[0].strip('/').split('/')
            name=parts[3] if len(parts)>3 else ''
            if '?list=true' in self.path: data={'keys':['test-key']+[key for backend,key in Vault.managed if backend=='vault']}
            elif self.command=='DELETE':
                Vault.managed.pop(('vault',name),None); self.send_response(204);self.end_headers();return
            elif self.command=='POST':
                item=Vault.managed.setdefault(('vault',name),{'version':1})
                if parts[-1]=='rotate':item['version']+=1
                self.send_response(204);self.end_headers();return
            else: data={'latest_version':Vault.managed.get(('vault',name),{'version':1})['version']}
        elif self.path.startswith('/v1/secret/metadata/zigfs/kms/keys/'):
            name=self.path.split('?')[0].split('/')[-1]
            if '?list=true' in self.path:data={'keys':['test-key']+[key for backend,key in Vault.managed if backend=='vault-kv2']}
            elif self.command=='DELETE':
                Vault.managed.pop(('vault-kv2',name),None);self.send_response(204);self.end_headers();return
            else:data={'current_version':Vault.managed.get(('vault-kv2',name),{'version':Vault.version})['version'],'created_time':'2026-11-10T00:00:00Z'}
        elif self.path.startswith('/v1/secret/data/zigfs/kms/keys/'):
            name=self.path.split('?')[0].split('/')[-1]
            item=Vault.managed.get(('vault-kv2',name))
            if self.command=='POST':
                current=item['version'] if item else 0
                assert body['options']['cas']==current
                if item is None:item={'version':0,'keys':{}};Vault.managed[('vault-kv2',name)]=item
                item['version']+=1;item['keys'][item['version']]=body['data']['key']
                data={'version':item['version']}
            else:
                version = int(self.path.split('?version=')[1]) if '?version=' in self.path else (item['version'] if item else Vault.version)
                data = {'data': {'key': item['keys'][version] if item else base64.b64encode(bytes([version]) * 32).decode()}, 'metadata': {'version': version}}
        else:
            self.send_response(404); self.end_headers(); return
        payload = json.dumps({'data': data}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)

def port():
    with socket.socket() as s: s.bind(('127.0.0.1', 0)); return s.getsockname()[1]

def run():
    with tempfile.TemporaryDirectory(prefix='zigfs-kms-') as directory:
        root = Path(directory)
        endpoint = f'http://127.0.0.1:{port()}'
        vault = ThreadingHTTPServer(('127.0.0.1', 0), Vault)
        threading.Thread(target=vault.serve_forever, daemon=True).start()
        config = root / 'config.yaml'
        config.write_text(f'''server:
  api_address: {endpoint[7:]}
observability:
  metrics_enabled: false
storage:
  data_root: {root}/data
s3:
  public_endpoint: {endpoint}
admin:
  username: phase7-admin
  password: phase7-admin-password
  session_secret: phase7-isolated-session-secret-000000000000
''')
        log = (root / 'server.log').open('w')
        process = None
        tls_vault = None
        def start():
            nonlocal process
            process = subprocess.Popen([str(Path('zigfs/zig-out/bin/zigfs').resolve()), '--config', str(config)], stdout=log, stderr=log, env={**os.environ, 'ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS':'true'})
            for _ in range(200):
                if process.poll() is not None: raise AssertionError((root / 'server.log').read_text())
                try:
                    urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close(); return
                except OSError: time.sleep(.05)
            raise AssertionError('readiness timeout')
        def stop():
            if process and process.poll() is None: process.terminate(); process.wait(timeout=15)
        token = ''
        def api(path, body=None, method=None):
            request = urllib.request.Request(endpoint + '/_admin/v1/' + path, data=json.dumps(body).encode() if body is not None else None,
                method=method, headers={'content-type':'application/json', 'authorization': 'Bearer '+token})
            with urllib.request.urlopen(request, timeout=20) as response: return json.load(response)
        def save(backend, **changes):
            value = dict(backend=backend, defaultKey='test-key', staticSecretKey='', localKeyDirectory='/data/test', filePermissions='384', localCacheEnabled=False,
                address=f'http://127.0.0.1:{vault.server_port}', token='isolated-vault-token', namespace='test', mountPath='transit', kvMount='secret', keyPathPrefix='zigfs/kms/keys/',
                skipTlsVerification=False, caCertificatePath='', clientCertificatePath='', clientKeyPath='', timeoutSeconds='2', retryCount='1', cacheEnabled=False, cacheTtlSeconds='60', cacheCapacity='10')
            if backend == 'static': value['staticSecretKey'] = base64.b64encode(b'K'*32).decode()
            value.update(changes)
            requests_before = len(Vault.requests)
            result = api('settings/kms', value, 'PUT')
            assert len(Vault.requests) == requests_before
            assert not result['healthChecked'] and result['state']=='configured' and not result['errorMessage']
            assert result['configured'] and result['config']['token'] == '' and result['config']['staticSecretKey'] == ''
            return result
        def encrypted(response):
            assert response['ServerSideEncryption'] == 'aws:kms', response
            assert response['SSEKMSKeyId'] == 'test-key', response
        try:
            start()
            token = api('auth/login', {'username':'phase7-admin','password':'phase7-admin-password'})['token']
            credentials = api('access-keys', {'owner':'kms-sdk'})
            s3 = boto3.client('s3', endpoint_url=endpoint, region_name='us-east-1', aws_access_key_id=credentials['access_key'], aws_secret_access_key=credentials['secret_key'],
                config=Config(signature_version='s3v4', s3={'addressing_style':'path'}, retries={'max_attempts':0}, request_checksum_calculation='when_required', response_checksum_validation='when_required'))
            assert not api('settings/kms')['configured']
            bucket = 'kms-conformance'; s3.create_bucket(Bucket=bucket)
            # A running backend exposes usable keys without a configured default.
            save('local', defaultKey='')
            api('settings/kms/start', {}, 'POST')
            probe='zigfs-internal-kms-probe'
            assert api('settings/kms')['config']['defaultKey']==''
            assert any(key['id']==probe and key['status']=='Enabled' for key in api('settings/kms/keys')['items'])
            api(f'buckets/{bucket}/configuration', {'encryption':'KMS','kms_key_id':probe}, 'PATCH')
            response=s3.put_object(Bucket=bucket,Key='probe-selected',Body=b'without-default')
            assert response['SSEKMSKeyId']==probe
            assert s3.get_object(Bucket=bucket,Key='probe-selected')['Body'].read()==b'without-default'
            print('PASS running KMS without default: list, select existing key and encrypt/decrypt',flush=True)
            expected = {}
            for backend in ['local','static','vault-kv2','vault']:
                save(backend)
                try: s3.put_object(Bucket=bucket,Key='not-started',Body=b'no',ServerSideEncryption='aws:kms')
                except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode']==503
                else: raise AssertionError('unstarted KMS accepted write')
                stored_config = root/'data'/'.zigfs'/'config'/'kms_config.json'/'xl.meta'
                stored_bytes = stored_config.read_bytes()
                started = api('settings/kms/start', {}, 'POST')
                assert started['state']=='running' and started['healthy']
                assert stored_config.read_bytes()!=stored_bytes
                s3.put_bucket_encryption(Bucket=bucket, ServerSideEncryptionConfiguration={'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'aws:kms'}}]})
                payload = (f'{backend}-confidential-data!'.encode()) * 10000
                encrypted(s3.put_object(Bucket=bucket, Key=backend, Body=payload, ServerSideEncryption='aws:kms'))
                expected[backend] = payload
                encrypted(s3.head_object(Bucket=bucket, Key=backend))
                result = s3.get_object(Bucket=bucket, Key=backend, Range='bytes=13-57'); encrypted(result); assert result['Body'].read() == payload[13:58]
                encrypted(s3.copy_object(Bucket=bucket, Key=backend+'-copy', CopySource={'Bucket':bucket,'Key':backend}, ServerSideEncryption='aws:kms'))
                expected[backend+'-copy'] = payload
                upload = s3.create_multipart_upload(Bucket=bucket, Key=backend+'-parts', ServerSideEncryption='aws:kms'); encrypted(upload)
                part = s3.upload_part(Bucket=bucket, Key=backend+'-parts', UploadId=upload['UploadId'], PartNumber=1, Body=payload); encrypted(part)
                # Configuration changes must not alter an in-flight upload's KMS profile.
                save('static', staticSecretKey=base64.b64encode(b'Z'*32).decode())
                api('settings/kms/start', {}, 'POST')
                encrypted(s3.complete_multipart_upload(Bucket=bucket, Key=backend+'-parts', UploadId=upload['UploadId'], MultipartUpload={'Parts':[{'PartNumber':1,'ETag':part['ETag']}]}))
                expected[backend+'-parts'] = payload
                print('PASS', backend, 'PUT, HEAD, range, COPY and multipart configuration snapshot', flush=True)
            # Bucket key overrides platform default across all write paths and restart.
            save('local')
            api('settings/kms/start', {}, 'POST')
            selected = api('settings/kms/keys', {'name':'bucket-selected-key'})['id']
            setting = {'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'aws:kms','KMSMasterKeyID':selected}}]}
            s3.put_bucket_encryption(Bucket=bucket, ServerSideEncryptionConfiguration=setting)
            assert s3.get_bucket_encryption(Bucket=bucket)['ServerSideEncryptionConfiguration']==setting
            bucket_path=f'buckets/{bucket}/configuration'
            assert api(bucket_path)['kms_key_id']==selected
            api(bucket_path, {'tags_json':'{"purpose":"kms-test"}'}, 'PATCH')
            assert api(bucket_path)['kms_key_id']==selected
            assert s3.put_object(Bucket=bucket,Key='selected',Body=b'selected')['SSEKMSKeyId']==selected
            assert s3.copy_object(Bucket=bucket,Key='selected-copy',CopySource={'Bucket':bucket,'Key':'selected'})['SSEKMSKeyId']==selected
            upload=s3.create_multipart_upload(Bucket=bucket,Key='selected-parts')
            assert upload['SSEKMSKeyId']==selected
            part=s3.upload_part(Bucket=bucket,Key='selected-parts',UploadId=upload['UploadId'],PartNumber=1,Body=b'part')
            assert s3.complete_multipart_upload(Bucket=bucket,Key='selected-parts',UploadId=upload['UploadId'],MultipartUpload={'Parts':[{'PartNumber':1,'ETag':part['ETag']}]})['SSEKMSKeyId']==selected
            assert s3.put_object(Bucket=bucket,Key='explicit-default',Body=b'explicit',ServerSideEncryption='aws:kms')['SSEKMSKeyId']=='test-key'
            assert s3.put_object(Bucket=bucket,Key='explicit-s3',Body=b'explicit',ServerSideEncryption='AES256')['ServerSideEncryption']=='AES256'
            post=s3.generate_presigned_post(bucket,'selected-form')
            boundary='selected-key-form'; form=bytearray()
            for name,value in post['fields'].items():
                form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
            form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.txt"\r\n\r\nform-data\r\n--{boundary}--\r\n'.encode())
            with urllib.request.urlopen(urllib.request.Request(post['url'],data=form,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})) as response:
                assert response.headers['x-amz-server-side-encryption-aws-kms-key-id']==selected
            stop();start()
            assert api(bucket_path)['kms_key_id']==selected
            assert s3.put_object(Bucket=bucket,Key='selected-restarted',Body=b'restart')['SSEKMSKeyId']==selected
            assert s3.get_object(Bucket=bucket,Key='selected')['Body'].read()==b'selected'
            api(bucket_path, {'encryption':'Enabled'}, 'PATCH')
            assert api(bucket_path)['kms_key_id']==''
            api(bucket_path, {'encryption':'KMS','kms_key_id':selected}, 'PATCH')
            assert s3.get_bucket_encryption(Bucket=bucket)['ServerSideEncryptionConfiguration']==setting
            print('PASS bucket selected key, XML/management roundtrip, PUT/COPY/multipart/POST, explicit overrides and restart',flush=True)
            Vault.version = 2
            save('vault-kv2')
            api('settings/kms/start', {}, 'POST')
            s3.put_bucket_encryption(Bucket=bucket, ServerSideEncryptionConfiguration={'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'aws:kms'}}]})
            encrypted(s3.put_object(Bucket=bucket, Key='default', Body=b'bucket-default-kms'))
            expected['default'] = b'bucket-default-kms'
            # Signed browser POST and key-level authorization.
            post=s3.generate_presigned_post(bucket,'form',Fields={'x-amz-server-side-encryption':'aws:kms'},Conditions=[{'x-amz-server-side-encryption':'aws:kms'}])
            boundary='kms-form-boundary'; form=bytearray()
            for name,value in post['fields'].items():
                form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
            form.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.txt"\r\nContent-Type: text/plain\r\n\r\nform-data\r\n--{boundary}--\r\n'.encode())
            with urllib.request.urlopen(urllib.request.Request(post['url'],data=form,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})) as response:
                assert response.headers['x-amz-server-side-encryption']=='aws:kms'
            expected['form']=b'form-data'
            restricted=api('access-keys',{'owner':'kms-sdk','policy_document':json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]})})
            reader=boto3.client('s3',endpoint_url=endpoint,region_name='us-east-1',aws_access_key_id=restricted['access_key'],aws_secret_access_key=restricted['secret_key'],config=Config(signature_version='s3v4',retries={'max_attempts':0},request_checksum_calculation='when_required'))
            for operation,kwargs in [(reader.get_object,dict(Bucket=bucket,Key='default')),(reader.put_object,dict(Bucket=bucket,Key='denied',Body=b'x')),(reader.copy_object,dict(Bucket=bucket,Key='denied-copy',CopySource={'Bucket':bucket,'Key':'default'},ServerSideEncryption='AES256'))]:
                try: operation(**kwargs)
                except ClientError as error: assert error.response['Error']['Code']=='AccessDenied'
                else: raise AssertionError('missing KMS permissions were accepted')
            print('PASS signed POST and KMS permissions on upload/read/copy',flush=True)
            stop(); start()
            assert api('settings/kms')['state']=='running'
            for key, payload in expected.items():
                result = s3.get_object(Bucket=bucket, Key=key); encrypted(result); assert result['Body'].read() == payload, key
            assert any('?version=1' in path for path in Vault.requests)
            print('PASS restart, retained backend profiles, KV2 version pinning and bucket defaults', flush=True)
            assert (root/'data'/'test'/'test-key.key').stat().st_mode & 0o777 == 0o600
            assert len(base64.b64decode(json.loads((root/'data'/'test'/'test-key.key').read_text())['encrypted_key_material'])) == 32
            config_bytes=(root/'data'/'.zigfs'/'config'/'kms_config.json'/'xl.meta').read_bytes()
            assert config_bytes[:4] == b'ZFKM'
            assert int.from_bytes(config_bytes[6:8], 'little') == 2
            assert b'ciphertext' not in config_bytes and b'nonce' not in config_bytes
            assert not (root/'data'/'.zigfs'/'config'/'kms_config.json'/'profiles').exists()
            import hashlib
            assert hashlib.sha256(config_bytes[44:]).digest() == config_bytes[12:44]
            probe=json.loads((root/'data'/'test'/'zigfs-internal-kms-probe.key').read_text())
            assert probe['format_version']==1 and probe['key_id']=='zigfs-internal-kms-probe'
            assert probe['algorithm']=='AES_256' and probe['usage']=='EncryptDecrypt'
            assert probe['status']=='Enabled' and probe['deletion_date'] is None
            assert probe['nonce']==[] and probe['at_rest_protection']=='plaintext-dev-only'
            assert len(base64.b64decode(probe['encrypted_key_material']))==32
            for path in (root/'data').rglob('*'):
                if path.is_file():
                    data=path.read_bytes()
                    assert b'isolated-vault-token' not in data
                    assert base64.b64encode(b'K'*32) not in data
                    assert b'local-confidential-data!' not in data
            # Exercise libcurl's CA validation and client certificate authentication.
            def openssl(*args):
                subprocess.run(['openssl', *map(str,args)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',root/'ca.key','-out',root/'ca.pem','-subj','/CN=KMS Test CA')
            for name in ['server','client']:
                openssl('req','-newkey','rsa:2048','-nodes','-keyout',root/f'{name}.key','-out',root/f'{name}.csr','-subj',f'/CN={name}')
                (root/f'{name}.ext').write_text('subjectAltName=IP:127.0.0.1\nextendedKeyUsage='+('serverAuth' if name=='server' else 'clientAuth')+'\n')
                openssl('x509','-req','-in',root/f'{name}.csr','-CA',root/'ca.pem','-CAkey',root/'ca.key','-CAcreateserial','-out',root/f'{name}.pem','-days','1','-extfile',root/f'{name}.ext')
            tls_vault = ThreadingHTTPServer(('127.0.0.1',0), Vault)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(root/'server.pem',root/'server.key')
            tls.load_verify_locations(root/'ca.pem')
            tls_vault.socket = tls.wrap_socket(tls_vault.socket, server_side=True)
            threading.Thread(target=tls_vault.serve_forever,daemon=True).start()
            https = f'https://127.0.0.1:{tls_vault.server_port}'
            save('vault', address=https)
            try: api('settings/kms/start', {}, 'POST')
            except HTTPError as error: assert error.code==503
            else: raise AssertionError('untrusted TLS started')
            failed = api('settings/kms')
            assert failed['state']=='error' and 'TLS' in failed['errorMessage']
            assert 'isolated-vault-token' not in failed['errorMessage']
            try: s3.put_object(Bucket=bucket, Key='bad-tls', Body=b'no')
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode'] == 503
            else: raise AssertionError('untrusted TLS accepted')
            save('vault', address=https, skipTlsVerification=True)
            assert api('settings/kms/start', {}, 'POST')['state']=='running'
            encrypted(s3.put_object(Bucket=bucket, Key='skip-tls', Body=b'ok'))
            save('vault', address=https, caCertificatePath=str(root/'ca.pem'))
            api('settings/kms/start', {}, 'POST')
            encrypted(s3.put_object(Bucket=bucket, Key='ca-tls', Body=b'ok'))
            tls.verify_mode = ssl.CERT_REQUIRED
            save('vault', address=https, caCertificatePath=str(root/'ca.pem'))
            try: api('settings/kms/start', {}, 'POST')
            except HTTPError as error: assert error.code==503
            else: raise AssertionError('missing client certificate started')
            try: s3.put_object(Bucket=bucket, Key='missing-client-cert', Body=b'no')
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode'] == 503
            else: raise AssertionError('missing client certificate accepted')
            save('vault', address=https, caCertificatePath=str(root/'ca.pem'), clientCertificatePath=str(root/'client.pem'), clientKeyPath=str(root/'client.key'))
            api('settings/kms/start', {}, 'POST')
            encrypted(s3.put_object(Bucket=bucket,Key='mtls',Body=b'mtls-data'))
            assert s3.get_object(Bucket=bucket,Key='mtls')['Body'].read()==b'mtls-data'
            print('PASS TLS trust validation, custom CA, verification override and mutual TLS',flush=True)
            # Cache on/off and expiry use the same current Transit profile.
            save('vault', cacheEnabled=True, cacheTtlSeconds='1')
            api('settings/kms/start', {}, 'POST')
            encrypted(s3.put_object(Bucket=bucket,Key='cached',Body=b'cache-data'))
            assert s3.get_object(Bucket=bucket,Key='cached')['Body'].read()==b'cache-data'
            Vault.unavailable=True
            assert s3.get_object(Bucket=bucket,Key='cached')['Body'].read()==b'cache-data'
            time.sleep(1.1)
            try: s3.get_object(Bucket=bucket,Key='cached')
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode']==503
            else: raise AssertionError('expired cache bypassed unavailable KMS')
            print('PASS Transit DEK cache and TTL, read failure is HTTP 503',flush=True)
            Vault.unavailable = True
            save('vault')
            assert not api('settings/kms')['healthChecked']
            s3.delete_bucket_encryption(Bucket=bucket)
            try: s3.put_bucket_encryption(Bucket=bucket, ServerSideEncryptionConfiguration={'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'aws:kms'}}]})
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode']==503
            else: raise AssertionError('unavailable provider enabled')
            try: s3.get_bucket_encryption(Bucket=bucket)
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode']==404
            else: raise AssertionError('failed enable modified bucket encryption')
            try: s3.put_object(Bucket=bucket, Key='failure', Body=b'must-not-persist', ServerSideEncryption='aws:kms')
            except ClientError as error: assert error.response['ResponseMetadata']['HTTPStatusCode'] == 503
            else: raise AssertionError('failed open')

            Vault.unavailable=False
            for backend in ['local','vault-kv2','vault']:
                save(backend)
                api('settings/kms/start',{},'POST')
                listed=api('settings/kms/keys')
                assert listed['canCreate'] and not listed['canRekey']
                created=api('settings/kms/keys',{'name':'Reports','description':'Managed test key','setAsDefault':True},'POST')
                key_id=created['id']
                assert created['name']=='Reports'
                assert api('settings/kms')['config']['defaultKey']==key_id
                def key_action(action):return api('settings/kms/keys/action',{'id':key_id,'action':action},'POST')
                object_name='managed-'+backend
                s3.put_object(Bucket=bucket,Key=object_name,Body=b'managed-data',ServerSideEncryption='aws:kms')
                key_action('rotate')
                api('settings/kms/clear-cache',{},'POST')
                assert s3.get_object(Bucket=bucket,Key=object_name)['Body'].read()==b'managed-data'
                detail=next(key for key in api('settings/kms/keys')['items'] if key['id']==key_id)
                assert detail['version']==2 and detail['name']=='Reports'
                assert 'encrypted_key_material' not in json.dumps(detail)
                key_action('schedule-deletion')
                try:s3.get_object(Bucket=bucket,Key=object_name)
                except ClientError as error:assert error.response['ResponseMetadata']['HTTPStatusCode']==503
                else:raise AssertionError('pending key still decrypted')
                key_action('cancel-deletion')
                assert s3.get_object(Bucket=bucket,Key=object_name)['Body'].read()==b'managed-data'
                key_action('schedule-deletion')
                key_action('delete')
                assert all(key['id']!=key_id for key in api('settings/kms/keys')['items'])
                try:s3.put_object(Bucket=bucket,Key='deleted-key',Body=b'no',ServerSideEncryption='aws:kms')
                except ClientError as error:assert error.response['ResponseMetadata']['HTTPStatusCode']==503
                else:raise AssertionError('deleted key regenerated')
                stopped=api('settings/kms/stop',{},'POST')
                assert stopped['state']=='configured' and not stopped['healthChecked']
            save('static')
            api('settings/kms/start',{},'POST')
            assert not api('settings/kms/keys')['canCreate']
            try:api('settings/kms/keys',{'name':'unsupported'},'POST')
            except HTTPError as error:assert error.code==409
            else:raise AssertionError('static key creation accepted')
            api('settings/kms/stop',{},'POST')
            stop();start()
            assert api('settings/kms')['state']=='configured'
            api('settings/kms/start',{},'POST')
            stop();start()
            assert api('settings/kms')['state']=='running'
            save('vault')
            api('settings/kms/start',{},'POST')
            Vault.unavailable=True
            stop();start()
            assert api('settings/kms')['state']=='error'
            assert api('settings/kms')['errorMessage']
            Vault.unavailable=False
            stop();start()
            assert api('settings/kms')['state']=='running'
            api('settings/kms/stop',{},'POST')
            requests_before=len(Vault.requests)
            stop();start()
            assert api('settings/kms')['state']=='configured'
            assert len(Vault.requests)==requests_before
            print('PASS persisted running/stopped state and failed startup recovery across process restarts',flush=True)
            print('PASS key listing, create/default, rotate with old reads, cache clear, deletion/restore, tombstones and stop',flush=True)
            print('PASS secrets redacted/encrypted, local permissions, offline saves, enable-time checks, no plaintext fallback', flush=True)
        finally:
            stop(); vault.shutdown(); log.close()
            if tls_vault: tls_vault.shutdown()
if __name__ == '__main__': run()
