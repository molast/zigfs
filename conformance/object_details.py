#!/usr/bin/env python3
"""Object details: presigned HEAD, version tags, copy restore and legal hold."""
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

        def signed(method, version=None, **options):
            return api('objects/presign', {'bucket':'details-test','key':'photo.png','method':method,'expires_seconds':900,**({'version_id':version} if version is not None else {}),**options})

        def send_signed(value, method='GET', body=None):
            with urllib.request.urlopen(urllib.request.Request(value['url'],method=method,data=body,headers=value['required_headers']),timeout=10) as response:
                return response.read(), response.headers

        try:
            start()
            token = login('file-root', 'file-root-password')
            api('buckets', {'name':'details-test'})
            s3('PUT','/details-test/photo.png',payload=b'first-image',extra={'content-type':'image/png','x-amz-meta-team':'blue'})
            versions = api('buckets/details-test/versions')['items']
            assert len(versions)==1 and versions[0]['version_id']=='null'
            head = signed('HEAD')
            body, headers = send_signed(head,'HEAD')
            assert body==b'' and headers['Content-Type']=='image/png'
            assert headers['x-amz-meta-team']=='blue' and headers['Content-Length']=='11'
            assert headers['Access-Control-Expose-Headers']=='*'
            reject(lambda: send_signed(head,'GET'),403)
            reject(lambda: signed('HEAD',tagging=True),400)
            api('buckets/details-test/configuration', {'versioning':'Enabled'}, 'PATCH')
            s3('PUT','/details-test/photo.png',payload=b'second-image')
            versions = api('buckets/details-test/versions')['items']
            assert len(versions)==2 and sum(v['is_latest'] for v in versions)==1
            current=next(v['version_id'] for v in versions if v['is_latest'])
            assert current!='null'
            tagbody=b'<Tagging><TagSet><Tag><Key>team</Key><Value>a&amp;b</Value></Tag></TagSet></Tagging>'
            _,tag_headers=send_signed(signed('PUT','null',tagging=True),'PUT',tagbody)
            assert tag_headers['Access-Control-Allow-Origin']=='*'
            data,_=send_signed(signed('GET','null',tagging=True))
            assert ET.fromstring(data).find('.//{*}Value').text=='a&b'
            data,_=send_signed(signed('GET',current,tagging=True))
            assert not ET.fromstring(data).findall('.//{*}Tag')
            _,tag_headers=send_signed(signed('DELETE','null',tagging=True),'DELETE')
            assert tag_headers['Access-Control-Allow-Origin']=='*'
            # Restore is CopyObject from null, never removing either prior version.
            data,_=send_signed(signed('PUT',copy_source_bucket='details-test',copy_source_key='photo.png',copy_source_version_id='null'),'PUT',b'')
            assert ET.fromstring(data).tag.endswith('CopyObjectResult')
            versions = api('buckets/details-test/versions')['items']
            assert len(versions)==3
            latest=next(v for v in versions if v['is_latest'])
            assert latest['version_id'] not in ('null',current)
            link=signed('GET')
            params=urllib.parse.parse_qs(urllib.parse.urlsplit(link['url']).query)
            for name,value in {'X-Amz-Algorithm':'AWS4-HMAC-SHA256','X-Amz-Content-Sha256':'UNSIGNED-PAYLOAD','X-Amz-Expires':'900','X-Amz-SignedHeaders':'host','x-amz-checksum-mode':'ENABLED','x-id':'GetObject'}.items():
                assert params[name]==[value], name
            assert params['X-Amz-Credential'][0].endswith('/us-east-1/s3/aws4_request')
            assert params['X-Amz-Security-Token'] and len(params['X-Amz-Signature'][0])==64
            data,_=send_signed(link)
            assert data==b'first-image'
            reject(lambda:send_signed({**link,'url':link['url'].replace('x-id=GetObject','x-id=HeadObject')}),403)
            reject(lambda:send_signed({**link,'url':link['url'].replace('x-amz-checksum-mode=ENABLED','x-amz-checksum-mode=DISABLED')}),403)
            download=signed('GET','null',download=True)
            data,download_headers=send_signed(download)
            assert data==b'first-image' and download_headers['Content-Disposition']=='attachment'
            assert urllib.parse.parse_qs(urllib.parse.urlsplit(download['url']).query)['versionId']==['null']
            result=api('buckets/details-test/legal-hold',{'key':'photo.png','version_id':latest['version_id'],'enabled':True},'PATCH')
            assert result['legal_hold'] and result['version_id']==latest['version_id']
            reject(lambda:send_signed(signed('DELETE',latest['version_id']),'DELETE'),403)
            api('buckets/details-test/legal-hold',{'key':'photo.png','version_id':latest['version_id'],'enabled':False},'PATCH')
            send_signed(signed('DELETE',latest['version_id']),'DELETE')
            assert len(api('buckets/details-test/versions')['items'])==2
            long_link=api('objects/presign',{'bucket':'details-test','key':'photo.png','method':'GET','expires_seconds':604800})
            expiry=datetime.datetime.fromisoformat(long_link['expires_at'].replace('Z','+00:00'))
            session=api('auth/session')
            assert expiry.timestamp()<=session['expires_at']
            print('PASS: metadata-only HEAD, method binding, null/current version tags, restore creates a new version, legal hold protects deletion, session-bounded link expiry')
        finally:
            stop()
            output.close()

if __name__=='__main__':
    run()
