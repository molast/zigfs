import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

function load(path) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(new URL(path, import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports })
  return exports
}
const { accountStatusKey } = load('../src/features/account/accountStatus.ts')
const { loadBucketSnapshot } = load('../src/features/buckets/bucketSnapshot.ts')

test('account status uses explicit local enabled flags and respects external identity sources', () => {
  assert.equal(accountStatusKey({ auth_source: 'local', account_enabled: true }), 'account.enabled')
  assert.equal(accountStatusKey({ auth_source: 'local', account_enabled: false }), 'account.disabledStatus')
  for (const value of [undefined, null]) assert.equal(accountStatusKey({ auth_source: 'local', account_enabled: value }), 'account.statusUnknown')
  assert.equal(accountStatusKey({ auth_source: 'deployment' }), 'account.deploymentManagedStatus')
  assert.equal(accountStatusKey({ auth_source: 'oidc' }), 'account.externalManagedStatus')
  assert.equal(accountStatusKey({ auth_source: 'sts' }), 'account.credentialManagedStatus')
})

test('missing configuration is unknown even when bucket inventory and usage succeed', async () => {
  const result = await loadBucketSnapshot({
    listBuckets: async () => [{ name: 'public-bucket', owner: 'alice' }],
    getBucketConfiguration: async () => { throw new Error('forbidden') },
    getBucketUsage: async () => ({ bytes: 0, objects: 0 }),
  }, 'public-bucket')
  assert.equal(result.bucket.name, 'public-bucket')
  assert.equal(result.configuration, null)
  assert.equal(result.usage.bytes, 0)
  assert.equal(result.errors.length, 1)
})

test('usage errors preserve actual public access policy and do not become fake zero usage', async () => {
  const api = {
    listBuckets: async () => [{ name: 'public-bucket' }],
    getBucketConfiguration: async name => ({ name, access_policy: 'Public' }),
    getBucketUsage: async () => { throw new Error('unavailable') },
  }
  const result = await loadBucketSnapshot(api, 'public-bucket')
  assert.equal(result.configuration.access_policy, 'Public')
  assert.equal(result.usage, null)
  api.getBucketConfiguration = async () => { throw new Error('offline') }
  const refreshed = await loadBucketSnapshot(api, 'public-bucket')
  assert.equal(refreshed.configuration, null)
  assert.equal(refreshed.errors.length, 2)
})
