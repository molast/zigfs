#!/usr/bin/env python3
"""Isolated Webhook and MQTT destination configuration checks. Never contacts destinations."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
from urllib.error import HTTPError


def run():
    binary = Path('zigfs/zig-out/bin/zigfs').resolve()
    with tempfile.TemporaryDirectory(prefix='zigfs-destinations-') as directory:
        root = Path(directory)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config = root / '.env'
        config.write_text(f'''ZIGFS_ACCESS_KEY=DestinationTestKey123
ZIGFS_SECRET_KEY=0123456789012345678901234567890123456789
ZIGFS_ROOT_USER=test-root
ZIGFS_ROOT_PASSWORD=test-password
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
''')
        environment = {k:v for k,v in os.environ.items() if not k.startswith('ZIGFS_')}
        process, token = None, ''
        output = (root / 'process.log').open('w')

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        def start():
            nonlocal process
            process = subprocess.Popen([str(binary), '--env-file', str(config)], env=environment, stdout=output, stderr=output)
            for _ in range(200):
                assert process.poll() is None, 'server unexpectedly exited'
                try:
                    urllib.request.urlopen(endpoint+'/health/ready', timeout=1).close()
                    return
                except OSError:
                    time.sleep(.05)
            raise AssertionError('readiness timeout')

        def api(path, value=None, method=None, bearer=None):
            req = urllib.request.Request(endpoint+'/_admin/v1/'+path, data=None if value is None else json.dumps(value).encode(), headers={'Content-Type':'application/json','Authorization':'Bearer '+(token if bearer is None else bearer)}, method=method)
            with urllib.request.urlopen(req,timeout=10) as response:
                return json.loads(response.read())

        def reject(call, status):
            try:
                call()
            except HTTPError as error:
                assert error.code == status, (status,error.code,error.read())
            else:
                raise AssertionError('request unexpectedly succeeded')

        def login(user='test-root', password='test-password'):
            return api('auth/login',{'username':user,'password':password},bearer='')['token']

        try:
            start()
            token = login()
            assert api('event-destinations')['items'] == []
            reject(lambda: api('event-destinations',bearer=''),401)
            api('users',{'name':'reader','password':'reader-password','policies':['readonly']})
            reader = login('reader','reader-password')
            reject(lambda: api('event-destinations',bearer=reader),403)
            value = {'name':'WEBHOOK_1','type':'webhook','endpoint':'http://127.0.0.1:1/events','auth_token':'test-webhook-secret','queue_limit':1000,'queue_directory':'events/WEBHOOK_1','client_certificate':'certs/client.crt','client_key':'certs/client.key','client_ca':'certs/ca.crt','skip_tls_verify':False,'comment':'Configuration only'}
            reject(lambda: api('event-destinations',value,bearer=reader),403)
            created = api('event-destinations',value)
            assert created['auth_token'] == '' and created['has_auth_token']
            # Unreachable endpoint and missing certificate files do not prevent configuration saves.
            reject(lambda: api('event-destinations',value),409)
            reject(lambda: api('event-destinations/WEBHOOK_1',{**created,'endpoint':'ws://invalid'},'PUT'),400)
            reject(lambda: api('event-destinations/WEBHOOK_1',{**created,'queue_directory':'../outside'},'PUT'),400)
            reject(lambda: api('event-destinations/WEBHOOK_1',{**created,'queue_limit':0},'PUT'),400)
            reject(lambda: api('event-destinations/WEBHOOK_1',{**created,'client_key':''},'PUT'),400)
            updated = api('event-destinations/WEBHOOK_1',{**created,'comment':'Updated'},'PUT')
            assert updated['has_auth_token'] and updated['comment'] == 'Updated'
            saved = root/'data/.zigfs/config/event-destinations.enc'
            assert b'test-webhook-secret' not in saved.read_bytes()
            mqtt_value = {'name':'MQTT_1','type':'mqtt','broker':'tcp://127.0.0.1:1','topic':'bucket/events','qos':2,'username':'publisher','password':'mqtt-private-password','reconnect_interval':'5s','keep_alive_interval':'30s','queue_directory':'events/MQTT_1','queue_limit':1000,'tls_policy':'strict','tls_ca':'certs/ca.pem','tls_client_certificate':'certs/client.pem','tls_client_key':'certs/client.key','trust_leaf_as_ca':False,'websocket_path_allowlist':'/mqtt,/ws','comment':'MQTT configuration only'}
            mqtt = api('event-destinations',mqtt_value)
            assert mqtt['password'] == '' and mqtt['has_password'] and mqtt['qos'] == 2
            assert b'mqtt-private-password' not in saved.read_bytes()
            for field,bad in [('qos',3),('topic','events/#'),('broker','http://invalid'),('reconnect_interval','0s'),('tls_ca','../outside'),('tls_client_key',''),('websocket_path_allowlist','/mqtt,https://invalid')]:
                reject(lambda: api('event-destinations/MQTT_1',{**mqtt,field:bad},'PUT'),400)
            reject(lambda: api('event-destinations/MQTT_1',{**created,'name':'MQTT_1'},'PUT'),400)
            mqtt = api('event-destinations/MQTT_1',{**mqtt,'comment':'Updated MQTT'},'PUT')
            assert mqtt['has_password'] and mqtt['password'] == ''
            stop()
            start()
            token = login()
            all_items = api('event-destinations')['items']
            assert len(all_items) == 2
            mqtt_loaded = next(item for item in all_items if item['name']=='MQTT_1')
            assert mqtt_loaded == mqtt
            replaced = api('event-destinations/MQTT_1',{**mqtt_loaded,'password':'replacement-password'},'PUT')
            assert replaced['has_password'] and replaced['password'] == ''
            cleared_mqtt = api('event-destinations/MQTT_1',{**replaced,'has_password':False},'PUT')
            assert not cleared_mqtt['has_password']
            api('event-destinations/MQTT_1',method='DELETE')
            loaded = api('event-destinations')['items'][0]
            assert loaded == updated, (loaded,updated)
            cleared = api('event-destinations/WEBHOOK_1',{**loaded,'has_auth_token':False},'PUT')
            assert not cleared['has_auth_token'] and not cleared['auth_token']
            api('event-destinations/WEBHOOK_1',method='DELETE')
            assert api('event-destinations')['items'] == []
            reject(lambda: api('event-destinations/WEBHOOK_1',method='DELETE'),404)
            print('PASS Webhook/MQTT CRUD, validation, secret redaction/preservation/replacement/removal, encrypted storage, restart and authorization')
        finally:
            stop()
            output.close()


if __name__ == '__main__':
    run()
