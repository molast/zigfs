import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

const exports = {}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(new URL('../src/features/system/diagnostics.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
const { serviceHealth } = exports
const ready = () => ({ status: 'ready', recovery: 'ready', diagnostics: { storage: { state: 'online', online: 1, offline: 0, read_only: false }, metadata: { ready: true } } })

test('healthy requires measured filesystem and initialized metadata, not just recovery readiness', () => {
  assert.equal(serviceHealth(ready(), 0), 'healthy')
  assert.equal(serviceHealth(null, 0), 'unknown')
  assert.equal(serviceHealth({ status: 'ready', recovery: 'ready' }, 0), 'unknown')
  assert.equal(serviceHealth(ready(), 1), 'unknown')
  const unavailable = ready()
  unavailable.diagnostics.storage.state = 'unknown'
  assert.equal(serviceHealth(unavailable, 0), 'unknown')
})

test('offline, read-only, failed scanner and unavailable index are never green', () => {
  for (const mutate of [
    health => { health.diagnostics.storage.state = 'offline' },
    health => { health.diagnostics.storage.read_only = true },
    health => { health.diagnostics.metadata.ready = false },
    health => { health.recovery = 'recovery_required' },
  ]) {
    const health = ready()
    mutate(health)
    assert.equal(serviceHealth(health, 0), 'attention')
  }
  assert.equal(serviceHealth(ready(), 0, false), 'attention')
})
