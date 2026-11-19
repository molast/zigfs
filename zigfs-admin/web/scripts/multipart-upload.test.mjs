import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

const source = readFileSync(new URL('../src/features/objects/multipart-upload.ts', import.meta.url), 'utf8')
const policySource = readFileSync(new URL('../src/features/objects/upload-policy.ts', import.meta.url), 'utf8')
const policy = {}
vm.runInNewContext(ts.transpile(policySource, { module: ts.ModuleKind.CommonJS }), { exports: policy })
const requireModule = name => name === './upload-policy' ? policy : { t: key => key }
const exports = {}
vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), {
  exports, require: requireModule,
})
const { choosePartSize, chooseUploadConcurrency, inferPartSize, uploadPartsConcurrently } = exports
const MiB = 1024 * 1024
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const tick = () => new Promise(resolve => setImmediate(resolve))

test('new uploads adapt sizing while old uploads keep their part boundaries', () => {
  assert.equal(choosePartSize(20 * MiB), 8 * MiB)
  assert.equal(choosePartSize(1024 * MiB), 32 * MiB)
  assert.equal(choosePartSize(4 * 1024 * MiB), 32 * MiB)
  const huge = 5 * 1024 * 1024 * MiB
  assert.ok(Math.ceil(huge / choosePartSize(huge)) <= 10000)
  assert.equal(chooseUploadConcurrency(32 * MiB, 8), 2)
  assert.equal(chooseUploadConcurrency(64 * MiB, 8), 2)
  assert.equal(chooseUploadConcurrency(512 * MiB, 8), 4)
  assert.equal(inferPartSize({ parts: [] }, 1024 * MiB, 8 * MiB), 8 * MiB)
  assert.equal(inferPartSize({ parts: [{ size: 8 * MiB }] }, 1024 * MiB), 8 * MiB)
})

test('CPU hints reduce concurrency without exceeding the payload or connection limits', () => {
  for (const [cores, expected] of [[1, 1], [2, 2], [4, 4], [6, 4], [8, 4], [32, 4]]) {
    assert.equal(chooseUploadConcurrency(512 * MiB, cores), expected)
  }
  assert.equal(chooseUploadConcurrency(64 * MiB, 32), 2)
  assert.equal(chooseUploadConcurrency(512 * MiB, 32), 4)
  for (const missing of [undefined, 0, -1, NaN, Infinity]) {
    assert.equal(chooseUploadConcurrency(32 * MiB, missing), 1)
  }
})

test('default CPU hint comes from the browser at upload time', () => {
  const browserExports = {}
  const navigator = { hardwareConcurrency: 4 }
  vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), {
    exports: browserExports, navigator, require: requireModule,
  })
  assert.equal(browserExports.chooseUploadConcurrency(32 * MiB), 2)
  navigator.hardwareConcurrency = 6
  assert.equal(browserExports.chooseUploadConcurrency(32 * MiB), 2)
})

test('workers refill as each part finishes and never exceed the concurrency limit', async () => {
  const pending = new Map()
  const started = []
  const finished = []
  const run = uploadPartsConcurrently([1, 3, 4, 6, 7], 2, async part => {
    started.push(part)
    const gate = deferred()
    pending.set(part, gate)
    await gate.promise
    pending.delete(part)
    finished.push(part)
  }, () => assert.fail('unexpected stop'))
  assert.deepEqual(started, [1, 3])
  pending.get(3).resolve()
  await tick()
  assert.deepEqual(started, [1, 3, 4])
  assert.equal(pending.size, 2)
  pending.get(4).resolve()
  await tick()
  pending.get(6).resolve()
  await tick()
  pending.get(7).resolve()
  pending.get(1).resolve()
  await run
  assert.deepEqual(finished, [3, 4, 6, 7, 1])
})

test('terminal failure stops scheduling, drains siblings and preserves the original error', async () => {
  const gates = [deferred(), deferred(), deferred()]
  const started = []
  const original = new Error('part failed after retries')
  let stops = 0
  let settled = false
  const run = uploadPartsConcurrently([0, 1, 2, 3, 4], 3, part => {
    started.push(part)
    return gates[part].promise
  }, () => { stops += 1; gates[1].reject(new Error('sibling aborted')) })
  const checked = assert.rejects(run, error => error === original).then(() => { settled = true })
  gates[0].reject(original)
  await tick()
  assert.equal(stops, 1)
  assert.equal(settled, false, 'pending presign/transfer must finish before resume')
  gates[2].resolve()
  await checked
  assert.deepEqual(started, [0, 1, 2])
})

test('pause aborts all active workers and leaves queued parts untouched', async () => {
  const gates = [deferred(), deferred(), deferred()]
  const started = []
  const abort = Object.assign(new Error('paused'), { name: 'AbortError' })
  const run = uploadPartsConcurrently([0, 1, 2, 3], 3, part => {
    started.push(part)
    return gates[part].promise
  }, () => gates.forEach(gate => gate.reject(abort)))
  const checked = assert.rejects(run, { name: 'AbortError' })
  gates[0].reject(abort)
  await checked
  assert.deepEqual(started, [0, 1, 2])
})

function uploadViewFixture() {
  const view = readFileSync(new URL('../src/features/objects/ObjectsView.tsx', import.meta.url), 'utf8')
  const start = view.indexOf('  async function runUpload(')
  const end = view.indexOf('  function pauseUpload(', start)
  const active = new Map()
  const updates = []
  const completions = []
  const task = { uploadId: 'id', bucket: 'bucket', key: 'file', fileSize: 32 * MiB, partSize: 8 * MiB, lastModified: 1, uploadedBytes: 8 * MiB, completedParts: 1 }
  const file = { size: task.fileSize, lastModified: 1, name: 'file', type: '', slice: (start, end) => ({ size: end - start }) }
  const context = {
    ...exports, performance, Map, Set, Date, Error,
    // Worker lifecycle tests use three lanes; sizing/CPU policy is tested above.
    chooseUploadConcurrency: () => 3,
    window: { setInterval: () => 1, clearInterval() {} },
    uploadControl: { current: null },
    cancelledUploadIds: { current: new Set() },
    prefix: '', showDeleted: false,
    setUploadSpeed() {}, setUploading() {}, setUploadProgress() {},
    setCompletedUploads() {}, setUploadTasks() {}, load: async () => {},
    updateUploadTask: (_id, value) => updates.push(value),
    reportUploadProgress: () => {}, showToast() {}, notifyError() {},
    t: key => key, displayFileName: key => key, delay: async () => {},
    abortError: () => Object.assign(new Error('paused'), { name: 'AbortError' }),
    api: {
      getMultipartUpload: async () => ({ parts: [{ part_number: 2, size: 8 * MiB, etag: 'part-2' }] }),
      presignObject: async (...args) => ({ url: String(args.at(-1).partNumber) }),
      completeMultipartUpload: async (...args) => completions.push(args.at(-1)),
    },
    putPart: (url, body, _type, progress, onRequest) => {
      const gate = deferred()
      const part = Number(url)
      const request = { abort: () => gate.reject(context.abortError()) }
      active.set(part, { gate, progress, request, body })
      onRequest(request)
      return gate.promise
    },
  }
  vm.runInNewContext(ts.transpile(view.slice(start, end), { target: ts.ScriptTarget.ES2022 }), context)
  return { context, active, updates, completions, run: () => context.runUpload(task, file) }
}

test('view sums parallel progress, skips persisted parts and completes in part-number order', async () => {
  const f = uploadViewFixture()
  const run = f.run()
  await tick()
  assert.deepEqual([...f.active.keys()], [1, 3, 4])
  f.active.get(1).progress({ loaded: 4 * MiB })
  f.active.get(3).progress({ loaded: 2 * MiB })
  assert.equal(f.updates.at(-1).uploadedBytes, 14 * MiB)
  f.active.get(4).gate.resolve('part-4')
  await tick()
  assert.equal(f.updates.at(-1).uploadedBytes, 22 * MiB)
  assert.equal(f.completions.length, 0)
  f.active.get(1).gate.resolve('part-1')
  f.active.get(3).gate.resolve('part-3')
  await run
  assert.equal(f.completions.length, 1)
  assert.deepEqual(Array.from(f.completions[0], part => part.part_number), [1, 2, 3, 4])
  assert.equal(f.context.uploadControl.current, null)
})

test('view pause drains every request, retains committed progress and never completes', async () => {
  const f = uploadViewFixture()
  const run = f.run()
  await tick()
  const control = f.context.uploadControl.current
  assert.equal(control.requests.size, 3)
  control.paused = true
  control.requests.forEach(request => request.abort())
  await run
  assert.equal(f.completions.length, 0)
  assert.equal(f.updates.at(-1).status, 'paused')
  assert.equal(f.updates.at(-1).uploadedBytes, 8 * MiB)
  assert.equal(control.requests.size, 0)
  assert.equal(f.context.uploadControl.current, null)
})

test('view retries a failed part without double-counting progress or reuploading successful siblings', async () => {
  const f = uploadViewFixture()
  const run = f.run()
  await tick()
  const first = f.active.get(1)
  first.progress({ loaded: 4 * MiB })
  f.active.get(3).progress({ loaded: 2 * MiB })
  f.active.get(4).gate.resolve('part-4')
  first.gate.reject(new Error('network'))
  await tick()
  assert.notEqual(f.active.get(1), first)
  assert.equal(f.updates.at(-1).uploadedBytes, 18 * MiB)
  f.active.get(1).progress({ loaded: 3 * MiB })
  assert.equal(f.updates.at(-1).uploadedBytes, 21 * MiB)
  f.active.get(1).gate.resolve('part-1')
  f.active.get(3).gate.resolve('part-3')
  await run
  assert.equal(f.completions.length, 1)
})

test('view aborts sibling requests after retries are exhausted and reports the original failure', async () => {
  const f = uploadViewFixture()
  const run = f.run()
  await tick()
  const control = f.context.uploadControl.current
  for (let attempt = 0; attempt < 3; attempt += 1) {
    f.active.get(1).gate.reject(new Error('network exhausted'))
    await tick()
  }
  await run
  assert.equal(f.completions.length, 0)
  assert.equal(f.updates.at(-1).status, 'failed')
  assert.equal(f.updates.at(-1).error, 'network exhausted')
  assert.equal(f.updates.at(-1).uploadedBytes, 8 * MiB)
  assert.equal(control.requests.size, 0)
})

test('small and multipart files enter tasks; multipart creation failures stay retryable', async () => {
  const view = readFileSync(new URL('../src/features/objects/ObjectsView.tsx', import.meta.url), 'utf8')
  const start = view.indexOf('  async function beginUploads(')
  const end = view.indexOf('  async function createPath(', start)
  const calls = []
  const completed = []
  let failed = []
  const context = {
    ...exports, ...policy, Date, crypto: { randomUUID: () => 'single' }, bucket: 'test',
    joinObjectPath: (_prefix, name) => name,
    startLoading: () => () => {},
    setCompletedUploads: update => completed.push(...update([])),
    setPendingFiles: files => { failed = files },
    setUploadDialogOpen() {}, setTaskTab() {}, setUploadsPanelOpen() {}, setUploadTasks() {},
    load: async () => {}, notifyError() {}, t: key => key,
    api: {
      presignObject: async (...args) => { calls.push(['presign', ...args]); return { url: 'signed' } },
      createMultipartUpload: async (...args) => { calls.push(['multipart', ...args]); return { upload_id: 'multi' } },
    },
    putPart: async (_url, body) => { calls.push(['put', body.size]) },
    runUpload: async task => { calls.push(['run', task.partSize]) },
  }
  vm.runInNewContext(ts.transpile(view.slice(start, end), { target: ts.ScriptTarget.ES2022 }), context)
  await context.beginUploads([{ name: 'small', size: 16 * MiB - 1 }, { name: 'large', size: 16 * MiB }], '')
  assert.deepEqual(calls.map(call => call[0]), ['multipart', 'run', 'run'])
  assert.equal(calls.at(-1)[1], 8 * MiB)
  assert.equal(completed.length, 0)
  assert.equal(failed.length, 0)
  context.api.createMultipartUpload = async () => { throw new Error('upload denied') }
  await context.beginUploads([{ name: 'failed', size: 16 * MiB }], '')
  assert.equal(failed[0].name, 'failed')
  assert.equal(completed.length, 0)
})
