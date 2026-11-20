"""Native transport regressions, executed inside s3api_integration.py's fixture."""
original_get = Fixture.do_GET
original_head = Fixture.do_HEAD
native_peers = []
native_payload = bytes(range(256)) * 1024


def native_get(self):
    mode = Fixture.mode
    if not mode.startswith('native-'):
        return original_get(self)
    Fixture.calls += 1
    self.verify()
    if mode == 'native-chunked':
        self.send_response(200)
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        for offset in range(0, len(native_payload), 8191):
            chunk = native_payload[offset:offset + 8191]
            self.wfile.write(f'{len(chunk):x};test=value\r\n'.encode())
            self.wfile.write(chunk + b'\r\n')
        self.wfile.write(b'0\r\nx-test-trailer: yes\r\n\r\n')
        return
    if mode == 'native-truncated-chunk':
        self.send_response(200)
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        self.wfile.write(b'100\r\npartial')
        self.wfile.flush()
        self.close_connection = True
        return
    if mode == 'native-head':
        self.send_response(200)
        # HEAD metadata does not imply that any chunks will follow.
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        return
    if mode == 'native-interim':
        self.wfile.write(b'HTTP/1.1 103 Early Hints\r\nLink: </unused>\r\n\r\n')
        self.reply(200, b'<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>')
        return
    if mode == 'native-stall':
        self.send_response(200)
        self.send_header('Content-Length', '100000')
        self.end_headers()
        self.wfile.write(b'partial')
        self.wfile.flush()
        time.sleep(2)
        self.close_connection = True
        return
    if mode == 'native-pages':
        native_peers.append(self.client_address)
        more = 'continuation-token=' not in self.path
        token = '<ContinuationToken>next</ContinuationToken>' if more else ''
        name = 'first-bucket' if more else 'second-bucket'
        self.reply(200, (
            '<ListAllMyBucketsResult><Buckets><Bucket><Name>' + name +
            '</Name></Bucket></Buckets>' + token + '</ListAllMyBucketsResult>'
        ).encode())


Fixture.do_GET = native_get
Fixture.do_HEAD = native_get
try:
    Fixture.mode = 'native-chunked'
    destination = root / 'native-chunked.bin'
    call('get-object', {'Bucket': 'test-bucket', 'Key': 'binary'},
         name='fixture', options=('--output', destination))
    assert destination.read_bytes() == native_payload

    Fixture.mode = 'native-truncated-chunk'
    destination = root / 'native-truncated.bin'
    call('get-object', {'Bucket': 'test-bucket', 'Key': 'binary'}, name='fixture',
         options=('--output', destination, '--retry-attempts', '1'), code=3)
    assert not destination.exists()

    Fixture.mode = 'native-head'
    call('head-object', {'Bucket': 'test-bucket', 'Key': 'binary'}, name='fixture',
         options=('--timeout', '1', '--connect-timeout', '1'))
    Fixture.mode = 'native-interim'
    call('list-buckets', name='fixture')

    Fixture.mode = 'native-stall'
    destination = root / 'native-stalled.bin'
    started = time.monotonic()
    call('get-object', {'Bucket': 'test-bucket', 'Key': 'binary'}, name='fixture',
         options=('--output', destination, '--timeout', '1', '--connect-timeout', '1'),
         code=3)
    assert time.monotonic() - started < 2
    assert not destination.exists()

    Fixture.mode = 'native-pages'
    outcome = cli(['--json', 'ls', 'fixture', '--page-size', '1'])
    assert outcome['data']['count'] == 2
    assert len(native_peers) == 2 and native_peers[0] == native_peers[1]
finally:
    Fixture.do_GET = original_get
    Fixture.do_HEAD = original_head

# A TCP peer accepts the TLS connection but never completes the handshake.
import socketserver


class SilentTLS(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(8192)
        time.sleep(2)


silent = socketserver.ThreadingTCPServer(('127.0.0.1', 0), SilentTLS)
silent.daemon_threads = True
threading.Thread(target=silent.serve_forever, daemon=True).start()
try:
    alias('native-silent-tls', f'https://localhost:{silent.server_address[1]}')
    started = time.monotonic()
    call('list-buckets', name='native-silent-tls',
         options=('--insecure', '--connect-timeout', '1', '--timeout', '4',
                  '--retry-attempts', '1'), code=3)
    assert time.monotonic() - started < 2
finally:
    silent.shutdown()
    silent.server_close()

print('PASS native transport: chunked binary/trailers, truncated chunks, HEAD, interim response, '
      'body deadline, connection reuse and TLS handshake deadline.')
