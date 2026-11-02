import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const root = fileURLToPath(new URL('../src/', import.meta.url))
const readCatalog = language => JSON.parse(fs.readFileSync(path.join(root, `locales/${language}.json`), 'utf8'))
const flatten = catalog => Object.fromEntries(Object.entries(catalog).flatMap(([module, entries]) => Object.entries(entries).map(([key, value]) => [`${module}.${key}`, value])))
const placeholders = text => [...new Set([...text.matchAll(/\{(\w+)\}/g)].map(match => match[1]))].sort()
function sourceFiles(dir = root) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? sourceFiles(path.join(dir, entry.name)) : /\.tsx?$/.test(entry.name) ? [path.join(dir, entry.name)] : [])
}
function compile(filename, require, globals = {}) {
  const source = fs.readFileSync(path.join(root, filename), 'utf8')
  const result = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } })
  const exports = {}
  vm.runInNewContext(result.outputText, { exports, require, ...globals }, { filename })
  return exports
}
function runtime(stored, storageBlocked = false) {
  let preference = stored
  const document = { documentElement: { lang: '' }, title: '' }
  const events = {}
  let notifications = 0
  const en = readCatalog('en'), zh = readCatalog('zh')
  const api = compile('locales/index.ts', name => {
    if (name === 'react') return { useSyncExternalStore: (subscribe, snapshot) => { subscribe(() => notifications++); return snapshot() } }
    if (name === './en.json') return en
    if (name === './zh.json') return zh
    throw new Error(`Unexpected dependency: ${name}`)
  }, {
    document,
    localStorage: {
      getItem() { if (storageBlocked) throw new Error('Blocked'); return preference },
      setItem(_key, value) { if (storageBlocked) throw new Error('Blocked'); preference = value },
    },
    window: { addEventListener: (name, listener) => { events[name] = listener } },
  })
  return { api, en, zh, document, events, get preference() { return preference }, set preference(value) { preference = value }, get notifications() { return notifications } }
}

test('English and Chinese catalogs have matching keys and placeholders', () => {
  const en = flatten(readCatalog('en')), zh = flatten(readCatalog('zh'))
  assert.deepEqual(Object.keys(en).sort(), Object.keys(zh).sort())
  for (const [key, value] of Object.entries(en)) {
    const [module, name] = key.split('.')
    if (module !== 'labels') assert.match(name, /^[a-z][A-Za-z0-9]*$/, `Use a semantic camelCase key: ${key}`)
    assert.doesNotMatch(name, /_[0-9a-f]{6}$/, `Do not use hash suffixes: ${key}`)
    assert.equal(typeof value, 'string', key)
    assert.ok(value.trim(), key)
    assert.ok(zh[key].trim(), key)
    assert.deepEqual(placeholders(value), placeholders(zh[key]), key)
    if (!['common.chinese', 'common.chineseShort'].includes(key)) assert.doesNotMatch(value, /\p{Script=Han}/u, key)
  }
})

test('Source references exist; user-facing JSX and Chinese copy stay in catalogs', () => {
  const catalog = flatten(readCatalog('en'))
  const protocolText = new Set(['ZigFS', 'ZigFS v0.1.0', 'ZigFS Admin v0.1.0', 'GOVERNANCE', 'COMPLIANCE', 'ETag', 'Apache 2.0', 'Apache License 2.0'])
  for (const file of sourceFiles()) {
    const source = fs.readFileSync(file, 'utf8')
    const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true)
    function visit(node) {
      if (ts.isCallExpression(node) && node.expression.getText(ast) === 't' && ts.isStringLiteral(node.arguments[0])) assert.ok(catalog[node.arguments[0].text], `${file}: ${node.arguments[0].text}`)
      if (ts.isJsxText(node) && /[A-Za-z\p{Script=Han}]/u.test(node.text)) assert.ok(protocolText.has(node.text.trim()), `${file}: inline text ${node.text}`)
      if (ts.isStringLiteral(node)) assert.doesNotMatch(node.text, /\p{Script=Han}/u, `${file}: inline text ${node.text}`)
      ts.forEachChild(node, visit)
    }
    visit(ast)
  }
})

test('English default, saved preference, document metadata and subscribers', () => {
  const state = runtime()
  assert.equal(state.api.getLocale(), 'en')
  assert.equal(state.document.documentElement.lang, 'en')
  state.api.useLocale()
  state.api.setLocale('zh')
  assert.equal(state.preference, 'zh')
  assert.equal(state.notifications, 1)
  assert.equal(state.document.documentElement.lang, 'zh-CN')
  assert.equal(state.api.getFormatLocale(), 'zh-CN')
  state.api.setLocale('zh')
  assert.equal(state.notifications, 1)
  assert.equal(runtime('zh').api.getLocale(), 'zh')
  assert.equal(runtime('invalid').api.getLocale(), 'en')
})

test('Storage failures do not prevent switching; other tabs synchronize', () => {
  const blocked = runtime('zh', true)
  blocked.api.setLocale('zh')
  assert.equal(blocked.api.getLocale(), 'zh')
  const state = runtime('en')
  state.api.useLocale()
  state.preference = 'zh'
  state.events.storage({ key: 'zigfs-admin-locale' })
  assert.equal(state.api.getLocale(), 'zh')
  assert.equal(state.notifications, 1)
  state.preference = null
  state.events.storage({ key: null })
  assert.equal(state.api.getLocale(), 'en')
})

test('Interpolation preserves user data, handles zero, and falls back to English', () => {
  const { api, zh } = runtime('zh')
  const userData = '<script>$&{unexpected}</script>'
  assert.ok(api.t('auth.providerSignIn', { provider: userData }).includes(userData))
  assert.ok(api.t('common.pagination', { page: 0, total: 0 }).includes('0'))
  delete zh.auth.providerSignIn
  assert.equal(api.t('auth.providerSignIn', { provider: 'Example' }), 'Continue with Example')
  assert.equal(api.displayValue('Example bucket'), 'Example bucket')
  assert.equal(api.displayValue('Enabled'), '已启用')
})

test('Changing language does not translate lifecycle protocol values', () => {
  const { api } = runtime()
  const lifecycle = compile('features/buckets/lifecycle.ts', name => {
    assert.equal(name, '@/locales')
    return api
  })
  const rules = [
    { id: 'keep-user-input', enabled: true, prefix: 'reports/', action: 'current-days', days: 7, expirationDate: '' },
    { id: 'disabled-rule', enabled: false, prefix: 'a&b/', action: 'current-days', days: 30, expirationDate: '' },
  ]
  const english = lifecycle.serializeLifecycleConfiguration(rules)
  api.setLocale('zh')
  const chinese = lifecycle.serializeLifecycleConfiguration(rules)
  assert.equal(chinese, english)
  assert.match(chinese, /<Status>Enabled<\/Status>/)
  assert.match(chinese, /<Status>Disabled<\/Status>/)
  assert.match(chinese, /<Prefix>a&amp;b\/<\/Prefix>/)
  assert.match(chinese, /<ID>keep-user-input<\/ID>/)
  assert.equal(api.displayValue('reports/'), 'reports/')
})
