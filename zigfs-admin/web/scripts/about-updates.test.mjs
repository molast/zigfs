import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

// Exercise button interactions and asynchronous completion with a minimal hook host.
function mount(api) {
  const states = [], cleanups = [], notifications = []
  let cursor = 0
  const hooks = {
    useState(initial) {
      const index = cursor++
      if (!(index in states)) states[index] = initial
      return [states[index], value => { states[index] = value }]
    },
    useRef(initial) {
      const index = cursor++
      return states[index] ??= { current: initial }
    },
    useEffect(effect) {
      const index = cursor++
      if (!(index in states)) { states[index] = true; cleanups.push(effect()) }
    },
  }
  const jsx = (type, props) => ({ type, props })
  const exports = {}
  const require = name => {
    if (name === 'react') return hooks
    if (name === 'react/jsx-runtime') return { jsx, jsxs: jsx, Fragment: 'fragment' }
    if (name.includes('Button')) return { Button: 'button' }
    if (name.includes('ToastProvider')) return { useErrorToast: () => value => notifications.push(value) }
    if (name.includes('dateTime')) return { formatDateTime: String }
    if (name.includes('locales')) return { t: (key, values) => key + (values ? JSON.stringify(values) : '') }
    return {}
  }
  const source = fs.readFileSync(new URL('../src/features/settings/AboutTelemetry.tsx', import.meta.url), 'utf8')
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require })
  return {
    render() { cursor = 0; return exports.AboutUpdates({ api }) },
    unmount() { cleanups.forEach(fn => fn?.()) },
    notifications,
  }
}
const button = tree => tree.props.children[0]

test('update check disables the button, shows release results, and never renders success on API errors', async () => {
  let resolve, reject
  const host = mount({ checkUpdates: () => new Promise((yes, no) => { resolve = yes; reject = no }) })
  const pending = button(host.render()).props.onClick()
  assert.equal(button(host.render()).props.disabled, true)
  reject(new Error('HTTP 404'))
  await pending
  await new Promise(setImmediate)
  assert.equal(button(host.render()).props.disabled, false)
  assert.match(JSON.stringify(host.render()), /settings.updateCheckFailed/)
  assert.doesNotMatch(JSON.stringify(host.render()), /settings.noNewerRelease/)
  assert.equal(host.notifications.length, 1)

  button(host.render()).props.onClick()
  resolve({ latest_version: '0.2.0', update_available: true, release_url: 'https://github.com/molast/zigfs/releases/tag/v0.2.0', checked_at: 100 })
  await new Promise(setImmediate)
  assert.match(JSON.stringify(host.render()), /settings.updateAvailable/)
  assert.match(JSON.stringify(host.render()), /releases\/tag\/v0.2.0/)
  assert.doesNotMatch(JSON.stringify(host.render()), /settings.updateCheckFailed/)
})

test('leaving About while a request is pending suppresses stale error notifications', async () => {
  let reject
  const host = mount({ checkUpdates: () => new Promise((_, no) => { reject = no }) })
  button(host.render()).props.onClick()
  host.unmount()
  reject(new Error('offline'))
  await new Promise(setImmediate)
  assert.equal(host.notifications.length, 0)
})
