"""Isolated native transport regressions. Run after zig build http-probe."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import time

PROBE = Path(__file__).resolve().parents[1] / 'zig-out/bin/net-transport-http-probe'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.peers.append(self.client_address)
        if self.path == '/stall':
            time.sleep(1)
        if self.path == '/rotate':
            self.server.rotate.write_text('invalid rotated certificate')
        self.send_response(307 if self.path == '/redirect' else 200)
        payload = b'payload' if self.path != '/large' else b'x' * 1024
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', '100' if self.path == '/partial' else str(len(payload)))
        if self.path == '/redirect':
            self.send_header('Location', 'http://127.0.0.1:1/must-not-follow')
        self.end_headers()
        try:
            if self.path == '/chunked':
                self.wfile.write(b'7;extension=yes\r\npayload\r\n0\r\nx-trailer: yes\r\n\r\n')
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass
        if self.path == '/partial':
            self.close_connection = True


@contextlib.contextmanager
def server(context=None):
    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    http.peers = []
    if context:
        http.socket = context.wrap_socket(http.socket, server_side=True)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    try:
        yield http
    finally:
        http.shutdown()
        http.server_close()
        thread.join()


def request(url, ca='', cert='', key='', insecure=False, timeout=1000,
            rounds=1, truncate=False, cancel=False):
    result = subprocess.run(
        [str(PROBE), url, str(ca), str(cert), str(key), str(int(insecure)),
         str(timeout), str(rounds), str(int(truncate)), str(int(cancel))],
        capture_output=True, text=True, timeout=8,
    )
    assert result.returncode == 0, result.stderr
    return [tuple(map(int, line.split())) for line in result.stdout.splitlines()]


with server() as http:
    url = f'http://127.0.0.1:{http.server_port}'
    assert request(url, rounds=2) == [(0, 200, 7)] * 2
    assert http.peers[0] == http.peers[1], 'connection was not reused'
    assert request(url + '/chunked') == [(0, 200, 7)]
    assert request(url + '/redirect') == [(0, 307, 7)]
    assert request(url + '/partial')[0][0] == 18
    assert request(url + '/large')[0][0] == -2
    assert request(url + '/large', truncate=True, rounds=2) == [(0, 200, 256)] * 2
    assert http.peers[-1] == http.peers[-2], 'truncated diagnostics were not drained'
    assert request(url + '/stall', timeout=150)[0][0] == 28
    assert request(url, cancel=True)[0][0] == 42

with tempfile.TemporaryDirectory(prefix='zigfs-native-tls-') as directory:
    root = Path(directory)

    def openssl(*args):
        subprocess.run(['openssl', *args], cwd=root, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=Test CA', '-keyout', 'ca.key', '-out', 'ca.pem')
    for name, extension in [('server', 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth'),
                            ('client', 'extendedKeyUsage=clientAuth')]:
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-subj', f'/CN={name}',
                '-keyout', f'{name}.key', '-out', f'{name}.csr')
        (root / f'{name}.ext').write_text(extension + '\n')
        openssl('x509', '-req', '-in', f'{name}.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
                '-CAcreateserial', '-days', '1', '-extfile', f'{name}.ext', '-out', f'{name}.pem')
    ca = root / 'ca.pem'
    cert = root / 'client.pem'
    key = root / 'client.key'
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'server.pem', root / 'server.key')
    names = []
    context.set_servername_callback(lambda connection, hostname, original: names.append(hostname))
    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
        context.minimum_version = context.maximum_version = version
        with server(context) as http:
            url = f'https://localhost:{http.server_port}'
            actual = request(url, ca=ca, rounds=2)
            assert actual == [(0, 200, 7)] * 2, (version, actual)
            assert http.peers[0] == http.peers[1]
            assert request(url, ca=root / 'server.pem') == [(0, 200, 7)]
            assert request(url, ca=cert)[0][0] == 60
            assert request(url)[0][0] == 60
            assert request(f'https://127.0.0.1:{http.server_port}', ca=ca)[0][0] == 60
            assert request(url, insecure=True) == [(0, 200, 7)]
            assert names[-1] == 'localhost', 'insecure mode must retain SNI'
            rotated = root / 'rotated.pem'
            rotated.write_bytes(ca.read_bytes())
            http.rotate = rotated
            results = request(url + '/rotate', ca=rotated, rounds=2)
            assert results[0] == (0, 200, 7) and results[1][0] == 60
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(ca)
    with server(context) as http:
        url = f'https://localhost:{http.server_port}'
        assert request(url, ca=ca, cert=cert, key=key) == [(0, 200, 7)]
        assert request(url, ca=ca)[0][0] != 0
        assert request(url, ca=ca, cert=cert, key=root / 'server.key')[0][0] == 60
        assert request(url, ca=ca, cert=cert, key=key, rounds=0) == [(0, 200, 7)] * 8

print('PASS native HTTP/TLS: pooling, chunked/truncated responses, bounds, cancellation, deadlines, '
      'TLS 1.2/1.3, hostname checks, SNI, CA rotation, mTLS and key mismatch.')
