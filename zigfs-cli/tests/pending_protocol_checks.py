"""Deterministic HTTP evidence for audit fixes; not backend compatibility evidence."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import signal
import subprocess
import time
import urllib.parse


def verify(check, run, root, access, secret, launch):
    class Fixture(BaseHTTPRequestHandler):
        mode = ''
        calls = []
        deletes = 0
        page_count = 0
        lifecycle = None
        started = threading.Event()
        release = threading.Event()
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, BrokenPipeError):
                # SIGINT deliberately closes an in-flight HTTP connection.
                pass

        def respond(self, body='', status=200, headers=None):
            body = body.encode()
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Type', 'application/xml')
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def handle_request(self):
            parsed = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            Fixture.calls.append((self.command, parsed.path, query, dict(self.headers), body))
            mode = Fixture.mode
            if mode in ('buckets', 'bucket-loop'):
                if parsed.path != '/':
                    self.respond('<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>')
                    return
                token = 'same' if mode == 'bucket-loop' else ('second' if len(Fixture.calls) == 1 else '')
                self.respond('<ListAllMyBucketsResult><Buckets><Bucket><Name>test-bucket</Name></Bucket></Buckets>'
                             + '<ContinuationToken>' + token + '</ContinuationToken></ListAllMyBucketsResult>')
            elif mode in ('service-filter', 'service-budget'):
                if parsed.path == '/':
                    self.respond('<ListAllMyBucketsResult><Buckets><Bucket><Name>first</Name></Bucket>'
                                 '<Bucket><Name>second</Name></Bucket></Buckets></ListAllMyBucketsResult>')
                elif mode == 'service-filter':
                    self.respond('<ListBucketResult><IsTruncated>false</IsTruncated>'
                                 '<Contents><Key>a.txt</Key><Size>3</Size><LastModified>2026-11-17T00:00:00Z</LastModified></Contents>'
                                 '<Contents><Key>b.csv</Key><Size>5</Size><LastModified>2026-11-17T00:00:00Z</LastModified></Contents>'
                                 '<Contents><Key>c.bin</Key><Size>7</Size><LastModified>2026-11-17T00:00:00Z</LastModified></Contents></ListBucketResult>')
                else:
                    page = int(query.get('continuation-token', ['0'])[0])
                    contents = ''.join(f'<Contents><Key>key-{page}-{index}</Key><Size>1</Size><LastModified>2026-11-17T00:00:00Z</LastModified></Contents>'
                                       for index in range(1000))
                    truncated = 'true' if page < 59 else 'false'
                    self.respond('<ListBucketResult><IsTruncated>' + truncated + '</IsTruncated>'
                                 + f'<NextContinuationToken>{page + 1}</NextContinuationToken>'
                                 + contents + '</ListBucketResult>')
            elif mode == 'memory-pages':
                page = int(query.get('continuation-token', ['0'])[0])
                truncated = 'true' if page + 1 < Fixture.page_count else 'false'
                self.respond('<ListBucketResult><IsTruncated>' + truncated + '</IsTruncated>'
                             + f'<NextContinuationToken>{page + 1}</NextContinuationToken></ListBucketResult>')
            elif mode == 'parts':
                marker = self.headers.get('x-amz-part-number-marker', '')
                assert marker in ('', '1')
                truncated = 'true' if not marker else 'false'
                self.respond('<GetObjectAttributesOutput><ObjectParts><IsTruncated>' + truncated
                             + '</IsTruncated><NextPartNumberMarker>1</NextPartNumberMarker>'
                             + '<Part><PartNumber>1</PartNumber><Size>4</Size></Part></ObjectParts></GetObjectAttributesOutput>')
            elif mode == 'no-parts':
                self.respond('<GetObjectAttributesOutput><ObjectSize>4</ObjectSize></GetObjectAttributesOutput>')
            elif mode == 'metadata':
                self.respond('', headers={'X-Amz-Meta-Custom': 'preserved', 'x-amz-meta-Other': 'also'})
            elif mode == 'lifecycle':
                if self.command == 'GET':
                    self.respond(Fixture.lifecycle, headers={'x-amz-transition-default-minimum-object-size': 'all_storage_classes_128K'})
                elif self.command == 'PUT':
                    assert self.headers['x-amz-transition-default-minimum-object-size'] == 'all_storage_classes_128K'
                    assert b'TransitionDefaultMinimumObjectSize' not in body
                    Fixture.lifecycle = body.decode()
                    self.respond()
                else:
                    self.respond(status=204)
            elif mode == 'retention':
                if 'retention' in query:
                    assert self.headers.get('x-amz-bypass-governance-retention') == 'true'
                self.respond()
            elif mode in ('versions', 'delete-fail', 'delete-cancel'):
                if self.command == 'GET':
                    assert query['max-keys'] == ['1']
                    assert self.headers.get('x-amz-bypass-governance-retention') is None
                    self.respond('<ListVersionsResult><IsTruncated>false</IsTruncated>'
                                 '<Version><Key>a</Key><VersionId>v1</VersionId></Version>'
                                 '<Version><Key>b</Key><VersionId>v2</VersionId></Version>'
                                 '<Version><Key>c</Key><VersionId>v3</VersionId></Version></ListVersionsResult>')
                else:
                    assert self.headers.get('x-amz-bypass-governance-retention') == 'true'
                    assert query['versionId'][0] in ('v1', 'v2', 'v3')
                    Fixture.deletes += 1
                    if mode == 'delete-cancel' and Fixture.deletes == 2:
                        Fixture.started.set()
                        Fixture.release.wait(5)
                    if mode == 'delete-fail' and Fixture.deletes == 2:
                        self.respond('<Error><Code>AccessDenied</Code></Error>', status=403)
                    else:
                        self.respond(status=204)
            elif mode == 'denied':
                self.respond('<Error><Code>AccessDenied</Code></Error>', status=403)
            elif mode == 'incomplete':
                if 'uploads' in query:
                    self.respond('<ListMultipartUploadsResult><IsTruncated>false</IsTruncated>'
                                 '<Upload><Key>keep.txt</Key><UploadId>upload1</UploadId>'
                                 '<Initiated>2026-11-17T00:00:00Z</Initiated></Upload></ListMultipartUploadsResult>')
                elif 'uploadId' in query:
                    self.respond('<ListPartsResult><IsTruncated>false</IsTruncated>'
                                 '<Part><PartNumber>1</PartNumber><Size>16</Size></Part></ListPartsResult>')
                else:
                    self.respond('<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>')
            elif mode == 'mirror-fail':
                if self.command == 'GET':
                    self.respond('<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>')
                elif self.command == 'HEAD':
                    self.respond(status=404)
                elif self.command == 'PUT':
                    Fixture.deletes += 1
                    if Fixture.deletes == 2:
                        self.respond('<Error><Code>AccessDenied</Code></Error>', status=403)
                    else:
                        self.respond(headers={'ETag': '"test"'})
                else:
                    self.respond(status=204)
            else:
                self.respond()

        do_GET = handle_request
        do_HEAD = handle_request
        do_PUT = handle_request
        do_DELETE = handle_request
        do_POST = handle_request

    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f'http://127.0.0.1:{server.server_port}'
    run('alias set', '--skip-check', 'fixture', endpoint, access, secret)
    # Deliberately dead default verifies that every phase obeys the override.
    run('alias set', '--skip-check', 'override', 'http://127.0.0.1:1', access, secret)

    def reset(mode):
        Fixture.mode = mode
        Fixture.calls = []
        Fixture.deletes = 0
        Fixture.started.clear()
        Fixture.release.clear()

    try:
        def buckets():
            reset('buckets')
            value = run('du', 'fixture', '--fallback')
            assert Fixture.calls[1][2]['continuation-token'] == ['second']
            reset('bucket-loop')
            run('du', 'fixture', '--fallback', expected=1)
            assert len(Fixture.calls) == 2
        check('protocol R01 ListBuckets pages empty/repeated token', buckets)

        def service_filter():
            reset('service-filter')
            value = run('du', 'fixture', '--fallback', '--include', '*.txt', '--include', '*.csv')
            assert value['data']['bytes'] == 16, value
        check('protocol R05 service preserves repeated include filters', service_filter)

        def service_budget():
            reset('service-budget')
            value = run('du', 'fixture', '--fallback', '--exclude', '*', expected=1)
            assert 'budget exceeded' in json.dumps(value).lower() or 'ScanLimitExceeded' in json.dumps(value), value
            assert any(call[1] == '/second' for call in Fixture.calls), 'must reach second bucket'
            assert len(Fixture.calls) < 122, 'must stop before returning full service scan'
        check('protocol R04 cross-bucket cumulative budget counts filtered records', service_budget)

        def memory():
            peaks = []
            for pages in (10, 400):
                reset('memory-pages')
                Fixture.page_count = pages
                process = launch(['du', 'fixture/test-bucket', '--fallback', '--exclude', '*'])
                peak = 0
                try:
                    deadline = time.monotonic() + 35
                    while process.poll() is None:
                        assert time.monotonic() < deadline, 'memory probe timeout'
                        sample = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)],
                                                capture_output=True, text=True, timeout=2)
                        if sample.stdout.strip():
                            peak = max(peak, int(sample.stdout.strip()))
                        time.sleep(0.01)
                    stdout, stderr = process.communicate()
                    assert process.returncode == 0, stderr
                    assert json.loads(stdout)['data']['complete']
                    assert len(Fixture.calls) == pages
                    peaks.append(peak)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            assert peaks[0] > 0 and peaks[1] > 0
            assert peaks[1] - peaks[0] < 32 * 1024, peaks
            return {'pages': [10, 400], 'sampled_peak_rss_kib': peaks,
                    'scope': 'empty pages; 10ms sampling, not an RSS hard limit'}
        check('protocol R04 sampled RSS across 10 and 400 pages', memory)

        def attributes():
            reset('parts')
            value = run('object attributes', 'fixture/test-bucket/a', '--attributes', '["ObjectParts"]', '--all-pages')
            assert len(value['data']['pages']) == 2
            assert Fixture.calls[1][3]['x-amz-part-number-marker'] == '1'
            reset('no-parts')
            value = run('object attributes', 'fixture/test-bucket/a', '--attributes', '["ObjectSize"]', '--all-pages')
            assert value['data']['pages'][0]['ObjectSize'] == 4
        check('protocol ObjectParts integer cursor and absent ObjectParts', attributes)

        def json_stdin():
            reset('no-parts')
            value = run('s3api get-object-attributes', 'fixture', '--input-json', '-',
                        payload=json.dumps({'Bucket': 'test-bucket', 'Key': 'a',
                                            'ObjectAttributes': ['ObjectSize']}).encode())
            assert value['data']['result']['ObjectSize'] == 4
            before = len(Fixture.calls)
            run('s3api get-object-attributes', 'fixture', '--input-json', '-', '--file', '-',
                payload=b'{}', expected=2)
            run('s3api put-object-annotation', 'fixture', '--input-json', '-', '--body', '-',
                '--yes', payload=b'{}', expected=2)
            assert len(Fixture.calls) == before
        check('protocol modeled JSON stdin and conflicting stdin sources reject before network', json_stdin)

        def metadata():
            reset('metadata')
            path = root / 'metadata-request.json'
            path.write_text(json.dumps({'Bucket': 'test-bucket', 'Key': 'a', 'SSECustomerAlgorithm': 'AES256'}))
            value = run('s3api head-object', 'fixture', '--input-json', path)
            assert value['data']['metadata']['custom'] == 'preserved'
            assert value['data']['result']['Metadata'] == value['data']['metadata']
        check('protocol modeled Metadata case-insensitive header map and legacy output', metadata)

        def lifecycle():
            reset('lifecycle')
            Fixture.lifecycle = '<LifecycleConfiguration><Rule><ID>first</ID><Status>Enabled</Status><Filter><Prefix>x/</Prefix></Filter><Expiration><Days>30</Days></Expiration></Rule></LifecycleConfiguration>'
            rule = root / 'fixture-rule.json'
            rule.write_text(json.dumps({'ID': 'second', 'Status': 'Enabled', 'Filter': {'Prefix': 'y/'}, 'Expiration': {'Days': 40}}))
            run('ilm rule add', 'fixture/test-bucket', '--id', 'second', '--file', rule, '--yes')
            run('ilm rule remove', 'fixture/test-bucket', '--id', 'first', '--yes')
            exported = root / 'fixture-lifecycle.json'
            run('ilm rule export', 'fixture/test-bucket', '--output', exported)
            value = json.loads(exported.read_text())
            assert value['TransitionDefaultMinimumObjectSize'] == 'all_storage_classes_128K'
            assert len(value['Rules']) == 1
            run('ilm rule import', 'fixture/test-bucket', exported, '--yes')
        check('protocol lifecycle minimum-size header preservation and file roundtrip', lifecycle)

        def retention():
            reset('retention')
            path = root / 'fixture-lock.json'
            path.write_text(json.dumps({'ObjectLockEnabled': 'Enabled'}))
            run('retention set', '--default', 'fixture/test-bucket', '--file', path, '--yes')
            assert 'object-lock' in Fixture.calls[-1][2]
            run('retention clear', 'fixture/test-bucket/a', '--bypass', '--yes')
            assert 'retention' in Fixture.calls[-1][2]
        check('protocol retention default file consumed flag and bypass header', retention)

        def deletion():
            reset('versions')
            args = ['override/test-bucket', '--versions', '--recursive', '--endpoint', endpoint,
                    '--region', 'us-west-2', '--bucket-lookup', 'path', '--timeout', '5',
                    '--connect-timeout', '2', '--page-size', '1', '--bypass', '--yes']
            value = run('rm', *args)
            assert value['data']['deleted'] == 3
            reset('delete-fail')
            value = run('rm', *args, expected=4)
            summary = value['data']
            assert summary['completed'] == 1 and summary['unstarted'] == 1, summary
            assert summary['outcome_unknown'], summary
            assert Fixture.deletes == 2
        check('protocol R02/R03 version connection overrides bypass and partial failure', deletion)

        def cancellation():
            reset('delete-cancel')
            process = launch(['rm', 'fixture/test-bucket', '--versions', '--recursive',
                              '--page-size', '1', '--bypass', '--yes'])
            try:
                assert Fixture.started.wait(10), 'second deletion never started'
                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
                assert process.returncode == 130 and not stdout, (process.returncode, stderr)
                value = json.loads(stderr)
                assert value['data']['completed'] == 1, value
                assert value['data']['outcome_unknown'], value
                assert Fixture.deletes == 2
            finally:
                Fixture.release.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
        check('protocol R03 SIGINT preserves confirmed progress and unknown in-flight outcome', cancellation)

        def incomplete():
            reset('incomplete')
            value = run('du', 'fixture/test-bucket', '--fallback', '--incomplete', '--min-size', '8', '--max-size', '20')
            assert any('uploadId' in call[2] for call in Fixture.calls)
            assert '16' in json.dumps(value), value
        check('protocol R05 incomplete upload size filter after ListParts', incomplete)

        def errors():
            for command in ('find', 'tree', 'du'):
                reset('denied')
                value = run(command, 'fixture/test-bucket', '--fallback', expected=4)
                assert 'snapshot' in json.dumps(value), value
        check('protocol R07 scanner preserves denial exit code and stage', errors)

        def mirror():
            reset('mirror-fail')
            source = root / 'fixture-source'
            source.mkdir()
            for name in ('a', 'b', 'c'):
                (source / name).write_text(name)
            value = run('mirror', str(source) + '/', 'override/test-bucket/', '--fallback',
                        '--endpoint', endpoint, '--yes', expected=4)
            summary = value['data']
            assert summary['completed'] == 1 and summary['unstarted'] == 1, summary
            assert summary['outcome_unknown'], summary
        check('protocol R03 mirror connection override and partial failure', mirror)
    finally:
        server.shutdown()
        server.server_close()
