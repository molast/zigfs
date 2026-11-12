import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

function load() {
  const source = fs.readFileSync(new URL('../src/lib/dateTime.ts', import.meta.url), 'utf8')
  let locale = 'en-US', notifications = 0, subscribe
  const exports = {}
  const require = name => name === 'react'
    ? { useSyncExternalStore: (listener, snapshot) => { subscribe = listener(() => notifications++); return snapshot() } }
    : { getFormatLocale: () => locale }
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports, require, Intl, Date, Map, Set, Number, JSON })
  return { api: exports, locale: value => { locale = value }, count: () => notifications, unsubscribe: () => subscribe?.() }
}

test('fixed formats handle timezone date rollover and midnight without changing the instant', () => {
  const { api } = load(), date = new Date('2026-11-12T00:00:00Z')
  assert.equal(api.formatDateTime(date, { timezone: 'UTC', date_format: 'ymd' }), '2026-11-12 00:00:00')
  assert.equal(api.formatDateTime(date, { timezone: 'America/New_York', date_format: 'dmy' }), '11/11/2026 19:00:00')
  assert.equal(api.formatDateTime(date, { timezone: 'Asia/Shanghai', date_format: 'mdy' }), '11/12/2026 08:00:00')
  assert.equal(date.toISOString(), '2026-11-12T00:00:00.000Z')
  assert.equal(api.formatDate(date, { timezone: 'Asia/Shanghai', date_format: 'ymd' }), '2026-11-12')
  assert.equal(api.formatTime(date, { timezone: 'Asia/Shanghai', date_format: 'ymd' }), '08:00:00')
})

test('IANA timezone applies DST transitions instead of a fixed UTC offset', () => {
  const { api } = load(), prefs = { timezone: 'America/New_York', date_format: 'ymd' }
  assert.equal(api.formatDateTime('2026-03-08T06:59:59Z', prefs), '2026-03-08 01:59:59')
  assert.equal(api.formatDateTime('2026-03-08T07:00:00Z', prefs), '2026-03-08 03:00:00')
  assert.equal(api.formatDateTime('2026-11-01T06:00:00Z', prefs), '2026-11-01 01:00:00')
})

test('locale format follows language and browser timezone follows the runtime', () => {
  const { api, locale } = load(), date = new Date('2026-11-12T12:00:00Z')
  const options = { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }
  assert.equal(api.formatDateTime(date), new Intl.DateTimeFormat('en-US', options).format(date))
  locale('zh-CN')
  assert.equal(api.formatDateTime(date), new Intl.DateTimeFormat('zh-CN', options).format(date))
})

test('invalid dates are safe and preference changes notify existing views without remounting', () => {
  const { api, count, unsubscribe } = load()
  for (const value of [null, undefined, '', 'invalid']) assert.equal(api.formatDateTime(value), '—')
  api.useDisplayPreferences()
  api.setDisplayPreferences({ timezone: 'UTC', date_format: 'ymd' })
  assert.equal(count(), 1)
  api.setDisplayPreferences({ timezone: 'UTC', date_format: 'ymd' })
  assert.equal(count(), 1)
  assert.equal(api.formatDateTime(0), '1970-01-01 00:00:00')
  unsubscribe()
})
