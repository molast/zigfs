import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
const source = readFileSync(new URL('../src/features/objects/multipart-upload.ts', import.meta.url), 'utf8')
function fixture() {
  let now = 0, nextId = 0, request
  const timers = new Map()
  class FakeRequest {
    handlers = new Map()
    uploadHandlers = new Map()
    upload = { addEventListener: (name, fn) => this.uploadHandlers.set(name, fn) }
    constructor() { request = this }
    open() {}
    setRequestHeader() {}
    send() {}
    getResponseHeader() { return '0123456789abcdef0123456789abcdef' }
    addEventListener(name, fn) { this.handlers.set(name, fn) }
    abort() { this.aborted = true; this.handlers.get('abort')() }
  }
  const exports = {}
  vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), {
    exports, XMLHttpRequest: FakeRequest, Error,
    require: () => ({ t: key => key }),
    window: {
      setTimeout(fn, delay) { const id = ++nextId; timers.set(id, { at: now + delay, fn }); return id },
      clearTimeout(id) { timers.delete(id) },
    },
  })
  const promise = exports.putPart('url', { size: 1024 }, '', () => {}, () => {})
  return {
    request, promise, timers,
    advance(ms) { now += ms; for (const [id, timer] of timers) if (timer.at <= now) { timers.delete(id); timer.fn() } },
    progress(loaded) { request.uploadHandlers.get('progress')({ loaded, total: 1024, lengthComputable: true }) },
  }
}
test('stalled PUT aborts and rejects as retryable timeout, not user pause', async () => {
  const f = fixture()
  const checked = assert.rejects(f.promise, /partUploadTimedOut/)
  f.advance(60_000)
  await checked
  assert.equal(f.request.aborted, true)
  assert.equal(f.timers.size, 0)
})
test('real byte progress extends idle deadline; duplicate progress does not', async () => {
  const f = fixture()
  const checked = assert.rejects(f.promise, /partUploadTimedOut/)
  f.advance(59_000)
  f.progress(512)
  f.advance(59_000)
  assert.equal(f.request.aborted, undefined)
  f.progress(512)
  f.advance(1000)
  await checked
})
test('success, user pause and total timeout clear the watchdog', async () => {
  const success = fixture()
  success.request.status = 200
  success.request.handlers.get('load')()
  assert.equal(await success.promise, '0123456789abcdef0123456789abcdef')
  assert.equal(success.timers.size, 0)
  const paused = fixture()
  paused.request.abort()
  await assert.rejects(paused.promise, { name: 'AbortError' })
  assert.equal(paused.timers.size, 0)
  const timeout = fixture()
  assert.equal(timeout.request.timeout, 15 * 60 * 1000)
  timeout.request.handlers.get('timeout')()
  await assert.rejects(timeout.promise, /partUploadTimedOut/)
  assert.equal(timeout.timers.size, 0)
})
