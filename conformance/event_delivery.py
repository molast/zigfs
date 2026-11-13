#!/usr/bin/env python3
"""Exercise real Sender adapters against local HTTP(S), MQTT and WebSocket mocks.
Build first: cd zigfs && zig build event-delivery-probe
No production services, subscriptions or data are used.
"""
import base64
import contextlib
import hashlib
import http.server
import json
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

PROBE = Path('zigfs/zig-out/bin/event-delivery-probe').resolve()
EVENT = {'id':'event-stable-1','payload':'{"event_id":"event-stable-1","Records":[]}', 'content_type':'application/json'}


def exact(conn, count):
    data = b''
    while len(data) < count:
        part = conn.recv(count-len(data))
        if not part: raise EOFError('peer disconnected')
        data += part
    return data


class MqttWire:
    def __init__(self, conn, ws=False):
        self.conn, self.ws, self.buffer = conn, ws, bytearray()

    def read(self, n):
        if not self.ws: return exact(self.conn,n)
        while len(self.buffer)<n:
            first,second=exact(self.conn,2)
            assert first & 128 and first & 15 in (2,10)
            assert second & 128, 'client frames must be masked'
            length=second & 127
            if length==126:length=struct.unpack('!H',exact(self.conn,2))[0]
            if length==127:length=struct.unpack('!Q',exact(self.conn,8))[0]
            mask=exact(self.conn,4)
            payload=bytes(byte ^ mask[i%4] for i,byte in enumerate(exact(self.conn,length)))
            if first & 15 == 2:self.buffer.extend(payload)
        data=bytes(self.buffer[:n]);del self.buffer[:n];return data

    def packet(self):
        header=self.read(1)[0]
        length=0;multiplier=1
        for _ in range(4):
            value=self.read(1)[0];length+=(value&127)*multiplier
            if not value&128:break
            multiplier*=128
        else:raise AssertionError('invalid MQTT remaining length')
        return header,self.read(length)

    def send(self,data):
        if not self.ws:self.conn.sendall(data);return
        # Ping and fragmented binary response exercise control/continuation framing.
        self.conn.sendall(b'\x89\x01P')
        self.conn.sendall(bytes([0x02,1])+data[:1])
        self.conn.sendall(bytes([0x80,len(data)-1])+data[1:])


@contextlib.contextmanager
def mqtt_server(qos=1, ws=False, context=None, failure=None):
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(5)
    state={'published':False,'error':None,'path':None,'received':False}
    def serve():
        try:
            conn,_=listener.accept()
            with conn:
                conn.settimeout(4)
                if context:conn=context.wrap_socket(conn,server_side=True)
                if ws:
                    request=b''
                    while not request.endswith(b'\r\n\r\n'):request+=exact(conn,1)
                    lines=request.decode().split('\r\n');state['path']=lines[0].split()[1]
                    headers=dict(line.split(': ',1) for line in lines[1:] if ': ' in line)
                    assert headers['Sec-WebSocket-Protocol']=='mqtt'
                    accept=base64.b64encode(hashlib.sha1((headers['Sec-WebSocket-Key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                    if failure=='upgrade':accept=b'invalid'
                    conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: mqtt\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
                    if failure=='upgrade':return
                wire=MqttWire(conn,ws)
                header,body=wire.packet();assert header==0x10
                assert body[:7]==b'\0\4MQTT\4'
                assert body[7]&2 and body[7]&0xc0==0xc0
                assert struct.unpack('!H',body[8:10])[0]==15
                offset=10;values=[]
                while offset<len(body):
                    size=struct.unpack('!H',body[offset:offset+2])[0];offset+=2
                    values.append(body[offset:offset+size]);offset+=size
                assert values[0].startswith(b'zigfs') and values[1:]==[b'publisher',b'mqtt-test-password']
                state['received']=True
                if failure=='timeout':time.sleep(1.5);return
                wire.send(b'\x20\x02\x00'+(b'\x05' if failure=='auth' else b'\x00'))
                if failure=='auth':return
                header,body=wire.packet();assert header==0x30|(qos<<1)
                size=struct.unpack('!H',body[:2])[0];assert body[2:2+size]==b'bucket/events'
                offset=2+size
                if qos:assert body[offset:offset+2]==b'\0\1';offset+=2
                assert body[offset:]==EVENT['payload'].encode()
                state['published']=True
                if qos==1:
                    wire.send(b'\x40\x02\x00'+(b'\x02' if failure=='ack' else b'\x01'))
                if qos==2:
                    wire.send(b'\x50\x02\x00\x01')
                    assert wire.packet()==(0x62,b'\0\1')
                    wire.send(b'\x50\x02\x00\x01') # Duplicate PUBREC must resend PUBREL.
                    assert wire.packet()==(0x62,b'\0\1')
                    wire.send(b'\x70\x02\x00\x01')
                if failure!='ack':assert wire.packet()==(0xe0,b'')
        except Exception as error:state['error']=error
    worker=threading.Thread(target=serve,daemon=True);worker.start()
    try:yield listener.getsockname()[1],state
    finally:
        worker.join(5);listener.close()
        if state['error']:raise state['error']


@contextlib.contextmanager
def http_server(status=204, context=None):
    state={'requests':0}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            state['requests']+=1
            assert self.headers['Authorization']=='Bearer webhook-test-token'
            assert self.headers['X-ZigFS-Event-ID']==EVENT['id']
            assert self.headers['Content-Type']=='application/json'
            assert self.rfile.read(int(self.headers['Content-Length']))==EVENT['payload'].encode()
            self.send_response(status)
            if status==302:self.send_header('Location','http://127.0.0.1:1/never-follow')
            self.end_headers()
            if status==200:self.wfile.write(b'X'*16384)
        def log_message(self,*args):pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    if context:server.socket=context.wrap_socket(server.socket,server_side=True)
    worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
    try:yield server.server_port,state
    finally:server.shutdown();server.server_close();worker.join()


def run():
    with tempfile.TemporaryDirectory(prefix='zigfs-delivery-') as directory:
        root=Path(directory)
        def probe(destination, expected='', event=EVENT, timeout=2):
            path=root/'request.json';path.write_text(json.dumps({'destination':destination,'event':event,'expected_error':expected,'timeout_seconds':timeout}))
            result=subprocess.run([str(PROBE),str(root),str(path)],capture_output=True,text=True,timeout=timeout+5)
            assert result.returncode==0,result.stderr
        def webhook(port,**extra):return {'name':'WEBHOOK','endpoint':f'http://127.0.0.1:{port}/events','auth_token':'Bearer webhook-test-token',**extra}
        def mqtt(port,qos=1,**extra):return {'name':'MQTT','type':'mqtt','broker':f'tcp://127.0.0.1:{port}','topic':'bucket/events','qos':qos,'username':'publisher','password':'mqtt-test-password',**extra}
        for status,error in [(200,''),(204,''),(401,'AuthenticationFailed'),(403,'AuthenticationFailed'),(429,'RateLimited'),(503,'Unavailable'),(408,'Timeout'),(302,'Rejected'),(400,'Rejected')]:
            with http_server(status) as (port,state):
                probe(webhook(port),error);assert state['requests']==1
        for qos in [0,1,2]:
            with mqtt_server(qos) as (port,state):probe(mqtt(port,qos));assert state['published']
        for failure,error in [('auth','AuthenticationFailed'),('ack','Rejected'),('timeout','Timeout')]:
            with mqtt_server(failure=failure) as (port,state):probe(mqtt(port),error,timeout=1)
        for qos in [0,1,2]:
            with mqtt_server(qos,ws=True) as (port,state):
                probe(mqtt(port,qos,broker=f'ws://127.0.0.1:{port}/mqtt',websocket_path_allowlist='/mqtt,/ws'))
                assert state['published'] and state['path']=='/mqtt'
        with mqtt_server(ws=True,failure='upgrade') as (port,state):probe(mqtt(port,broker=f'ws://127.0.0.1:{port}/mqtt'),'Rejected')
        probe(mqtt(1,broker='ws://127.0.0.1:1/disallowed',websocket_path_allowlist='/mqtt'),'InvalidConfiguration')
        probe(mqtt(1,tls_policy='unknown'),'InvalidConfiguration')
        probe(webhook(1), 'InvalidEvent', {**EVENT,'id':'bad\r\nInjected: value'})
        def openssl(*args):
            result=subprocess.run(['openssl',*args],cwd=root,capture_output=True,text=True)
            assert result.returncode==0,result.stderr
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=Test CA','-keyout','ca.key','-out','ca.pem')
        openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=localhost','-keyout','server.key','-out','server.csr')
        (root/'server.ext').write_text('subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n')
        openssl('x509','-req','-in','server.csr','-CA','ca.pem','-CAkey','ca.key','-CAcreateserial','-days','1','-extfile','server.ext','-out','server.pem')
        openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=client','-keyout','client.key','-out','client.csr')
        (root/'client.ext').write_text('extendedKeyUsage=clientAuth\n')
        openssl('x509','-req','-in','client.csr','-CA','ca.pem','-CAkey','ca.key','-CAcreateserial','-days','1','-extfile','client.ext','-out','client.pem')
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(root/'server.pem',root/'server.key')
        with http_server(context=ctx) as (port,state):
            probe(webhook(port,endpoint=f'https://127.0.0.1:{port}/events',client_ca='ca.pem'))
            probe(webhook(port,endpoint=f'https://127.0.0.1:{port}/events'),'InvalidConfiguration')
            probe(webhook(port,endpoint=f'https://127.0.0.1:{port}/events',skip_tls_verify=True))
        for ws in [False,True]:
            with mqtt_server(qos=2,ws=ws,context=ctx) as (port,state):
                scheme='wss' if ws else 'tls';path='/mqtt' if ws else ''
                probe(mqtt(port,2,broker=f'{scheme}://127.0.0.1:{port}{path}',tls_ca='ca.pem'))
        probe(mqtt(1,broker='tls://127.0.0.1:1',tls_ca='server.pem'),'InvalidConfiguration')
        with mqtt_server(context=ctx) as (port,state):probe(mqtt(port,broker=f'tls://127.0.0.1:{port}',tls_ca='server.pem',trust_leaf_as_ca=True))
        ctx.verify_mode=ssl.CERT_REQUIRED;ctx.load_verify_locations(root/'ca.pem')
        with http_server(context=ctx) as (port,state):probe(webhook(port,endpoint=f'https://127.0.0.1:{port}/events',client_ca='ca.pem',client_certificate='client.pem',client_key='client.key'))
        with mqtt_server(context=ctx) as (port,state):probe(mqtt(port,broker=f'tls://127.0.0.1:{port}',tls_ca='ca.pem',tls_client_certificate='client.pem',tls_client_key='client.key'))
        print('PASS Webhook statuses, headers, bounded responses, TLS/mTLS; MQTT QoS 0/1/2, credentials, duplicate PUBREC, timeout, WS/WSS framing and path policy; unified Sender adapters')


if __name__=='__main__':run()
