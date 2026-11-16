import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import ts from 'typescript'
import vm from 'node:vm'
const source = fs.readFileSync(new URL('../src/features/system/monitoring.ts', import.meta.url), 'utf8')
const exports = {}
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
test('unknown and invalid memory do not become zero; sub-byte rates stay in bytes', () => {
  assert.equal(exports.formatMonitorBytes(null, 'en-US'), '—')
  assert.equal(exports.formatMonitorBytes(NaN, 'en-US'), '—')
  assert.equal(exports.formatMonitorBytes(0, 'en-US'), '0 B')
  assert.equal(exports.formatMonitorBytes(0.5, 'en-US'), '0.5 B')
  assert.equal(exports.formatMonitorBytes(1024, 'en-US'), '1 KiB')
})
test('missing history intervals get null gaps while real zero activity is retained', () => {
  const points = [{ timestamp: 10, qps: 2 }, { timestamp: 20, qps: 0 }, { timestamp: 60, qps: 1 }]
  const result = exports.historyWithGaps(points, 10)
  assert.equal(result.length, 4)
  assert.equal(result[1].qps, 0)
  assert.equal(result[2].timestamp, 30)
  assert.equal(result[2].qps, null)
  assert.equal(points.length, 3)
})

test('restart boundaries break curves even with adjacent observations', () => {
  const result = exports.historyWithGaps([{ timestamp: 100, run_id: 1, qps: 20 }, { timestamp: 102, run_id: 2, qps: 0 }], 10)
  assert.equal(result.length, 3)
  assert.equal(result[1].qps, null)
  assert.equal(result[1].timestamp, 101)
})

test('operation percentiles use actual histogram observations and expose overflow as unavailable', () => {
  assert.equal(exports.operationPercentile({ completed: 0, histogram: [] }, .5), null)
  assert.equal(exports.operationPercentile({ completed: 4, histogram: [1, 2, 1] }, .5), 5)
  assert.equal(exports.operationPercentile({ completed: 4, histogram: [1, 2, 1] }, .99), 10)
  assert.equal(exports.operationPercentile({ completed: 1, histogram: [...Array(13).fill(0), 1] }, .99), null)
})

test('numeric observation timestamps format safely instead of using series labels', () => {
  assert.notEqual(exports.formatMonitorTime(1794800000, 'en-US'), '—')
  for (const value of ['Host CPU', null, undefined, NaN, Infinity, 1e20]) {
    assert.equal(exports.formatMonitorTime(value, 'en-US'), '—')
  }
})
test('gauge zero and unknown draw no fill; tiny percentages end only near the start', () => {
  for (const value of [0, null, undefined, -1, NaN]) assert.equal(exports.gaugeArc(value), null)
  const small = exports.gaugeArc(.1).split(' ')
  assert.ok(Number(small.at(-2)) < 17)
  assert.ok(Number(small.at(-1)) < 100)
  assert.equal(exports.gaugeArc(100), 'M 16 100 A 84 84 0 0 1 184.000000 100.000000')
  assert.equal(exports.gaugeArc(101), exports.gaugeArc(100))
})

test('level meters exclude other runs, stale/future points and missing values', () => {
  const latest = { timestamp: 100, run_id: 2, rss: 20 }
  const history = [{ timestamp: 90, run_id: 1, rss: 900 }, { timestamp: 30, run_id: 2, rss: 800 }, { timestamp: 110, run_id: 2, rss: 700 }, { timestamp: 80, run_id: 2, rss: 40 }, { timestamp: 90, run_id: 2, rss: null }]
  const value = exports.monitorLevel(latest, history, 'rss', 100)
  assert.equal(value.peak, 40)
  assert.equal(value.max, 100)
  assert.equal(value.value, 20)
  assert.equal(value.rising, false)
})
test('level meters distinguish absent observations from true zero and stay finite', () => {
  for (const rss of [null, undefined, NaN, Infinity, -1]) {
    assert.equal(exports.monitorLevel({ timestamp: 100, run_id: 2, rss }, [], 'rss').value, null)
  }
  const zero = exports.monitorLevel({ timestamp: 100, run_id: 2, rss: 0 }, [], 'rss')
  assert.equal(zero.value, 0)
  assert.equal(zero.peak, 0)
  assert.equal(zero.max, 1)
})
