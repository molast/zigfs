import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
function fixture(fail = false) {
  const source = readFileSync(new URL('../src/features/objects/ObjectsView.tsx', import.meta.url), 'utf8')
  const calls = [], downloads = [], errors = [], messages = []
  const context = {
    bucket: 'bucket',
    api: { presignObject: async (...args) => { calls.push(args); if (fail) throw new Error('denied'); return { url: 'https://s3.example/file?signature=bound' } } },
    document: { createElement: () => { const link = { click() { downloads.push({ ...link }) }, remove() {} }; return link }, body: { appendChild() {} } },
    fetch: () => assert.fail('must not fetch or buffer object data'),
    startLoading: () => assert.fail('must not display a blocking download modal'),
    t: key => key, displayFileName: key => key, showToast: message => messages.push(message), notifyError: message => errors.push(message),
  }
  const start = source.indexOf('  function startBrowserDownload(')
  const end = source.indexOf('  async function listAllObjectsForPrefix(', start)
  vm.runInNewContext(ts.transpile(source.slice(start, end), { target: ts.ScriptTarget.ES2022 }), context)
  return { context, calls, downloads, errors, messages }
}
test('40 GiB object is handed directly to browser without fetch/blob or modal', async () => {
  const f = fixture()
  assert.equal(await f.context.download({ key: '目录/视频.mp4', size: 40 * 1024 ** 3 }), true)
  assert.equal(f.calls[0][5].download, true)
  assert.equal(f.downloads[0].href, 'https://s3.example/file?signature=bound')
  assert.equal(f.downloads[0].download, '视频.mp4')
  assert.equal(f.downloads[0].rel, 'noopener noreferrer')
  assert.deepEqual(f.messages, ['objects.downloadStartedValue'])
})
test('historical version uses its own signed attachment link', async () => {
  const f = fixture()
  assert.equal(await f.context.downloadVersion({ key: 'old.txt', version_id: 'version-1' }), true)
  assert.equal(f.calls[0][5].versionId, 'version-1')
  assert.equal(f.calls[0][5].download, true)
  assert.equal(await f.context.downloadVersion({ key: 'old.txt', is_delete_marker: true }), false)
  assert.equal(f.calls.length, 1)
})
test('presign failure remains visible and never starts a transfer', async () => {
  const f = fixture(true)
  assert.equal(await f.context.download({ key: 'denied.txt' }), false)
  assert.deepEqual(f.errors, ['denied'])
  assert.equal(f.downloads.length, 0)
  assert.equal(f.messages.length, 0)
})
