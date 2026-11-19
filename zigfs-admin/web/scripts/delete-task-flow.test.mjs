import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

const source = readFileSync(new URL('../src/features/objects/ObjectsView.tsx', import.meta.url), 'utf8')
const start = source.indexOf('  async function trackDeletion(')
const end = source.indexOf('  async function deleteObjectKey(', start)

for (const fails of [false, true]) {
  test(`deletion shows processing before settling as ${fails ? 'failed' : 'completed'}`, async () => {
    let tasks = []
    let panelOpen = false
    let tab = 'completed'
    let settle
    const operation = new Promise((resolve, reject) => {
      settle = () => fails ? reject(new Error('delete denied')) : resolve()
    })
    const context = {
      crypto: { randomUUID: () => 'delete-1' },
      setDeleteTasks: update => { tasks = update(tasks) },
      setTaskTab: value => { tab = value },
      setUploadsPanelOpen: value => { panelOpen = value },
    }
    vm.createContext(context)
    vm.runInContext(ts.transpile(source.slice(start, end), { target: ts.ScriptTarget.ES2022 }), context)
    const result = context.trackDeletion('photo.jpg', false, () => operation)
    assert.equal(tasks[0].status, 'processing')
    assert.equal(panelOpen, true)
    assert.equal(tab, null)
    // A task finishing must not reopen a panel the user has dismissed.
    panelOpen = false
    settle()
    if (fails) {
      await assert.rejects(result, /delete denied/)
      assert.equal(tasks[0].error, 'delete denied')
    } else {
      await result
    }
    assert.equal(tasks[0].status, fails ? 'failed' : 'completed')
    assert.equal(panelOpen, false)
  })
}
