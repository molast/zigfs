#!/usr/bin/env python3
"""Real bucket notifications against isolated ZigFS, Webhook and MQTT servers."""
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


def run(webhook_port, received, mqtt_port, mqtt_received, status):
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

        def wait(predicate):
            until = time.monotonic() + 25
            while time.monotonic() < until:
                if predicate(): return
                time.sleep(.1)
            raise AssertionError('delivery timeout: ' + (root / 'process.log').read_text()[-5000:])

        try:
            start()
            token = login('file-root', 'file-root-password')
            api('buckets', {'name':'events-test'})
            target = api('event-destinations', {'name':'HTTP','type':'webhook','endpoint':f'http://127.0.0.1:{webhook_port}/events','auth_token':'Bearer test'})
            api('event-destinations', {'name':'MQTT','type':'mqtt','broker':f'tcp://127.0.0.1:{mqtt_port}','topic':'bucket/events','qos':1})
            rule = {'id':'one','destination':'HTTP','prefix':'photos/','suffix':'.jpg','events':['PUT','GET','DELETE']}
            api('buckets/events-test/event-subscriptions', {'items':[rule,{**rule,'id':'overlap'},{**rule,'id':'mqtt','destination':'MQTT'}]}, 'PUT')
            reject(lambda: api('event-destinations/HTTP',method='DELETE'),409)
            reject(lambda: api('buckets/events-test/event-subscriptions', {'items':[{**rule,'destination':'MISSING'}]}, 'PUT'),400)
            s3('PUT','/events-test/skip.jpg',payload=b'no event')
            s3('PUT','/events-test/photos/skip.txt',payload=b'no event')
            s3('PUT','/events-test/photos/a.jpg',payload=b'hello')
            s3('GET','/events-test/photos/a.jpg')
            s3('HEAD','/events-test/photos/a.jpg')
            reject(lambda: s3('GET','/events-test/photos/missing.jpg'),404)
            s3('PUT','/events-test/photos/copy.jpg',extra={'x-amz-copy-source':'/events-test/photos/a.jpg'})
            s3('DELETE','/events-test/photos/a.jpg')
            s3('DELETE','/events-test/photos/missing.jpg')
            wait(lambda: len(received)>=5 and len(mqtt_received)>=5)
            time.sleep(1.5)
            assert len(received)==len(mqtt_received)==5, (received,mqtt_received)
            names = sorted(item['Records'][0]['eventName'] for item in received)
            assert names == sorted(['ObjectCreated:Put','ObjectCreated:Copy','ObjectAccessed:Get','ObjectAccessed:Head','ObjectRemoved:Delete']), names
            assert {v['event_id'] for v in received} == {v['event_id'] for v in mqtt_received}
            assert all(isinstance(item['Records'][0]['s3']['bucket']['id'],str) for item in received)
            assert all(item['Records'][0]['s3']['object']['key'].startswith('photos%2F') for item in received)
            # Permanent failures are retained, not hammered; changing configuration retries.
            status[0] = 401
            s3('PUT','/events-test/photos/blocked.jpg',payload=b'blocked')
            wait(lambda: len(received)==6)
            time.sleep(2)
            assert len(received)==6
            pending = list((root/'data/.zigfs/events/queues/HTTP').glob('*.json'))
            assert len(pending)==1 and json.loads(pending[0].read_text())['blocked']
            reject(lambda: api('event-destinations/HTTP',{**target,'queue_directory':'other'},'PUT'),409)
            status[0] = 204
            api('event-destinations/HTTP',{**target,'comment':'retry fixed configuration'},'PUT')
            wait(lambda: len(received)==7)
            assert received[5]['event_id']==received[6]['event_id']
            wait(lambda: not list((root/'data/.zigfs/events/queues/HTTP').glob('*.json')))
            # Transient retries survive process restart and preserve event identity.
            status[0] = 503
            s3('PUT','/events-test/photos/restart.jpg',payload=b'restart')
            wait(lambda: any(v['Records'][0]['s3']['object']['key']=='photos%2Frestart.jpg' for v in received))
            stop()
            queued = list((root/'data/.zigfs/events/queues/HTTP').glob('*.json'))
            assert len(queued)==1
            event_id = json.loads(queued[0].read_text())['id']
            status[0] = 204
            start()
            wait(lambda: not list((root/'data/.zigfs/events/queues/HTTP').glob('*.json')))
            assert sum(item['event_id']==event_id for item in received)>=2
            token = login('file-root','file-root-password')
            rule['events'] = ['PUT','GET','DELETE','ILM']
            api('buckets/events-test/event-subscriptions', {'items':[rule]}, 'PUT')
            def matching(key, name):
                return [v for v in received if v['Records'][0]['s3']['object']['key']=='photos%2F'+key and v['Records'][0]['eventName']==name]
            # Multipart emits once at completion, never for individual parts.
            initialized = s3('POST','/events-test/photos/multi.jpg?uploads=')
            upload_id = ET.fromstring(initialized).find('{*}UploadId').text
            _, headers = s3('PUT',f'/events-test/photos/multi.jpg?partNumber=1&uploadId={upload_id}',payload=b'multipart',with_headers=True)
            etag = headers['ETag']
            completion = f'<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{etag}</ETag></Part></CompleteMultipartUpload>'.encode()
            completed = s3('POST',f'/events-test/photos/multi.jpg?uploadId={upload_id}',payload=completion)
            wait(lambda: len(matching('multi.jpg','ObjectCreated:CompleteMultipartUpload'))==1)
            completed_etag = ET.fromstring(completed).find('{*}ETag').text.strip('"')
            assert matching('multi.jpg','ObjectCreated:CompleteMultipartUpload')[0]['Records'][0]['s3']['object']['eTag']==completed_etag
            # Repeated completion is idempotent and must not notify twice.
            s3('POST',f'/events-test/photos/multi.jpg?uploadId={upload_id}',payload=completion)
            time.sleep(1.2)
            assert len(matching('multi.jpg','ObjectCreated:CompleteMultipartUpload'))==1
            assert not matching('multi.jpg','ObjectCreated:Put')
            # Creating and explicitly deleting a delete marker are different events.
            s3('PUT','/events-test?versioning=',payload=b'<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>')
            s3('PUT','/events-test/photos/version.jpg',payload=b'versioned')
            _, marker = s3('DELETE','/events-test/photos/version.jpg',with_headers=True)
            s3('DELETE','/events-test/photos/version.jpg?versionId='+urllib.parse.quote(marker['x-amz-version-id']))
            wait(lambda: len(matching('version.jpg','ObjectRemoved:Delete'))==1 and len(matching('version.jpg','ObjectRemoved:DeleteMarkerCreated'))==1)
            # Real lifecycle expiration sends ILM, not a user DELETE event.
            s3('PUT','/events-test/photos/expire.jpg',payload=b'expire')
            lifecycle = b'<LifecycleConfiguration><Rule><ID>expire</ID><Filter><And><Prefix>photos/expire</Prefix><Tag><Key>ttl</Key><Value>yes</Value></Tag><Tag><Key>empty</Key><Value/></Tag></And></Filter><Status>Enabled</Status><Expiration><Date>2020-01-01T00:00:00Z</Date></Expiration></Rule></LifecycleConfiguration>'
            s3('PUT','/events-test?lifecycle=',payload=lifecycle)
            # A tag rule must never expire untagged or partially matched objects.
            s3('PUT','/events-test/photos/expire-wrong.jpg',payload=b'wrong',extra={'x-amz-tagging':'ttl=no&empty='})
            s3('PUT','/events-test/photos/expire-partial.jpg',payload=b'partial',extra={'x-amz-tagging':'ttl=yes'})
            s3('PUT','/events-test/photos/keep.jpg',payload=b'prefix mismatch',extra={'x-amz-tagging':'ttl=yes&empty='})
            time.sleep(2.2)
            assert not matching('expire.jpg','LifecycleExpiration:DeleteMarkerCreated')
            s3('HEAD','/events-test/photos/expire.jpg')
            s3('PUT','/events-test/photos/expire.jpg?tagging=',payload=b'<Tagging><TagSet><Tag><Key>ttl</Key><Value>yes</Value></Tag><Tag><Key>empty</Key><Value></Value></Tag></TagSet></Tagging>')
            wait(lambda: bool(matching('expire.jpg','LifecycleExpiration:DeleteMarkerCreated')))
            for key in ['expire-wrong.jpg','expire-partial.jpg','keep.jpg']:
                s3('HEAD','/events-test/photos/'+key)
                assert not matching(key,'LifecycleExpiration:DeleteMarkerCreated')
            saved_lifecycle = s3('GET','/events-test?lifecycle=')
            assert b'<And>' in saved_lifecycle and b'<Key>ttl</Key>' in saved_lifecycle
            assert matching('expire.jpg','LifecycleExpiration:DeleteMarkerCreated')[0]['eventCategory']=='ILM'
            assert not matching('expire.jpg','ObjectRemoved:DeleteMarkerCreated')
            print('PASS real S3 PUT/GET/COPY/DELETE through Webhook + MQTT, filters, deduplication, negative operations, multipart replay, version delete markers, lifecycle tag matching/expiration, target validation, retry/config recovery and restart persistence')
        finally:
            stop()
            output.close()


if __name__ == '__main__':
    import http.server
    import socketserver
    import threading
    from event_delivery import MqttWire
    received, mqtt_received, status = [], [], [204]
    class Webhook(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            value=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.headers['Authorization']=='Bearer test'
            assert self.headers['X-ZigFS-Event-ID']==value['event_id']
            received.append(value)
            self.send_response(status[0]); self.end_headers()
        def log_message(self,*args): pass
    class Broker(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(10)
            wire=MqttWire(self.request)
            header,body=wire.packet(); assert header==0x10
            wire.send(b'\x20\x02\x00\x00')
            header,body=wire.packet(); assert header==0x32
            length=int.from_bytes(body[:2],'big')
            assert body[2:2+length]==b'bucket/events'
            packet_id=body[2+length:4+length]
            mqtt_received.append(json.loads(body[4+length:]))
            wire.send(b'\x40\x02'+packet_id)
    http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Webhook)
    mqtt=socketserver.ThreadingTCPServer(('127.0.0.1',0),Broker)
    workers=[threading.Thread(target=server.serve_forever,daemon=True) for server in [http,mqtt]]
    for worker in workers: worker.start()
    try: run(http.server_port,received,mqtt.server_address[1],mqtt_received,status)
    finally:
        for server in [http,mqtt]: server.shutdown();server.server_close()
        for worker in workers: worker.join()
