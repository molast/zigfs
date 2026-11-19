import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'

test('generates distinct UUID v4 IDs without crypto.randomUUID', () => {
  const source = readFileSync(new URL('../src/lib/randomId.ts', import.meta.url), 'utf8')
  const exports = {}
  let nextByte = 0
  const crypto = {
    getRandomValues(bytes) {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = nextByte++
      }
      return bytes
    },
  }

  vm.runInNewContext(ts.transpile(source, { module: ts.ModuleKind.CommonJS }), {
    exports,
    crypto,
  })

  const first = exports.randomId()
  const second = exports.randomId()
  assert.match(first, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  assert.notEqual(first, second)
})
