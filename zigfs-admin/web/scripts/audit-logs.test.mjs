import assert from 'node:assert/strict'
import test from 'node:test'
import { filterAuditLogContent } from '../src/features/logs/auditLogs.ts'

test('audit download keeps original JSON/text format and applies active filters', () => {
  const event = { event_id: 'a', event_category: 'object_storage', event_action: 'PutObject', event_type: 'api_request', request: { request_id: 'req-1', source_ip: '127.0.0.1' }, identity: { principal_name: 'alice' }, resource: { bucket: 'photos' }, operation: { service: 's3' }, response: { status: 'success' } }
  const json = JSON.stringify(event)
  const text = `123 info [audit] ${json}`
  const other = JSON.stringify({ ...event, event_id: 'b', response: { status: 'denied' } })
  const result = filterAuditLogContent([json, text, other, 'invalid'].join('\n'), { category: 'object_storage', action: 'PutObject', actor: 'alice', outcome: 'success', bucket: 'photos', request_id: 'req-1', service: 's3', event_type: 'api_request', source_ip: '127.0.0.1' })
  assert.equal(result, [json, text].join('\n'))
  assert.equal(filterAuditLogContent(json, { actor: 'bob' }), '')
})
