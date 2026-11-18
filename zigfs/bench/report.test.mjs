import assert from 'node:assert/strict'
import test from 'node:test'

import { redactCommand } from './report.mjs'

test('redacts administrator passwords from benchmark commands', () => {
  const password = 'test-secret-value'
  const commands = [
    `node run.mjs --admin-password ${password} --profile smoke`,
    `node run.mjs --admin-password=${password} --profile smoke`,
    `node run.mjs --admin-password "${password}" --profile smoke`,
    `node run.mjs --admin-password '${password}' --profile smoke`,
    `wrapper --token=${password} node run.mjs --profile smoke`,
  ]

  for (const command of commands) {
    const redacted = redactCommand(command, password)
    assert.equal(redacted.includes(password), false)
    assert.equal(redacted.includes('[REDACTED]'), true)
  }
})
