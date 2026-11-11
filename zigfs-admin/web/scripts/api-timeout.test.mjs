import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

function fixture() {
  const timers = new Map()
  let now = 0
  let nextId = 0
  let pending
  const exports = {}
  const context = {
    exports, Headers, AbortController, CustomEvent,
    require: () => ({ t: key => key }),
    window: {
      dispatchEvent() {},
      setTimeout(fn, ms) { const id = ++nextId; timers.set(id, { at: now + ms, fn }); return id },
      clearTimeout(id) { timers.delete(id) },
    },
    fetch: (_path, init) => new Promise((resolve, reject) => {
      pending = { resolve, signal: init.signal }
      init.signal.addEventListener('abort', () => reject(new Error('aborted')))
    }),
  }
  const source = readFileSync(new URL('../src/api/client.ts', import.meta.url), 'utf8')
  vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), context)
  return {
    api: exports.createApiClient(), timers,
    advance(ms) { now += ms; for (const [id, timer] of timers) if (timer.at <= now) { timers.delete(id); timer.fn() } },
    respond(value) { pending.resolve({ ok: true, status: 200, json: async () => value }) },
    aborted: () => pending.signal.aborted,
  }
}

test('multipart completion survives a 53-second publish and clears its timer', async () => {
  const f = fixture()
  const result = f.api.completeMultipartUpload('upload', 'bucket', 'video.mp4', [{ part_number: 1, etag: 'etag' }])
  f.advance(53000)
  assert.equal(f.aborted(), false)
  f.respond({ key: 'video.mp4' })
  assert.equal((await result).key, 'video.mp4')
  assert.equal(f.timers.size, 0)
})

test('ordinary requests still time out after 15 seconds', async () => {
  const f = fixture()
  const result = f.api.listBuckets()
  f.advance(15000)
  await assert.rejects(result, /requestTimedOut/)
  assert.equal(f.timers.size, 0)
})

test('completion still has a bounded timeout', async () => {
  const f = fixture()
  const result = f.api.completeMultipartUpload('upload', 'bucket', 'video.mp4', [])
  f.advance(16 * 60 * 1000)
  await assert.rejects(result, /requestTimedOut/)
  assert.equal(f.timers.size, 0)
})
