import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

const source = readFileSync(new URL('../src/features/objects/ObjectsView.tsx', import.meta.url), 'utf8')
const ast = ts.createSourceFile('ObjectsView.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
let runUploadSource
function visit(node) {
  if (ts.isFunctionDeclaration(node) && node.name?.text === 'runUpload') {
    runUploadSource = node.getText(ast)
  }
  ts.forEachChild(node, visit)
}
visit(ast)

for (const fails of [false, true]) {
  test(`single PUT ${fails ? 'failure' : 'success'} is reported through tasks without an overlay`, async () => {
    const changes = []
    const progress = []
    const errors = []
    let completed = false
    const context = {
      uploadControl: { current: null },
      cancelledUploadIds: { current: new Set() },
      setUploadSpeed() {},
      setUploading() {},
      setUploadProgress() {},
      performance: { now: () => 0 },
      window: { setInterval() {}, clearInterval() {} },
      updateUploadTask: (_id, value) => changes.push(value),
      reportUploadProgress: loaded => progress.push(loaded),
      api: { presignObject: async () => ({ url: 'https://s3.test/photo.jpg' }) },
      putPart: async (_url, file, _type, report) => {
        report({ loaded: file.size, total: file.size })
        if (fails) throw new Error('offline')
      },
      setCompletedUploads: () => { completed = true },
      setUploadTasks() {},
      load: async (_reset, _prefix, _deleted, background) => assert.equal(background, true),
      prefix: '',
      showDeleted: false,
      notifyError: message => errors.push(message),
    }
    vm.createContext(context)
    vm.runInContext(ts.transpile(runUploadSource, { target: ts.ScriptTarget.ES2022 }), context)
    await context.runUpload({
      uploadId: 'local-1', singleRequest: true, bucket: 'photos', key: 'photo.jpg',
      fileName: 'photo.jpg', uploadedBytes: 0, completedParts: 0,
    }, { size: 12 })
    assert.equal(changes[0].status, 'uploading')
    assert.ok(progress.includes(12))
    assert.equal(completed, !fails)
    assert.deepEqual(errors, fails ? ['offline'] : [])
    if (fails) assert.equal(changes.at(-1).status, 'failed')
    assert.equal(context.uploadControl.current, null)
  })
}
