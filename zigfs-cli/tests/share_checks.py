"""Step 09 checks, executed by s3api_integration.py inside its isolated server."""
import re


def share_run(args, code=0):
    result = subprocess.run([str(CLI), '--json', *args], env=env, capture_output=True, timeout=30)
    assert result.returncode == code, (args[:2], result.returncode, result.stderr.decode())
    assert SK.encode() not in result.stdout + result.stderr
    if code:
        assert not result.stdout
        assert AK.encode() not in result.stderr
        return json.loads(result.stderr)
    assert not result.stderr
    return json.loads(result.stdout)


def verify_url(data, secret=SK):
    u = urllib.parse.urlsplit(data['url'])
    query = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    encode = lambda s: urllib.parse.quote(s, safe='-._~')
    canonical_query = '&'.join(sorted(f'{encode(k)}={encode(v)}' for k, values in query.items()
                                    if k != 'X-Amz-Signature' for v in values))
    signed_headers = query['X-Amz-SignedHeaders'][0]
    canonical_headers = ''.join(f'{name}:{data["headers"][name]}\n' for name in signed_headers.split(';'))
    canonical = '\n'.join([data['method'], u.path, canonical_query, canonical_headers,
                           signed_headers, 'UNSIGNED-PAYLOAD'])
    credential = query['X-Amz-Credential'][0]
    _, day, region, service, end = credential.split('/')
    key = ('AWS4' + secret).encode()
    for part in (day, region, service, end):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    message = '\n'.join(['AWS4-HMAC-SHA256', query['X-Amz-Date'][0], credential.split('/', 1)[1],
                         hashlib.sha256(canonical.encode()).hexdigest()])
    assert hmac.new(key, message.encode(), hashlib.sha256).hexdigest() == query['X-Amz-Signature'][0]


def use_url(data, body=None, expected=200, omit=None):
    u = urllib.parse.urlsplit(data['url'])
    connection = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    headers = {k: v for k, v in data['headers'].items() if k != omit}
    connection.request(data['method'], u.path + '?' + u.query, body=body, headers=headers)
    response = connection.getresponse()
    payload = response.read()
    assert response.status == expected, (data['method'], response.status, payload[:250])
    response_headers = dict(response.getheaders())
    connection.close()
    return payload, response_headers


share_key = 'share//../中 +%?&.bin'
remote_share = f'real/{bucket}/{share_key}'
put_url = share_run(['share', remote_share, '--method', 'PUT', '--expire', '5m',
                     '--header', 'Content-Type: application/octet-stream'])['data']
verify_url(put_url)
use_url(put_url, b'shared bytes')
get_url = share_run(['object', 'share', remote_share])['data']
verify_url(get_url)
assert use_url(get_url)[0] == b'shared bytes'
head_url = share_run(['share', remote_share, '--method', 'HEAD'])['data']
assert use_url(head_url)[0] == b''
range_url = share_run(['share', remote_share, '--header', 'Range: bytes=0-5'])['data']
verify_url(range_url)
assert use_url(range_url, expected=206)[0] == b'shared'
use_url(range_url, expected=400, omit='range')
tampered = dict(get_url, url=get_url['url'].replace('X-Amz-Expires=3600', 'X-Amz-Expires=3601'))
use_url(tampered, expected=403)
for args in (['--expire', '0'], ['--expire', '8d'], ['--method', 'POST'],
             ['--header', 'Host: attacker'], ['--header', 'Authorization: secret'],
             ['--header', 'X-Test: a', '--header', 'x-test: b'],
             ['--upload-id', 'id'], ['--operation', 'upload-part', '--upload-id', 'id', '--part-number', '0']):
    share_run(['share', remote_share, *args], code=2)
share_run(['share', f'temporary/{bucket}/{share_key}'], code=2)
share_run(['share', f'temporary/{bucket}/{share_key}', '--expire', '1h',
           '--credential-expiration', str(int(time.time()) + 300)], code=2)
temporary_bucket = 'zc-share-temporary'
cli(['--json', 'mb', f'temporary/{temporary_bucket}'])
temporary_source = root / 'temporary-shared'
temporary_source.write_bytes(b'shared bytes')
cli(['--json', 'put', str(temporary_source), f'temporary/{temporary_bucket}/{share_key}'])
temporary_url = share_run(['share', f'temporary/{temporary_bucket}/{share_key}', '--expire', '60s',
                           '--credential-expiration', str(int(time.time()) + 300)])['data']
verify_url(temporary_url, credentials['secret_key'])
assert use_url(temporary_url)[0] == b'shared bytes'
# Version is part of the signature; no network is used during generation.
version_url = share_run(['share', remote_share, '--version-id', 'null'])['data']
verify_url(version_url)
assert use_url(version_url)[0] == b'shared bytes'

multi_remote = f'real/{bucket}/share-multipart'
create_url = share_run(['share', multi_remote, '--operation', 'create-multipart-upload'])['data']
verify_url(create_url)
created_xml = use_url(create_url)[0]
upload_id = re.search(rb'<UploadId>([0-9a-f]{32})</UploadId>', created_xml).group(1).decode()
part_url = share_run(['share', multi_remote, '--operation', 'upload-part', '--upload-id', upload_id,
                      '--part-number', '1'])['data']
verify_url(part_url)
_, part_headers = use_url(part_url, b'multipart share')
etag = next(value for name, value in part_headers.items() if name.lower() == 'etag')
parts_url = share_run(['share', multi_remote, '--operation', 'list-parts', '--upload-id', upload_id])['data']
assert b'<PartNumber>1</PartNumber>' in use_url(parts_url)[0]
complete_url = share_run(['share', multi_remote, '--operation', 'complete-multipart-upload',
                          '--upload-id', upload_id, '--header', 'If-None-Match: *'])['data']
verify_url(complete_url)
completion_body = f'<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{etag}</ETag></Part></CompleteMultipartUpload>'.encode()
use_url(complete_url, completion_body)
assert cli(['cat', multi_remote], raw=True) == b'multipart share'
created_xml = use_url(create_url)[0]
upload_id = re.search(rb'<UploadId>([0-9a-f]{32})</UploadId>', created_xml).group(1).decode()
abort_url = share_run(['share', multi_remote, '--operation', 'abort-multipart-upload', '--upload-id', upload_id])['data']
use_url(abort_url, expected=204)
use_url(share_run(['share', remote_share, '--method', 'DELETE'])['data'], expected=204)
use_url(get_url, expected=404)

policy_path = root / 'post-policy.json'
fields_path = root / 'post-fields.json'
post_source = root / 'post-upload.bin'
post_source.write_bytes(bytes(range(256)) * 32768)  # 8 MiB streamed, not buffered.
for status in (200, 201, 204):
    policy_path.write_text(json.dumps({'conditions': [
        ['starts-with', '$key', 'posted/'], {'Content-Type': 'application/octet-stream'},
        {'success_action_status': str(status)}, ['content-length-range', 0, post_source.stat().st_size]]}))
    form = share_run(['share', 'post', f'real/{bucket}', '--policy-file', str(policy_path),
                      '--field', f'key=posted/{status}', '--expire', '5m'])
    fields = form['data']['fields']
    day, region, service, end = fields['x-amz-credential'].split('/')[1:]
    key = ('AWS4' + SK).encode()
    for part in (day, region, service, end):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    assert hmac.new(key, fields['policy'].encode(), hashlib.sha256).hexdigest() == fields['x-amz-signature']
    decoded_policy = json.loads(base64.b64decode(fields['policy']))
    assert {'bucket': bucket} in decoded_policy['conditions']
    fields_path.write_text(json.dumps(form))
    cli(['--json', 'object', 'post', f'real/{bucket}', '--file', str(post_source), '--fields-file', str(fields_path)], code=2)
    result = cli(['--json', 'object', 'post', f'real/{bucket}', '--file', str(post_source),
                  '--fields-file', str(fields_path), '--yes'])
    assert result['data'] == {'http_status': status, 'bytes_uploaded': post_source.stat().st_size}
    assert cli(['cat', f'real/{bucket}/posted/{status}'], raw=True) == post_source.read_bytes()

# Reuse signed fields with altered key or signature: fail without publishing.
for tamper in ('key', 'x-amz-signature'):
    changed = dict(fields)
    changed[tamper] = 'outside-prefix' if tamper == 'key' else '0' * 64
    fields_path.write_text(json.dumps(changed))
    result = cli(['--json', 'object', 'post', f'real/{bucket}', '--file', str(post_source),
                  '--fields-file', str(fields_path), '--yes'], code=1 if tamper == 'key' else 4)
    assert fields['policy'] not in json.dumps(result) and fields['x-amz-signature'] not in json.dumps(result)
call('head-object', {'Bucket': bucket, 'Key': 'outside-prefix'}, code=5)

# Length policy rejects oversize content, also for temporary credentials.
policy_path.write_text(json.dumps({'conditions': [{'key': 'post-short'}, ['content-length-range', 0, 1]]}))
form = share_run(['share', 'post', f'temporary/{temporary_bucket}', '--policy-file', str(policy_path), '--expire', '60s',
                  '--credential-expiration', str(int(time.time()) + 300)])
assert form['data']['fields']['x-amz-security-token'] == credentials['session_token']
fields_path.write_text(json.dumps(form))
post_source.write_bytes(b'x')
cli(['--json', 'object', 'post', f'temporary/{temporary_bucket}', '--file', str(post_source), '--fields-file', str(fields_path), '--yes'])
assert cli(['cat', f'temporary/{temporary_bucket}/post-short'], raw=True) == b'x'
post_source.write_bytes(b'too large')
cli(['--json', 'object', 'post', f'temporary/{temporary_bucket}', '--file', str(post_source), '--fields-file', str(fields_path), '--yes'], code=1)
assert cli(['cat', f'temporary/{temporary_bucket}/post-short'], raw=True) == b'x'

for policy in ({'conditions': [{'key': 'a'}]}, {'conditions': [['content-length-range', 0, 1]]},
               {'conditions': [{'key': 'a'}, ['content-length-range', 2, 1]]},
               {'conditions': [{'key': 'a'}, {'x-amz-signature': 'bad'}, ['content-length-range', 0, 1]]}):
    policy_path.write_text(json.dumps(policy))
    share_run(['share', 'post', f'real/{bucket}', '--policy-file', str(policy_path)], code=2)
print('PASS step 09: independent URL/policy signatures, real methods/multipart, temporary expiry, streamed POST 200/201/204, tampering and policy bounds.')

# POST policy expiration, not header-auth skew, controls the lifetime.
from datetime import datetime, timezone, timedelta
policy_path.write_text(json.dumps({'conditions': [{'key': 'post-age'}, ['content-length-range', 0, 1024]]}))
age_form = share_run(['share', 'post', f'real/{bucket}', '--policy-file', str(policy_path), '--expire', '1h'])

def dated_fields(offset, expiry_offset):
    result = dict(age_form['data']['fields'])
    now = datetime.now(timezone.utc)
    date = (now + timedelta(seconds=offset)).strftime('%Y%m%dT%H%M%SZ')
    result['x-amz-date'] = date
    result['x-amz-credential'] = f'{AK}/{date[:8]}/{REGION}/s3/aws4_request'
    document = json.loads(base64.b64decode(result['policy']))
    document['expiration'] = (now + timedelta(seconds=expiry_offset)).strftime('%Y-%m-%dT%H:%M:%SZ')
    for condition in document['conditions']:
        if isinstance(condition, dict):
            for field in ('x-amz-date', 'x-amz-credential'):
                if field in condition:
                    condition[field] = result[field]
    result['policy'] = base64.b64encode(json.dumps(document).encode()).decode()
    key = ('AWS4' + SK).encode()
    for part in (date[:8], REGION, 's3', 'aws4_request'):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    result['x-amz-signature'] = hmac.new(key, result['policy'].encode(), hashlib.sha256).hexdigest()
    return result

post_source.write_bytes(b'valid past signature')
fields_path.write_text(json.dumps(dated_fields(-1800, 600)))
cli(['--json', 'object', 'post', f'real/{bucket}', '--file', str(post_source), '--fields-file', str(fields_path), '--yes'])
assert cli(['cat', f'real/{bucket}/post-age'], raw=True) == post_source.read_bytes()
for offset, expiry_offset, code in ((-1800, -1, 1), (3600, 7200, 4)):
    fields_path.write_text(json.dumps(dated_fields(offset, expiry_offset)))
    cli(['--json', 'object', 'post', f'real/{bucket}', '--file', str(post_source), '--fields-file', str(fields_path), '--yes'], code=code)

# Offline DNS signing changes both canonical Host and URI; no service contact.
dns_url = share_run(['share', f'real/{bucket}/nested//../中 +%', '--endpoint', 'https://example.test:9443', '--bucket-lookup', 'dns'])['data']
verify_url(dns_url)
assert urllib.parse.urlsplit(dns_url['url']).netloc == f'{bucket}.example.test:9443'
assert urllib.parse.urlsplit(dns_url['url']).path == '/nested//../%E4%B8%AD%20%2B%25'

class PostFixture(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    mode = 'redirect'
    calls = 0
    def log_message(self, *args): pass
    def do_POST(self):
        PostFixture.calls += 1
        assert 'Authorization' not in self.headers
        assert self.headers['Content-Type'].startswith('multipart/form-data; boundary=zc-')
        remaining = int(self.headers['Content-Length'])
        while remaining:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk: break
            remaining -= len(chunk)
        if self.mode == 'drop':
            self.close_connection = True
            return
        payload = b'' if self.mode in ('redirect', 'ok') else b'<Error><Message>' + fields['policy'].encode() + b'</Message></Error>'
        self.send_response(307 if self.mode == 'redirect' else 200)
        if self.mode == 'redirect': self.send_header('Location', '/must-not-follow')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

post_fixture = ThreadingHTTPServer(('127.0.0.1', 0), PostFixture)
threading.Thread(target=post_fixture.serve_forever, daemon=True).start()
try:
    alias('postfixture', f'http://127.0.0.1:{post_fixture.server_port}')
    fixture_fields = dict(fields, success_action_status='200')
    fields_path.write_text(json.dumps(fixture_fields))
    for mode, code in (('redirect', 1), ('drop', 3), ('error-200', 1)):
        PostFixture.mode, PostFixture.calls = mode, 0
        cli(['--json', 'object', 'post', 'postfixture/test-bucket', '--file', str(post_source),
             '--fields-file', str(fields_path), '--yes'], code=code)
        assert PostFixture.calls == 1
finally:
    post_fixture.shutdown()
    post_fixture.server_close()
print('PASS step 09 boundaries: policy expiration/future date, DNS signing, POST redirect/no-retry/HTTP-200 error redaction.')
