import assert from 'node:assert/strict'
import test from 'node:test'
import { parseSystemLogs, filterSystemLogs, logHistogram } from '../src/features/logs/systemLogs.ts'

test('normalizes structured, legacy JSON, text and unparsed records without invented timestamps', () => {
  const logs = parseSystemLogs([
    JSON.stringify({ schema_version: '1.0', timestamp: '2026-11-11T10:00:00.123Z', level: 'ERROR', message: 'KMS unavailable', service: { name: 'zigfs', instance_id: 'node-1' }, source: { type: 'application', component: 'kms' }, context: { request_id: 'req-1' }, error: { code: 'Unavailable' } }),
    JSON.stringify({ timestamp: 100, level: 'warning', scope: 'storage', message: 'retry' }),
    '+150 info [default] http request request_id=req-2', 'broken text', '{"timestamp":"bad","message":"bad date"}',
  ].join('\n'))
  assert.equal(logs[0].context.request_id, 'req-1')
  assert.equal(logs[0].error.code, 'Unavailable')
  assert.equal(logs[1].level, 'WARN')
  assert.equal(logs[2].source.component, 'api')
  assert.equal(logs[2].context.request_id, 'req-2')
  assert.equal(logs[3].timestamp, null)
  assert.equal(logs[3].raw, 'broken text')
  assert.equal(logs[4].metadata.parse_status, 'unparsed')
  const filtered = filterSystemLogs(logs, { level: 'ERROR', component: 'kms', source: 'application', keyword: 'REQ-1' })
  assert.equal(filtered.length, 1)
  assert.equal(filterSystemLogs(logs, { level: 'WARN', component: 'kms', source: 'all', keyword: '' }).length, 0)
  const bins = logHistogram(logs, 100, 150)
  assert.equal(bins.reduce((sum, bin) => sum + bin.WARN + bin.INFO, 0), 2)
  assert.equal(bins.reduce((sum, bin) => sum + bin.ERROR + bin.UNKNOWN, 0), 0)
})


test('histogram includes milliseconds throughout the inclusive end second', () => {
  const logs = parseSystemLogs(JSON.stringify({ timestamp: '1970-01-01T00:02:30.999Z', level: 'INFO', message: 'boundary' }))
  assert.equal(logHistogram(logs, 100, 150).reduce((sum, bin) => sum + bin.INFO, 0), 1)
})

test('text diagnostics retain multiline stacks and historical access noise is excluded', () => {
  const details = { source: { type: 'application', component: 'storage', file: 'store.zig', line: 12, function: 'write' }, error: { code: 'IOError', type: 'RuntimeError', stack_trace: 'store.zig:12: write\napi.zig:10: upload', trace_kind: 'error_return' } }
  const logs = parseSystemLogs(`150 error [storage] write failed\t@zigfs:${JSON.stringify(details)}\n150 info [api] http request method=GET path=/_admin/v1/settings/logs/query status=200 request_id=req-1 duration_ms=+1`)
  assert.equal(logs.length, 1)
  assert.equal(logs[0].message, 'write failed')
  assert.equal(logs[0].error.stack_trace, details.error.stack_trace)
  assert.equal(logs[0].source.file, 'store.zig')
  assert.equal(logs[0].error.trace_kind, 'error_return')
  assert.equal(filterSystemLogs(logs, { level: 'all', component: 'all', source: 'all', keyword: 'api.zig' }).length, 1)
})
