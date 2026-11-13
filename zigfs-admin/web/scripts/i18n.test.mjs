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
  vm.runInNewContext(result.outputText, { exports, require, TextEncoder, ...globals }, { filename })
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


test('Lifecycle tag filters serialize AND, escape values and validate first invalid tag', () => {
  const { api } = runtime()
  const lifecycle = compile('features/buckets/lifecycle.ts', () => api)
  const rule = { ...lifecycle.createLifecycleRule('tags'), prefix: 'logs/', tags: [{ key: 'team', value: 'a&b' }, { key: 'empty', value: '' }] }
  const xml = lifecycle.serializeLifecycleConfiguration([rule])
  assert.match(xml, /<Filter><And><Prefix>logs\/<\/Prefix><Tag><Key>team<\/Key><Value>a&amp;b<\/Value><\/Tag><Tag><Key>empty<\/Key><Value><\/Value><\/Tag><\/And><\/Filter>/)
  const single = lifecycle.serializeLifecycleConfiguration([{ ...rule, prefix: '', tags: [rule.tags[0]] }])
  assert.ok(!single.includes('<And>'))
  assert.equal(lifecycle.lifecycleTagError({ ...rule, tags: [{key:'',value:''},{key:'',value:''}] }).index, 0)
  assert.equal(lifecycle.lifecycleTagError({ ...rule, tags: [{key:'a',value:''},{key:'a',value:'b'}] }).index, 1)
  assert.equal(lifecycle.lifecycleTagError({ ...rule, tags: [{key:'a',value:'x'.repeat(257)}] }).field, 'value')
  assert.ok(lifecycle.lifecycleTagError({ ...rule, action: 'delete-marker' }))
  assert.equal(lifecycle.lifecycleTagError({ ...rule, tags: [{key:'a',value:''}] }), null)
})


test('anonymous rules scope resources and listing, preserve unrelated policy statements', () => {
  const api = compile('features/buckets/anonymousRules.ts', () => { throw new Error('Unexpected import') })
  const deny = { Effect: 'Deny', Principal: '*', Action: 's3:GetObject', Resource: 'arn:aws:s3:::test/private/*' }
  const original = { Version: '2012-10-17', Statement: [deny] }
  for (const access of ['readonly', 'writeonly', 'readwrite']) {
    const rule = { id: 'abc123', prefix: 'public/', access }
    const saved = api.updateRule(original, 'test', rule.id, rule)
    assert.equal(JSON.stringify(api.accessRules(saved, 'test')), JSON.stringify([rule]))
    assert.equal(saved.Statement[0], deny)
    const object = saved.Statement[1]
    assert.equal(object.Resource, 'arn:aws:s3:::test/public/*')
    assert.equal(object.Action.includes('s3:PutObject'), access !== 'readonly')
    assert.equal(object.Action.includes('s3:GetObject'), access !== 'writeonly')
    if (access !== 'writeonly') assert.equal(saved.Statement[2].Condition.StringLike['s3:prefix'][0], 'public/*')
    const removed = api.updateRule(saved, 'test', rule.id)
    assert.equal(JSON.stringify(removed), JSON.stringify(original))
    // A manually edited managed statement must not be silently rewritten.
    saved.Statement[1].Condition = { Bool: { 'aws:SecureTransport': 'true' } }
    assert.equal(api.accessRules(saved, 'test').length, 0)
    assert.equal(api.updateRule(saved, 'test', rule.id).Statement.length, saved.Statement.length)
  }
})


test('adding an existing anonymous prefix replaces grants instead of accumulating permissions', () => {
  const api = compile('features/buckets/anonymousRules.ts', () => { throw new Error('Unexpected import') })
  for (const prefix of ['', 'public/']) {
    const original = { Version: '2012-10-17', Statement: [] }
    const first = api.updateRule(original, 'test', 'aaa', { id: 'aaa', prefix, access: 'readwrite' })
    const other = api.updateRule(first, 'test', 'bbb', { id: 'bbb', prefix: 'other/', access: 'readonly' })
    const replaced = api.updateRule(other, 'test', 'ccc', { id: 'ccc', prefix, access: 'writeonly' })
    const rules = api.accessRules(replaced, 'test')
    assert.equal(rules.length, 2)
    assert.equal(rules.find(rule => rule.prefix === prefix).access, 'writeonly')
    assert.equal(rules.find(rule => rule.prefix === prefix).id, 'aaa')
    assert.equal(rules.find(rule => rule.prefix === 'other/').access, 'readonly')
    assert.ok(!replaced.Statement.some(statement => statement.Sid === 'ZigFSAnonymousaaaList'))
    const object = replaced.Statement.find(statement => statement.Sid === 'ZigFSAnonymousaaaObjects')
    assert.ok(!object.Action.includes('s3:GetObject'))
    assert.ok(object.Action.includes('s3:PutObject'))
  }
})


test('legacy anonymous write rules can be upgraded without losing other statements', () => {
  const api = compile('features/buckets/anonymousRules.ts', () => { throw new Error('Unexpected import') })
  const rule = { id: 'aaa', prefix: 'public/', access: 'writeonly' }
  const original = { Version: '2012-10-17', Statement: api.statements('test', rule, true) }
  assert.equal(api.accessRules(original, 'test')[0].access, 'writeonly')
  const saved = api.updateRule(original, 'test', 'aaa', rule)
  const object = saved.Statement.find(s => s.Sid === 'ZigFSAnonymousaaaObjects')
  for (const action of ['s3:PutObject', 's3:DeleteObjectVersion', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts']) assert.ok(object.Action.includes(action))
  const listing = saved.Statement.find(s => s.Sid === 'ZigFSAnonymousaaaUploads')
  assert.equal(listing.Condition.StringLike['s3:prefix'][0], 'public/*')
  const narrowed = api.updateRule(saved, 'test', 'bbb', { ...rule, access: 'readonly' })
  assert.ok(!narrowed.Statement.some(s => s.Sid.endsWith('Uploads')))
  assert.ok(!narrowed.Statement[0].Action.includes('s3:PutObject'))
})
