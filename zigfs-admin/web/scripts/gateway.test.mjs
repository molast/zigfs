import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

const source = readFileSync(new URL('../src/features/settings/gateway.ts', import.meta.url), 'utf8')
const deployment = { id: 'revision-1', admin_url: 'https://admin.test', s3_url: 'https://s3.test' }
function verifier(fetch) {
  const exports = {}
  vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), {
    exports, fetch, AbortSignal,
  })
  return exports.verifyGatewayFromBrowser
}

test('browser verification probes both endpoints without cookies or redirects', async () => {
  const calls = []
  const verify = verifier(async (url, options) => {
    calls.push(url)
    assert.equal(options.credentials, 'omit')
    assert.equal(options.redirect, 'error')
    return { ok: true, text: async () => deployment.id }
  })
  await verify(deployment)
  assert.deepEqual(calls, ['https://admin.test/_gateway/probe', 'https://s3.test/_gateway/probe'])
})

test('a stale gateway or network failure cannot be treated as verified', async () => {
  await assert.rejects(verifier(async () => ({ ok: true, text: async () => 'wrong' }))(deployment))
  await assert.rejects(verifier(async () => { throw new TypeError('TLS failed') })(deployment))
})
