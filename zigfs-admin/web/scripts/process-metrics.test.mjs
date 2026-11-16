import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

const exports = {}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(new URL('../src/features/settings/processMetrics.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
const { processCPUPercent } = exports
const sample = (uptime, cpu, time) => ({ uptime, process: { cpu_seconds: cpu, sampled_at_seconds: time } })

test('CPU uses interval deltas and supports idle and multi-core utilization', () => {
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(15, 2.5, 105)), 10)
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(15, 2, 105)), 0)
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(15, 12, 105)), 200)
})
test('missing data, restart and invalid intervals never become fake zero metrics', () => {
  assert.equal(processCPUPercent(null, sample(10, 2, 100)), null)
  assert.equal(processCPUPercent(sample(10, 2, 100), { uptime: 11, process: null }), null)
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(1, 3, 105)), null)
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(15, 1, 105)), null)
  assert.equal(processCPUPercent(sample(10, 2, 100), sample(15, 3, 100)), null)
})
