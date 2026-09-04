import { writeFile } from 'node:fs/promises'

const [, , endpoint, outputPath] = process.argv
if (!endpoint || !outputPath) throw new Error('usage: node provision.mjs <endpoint> <output-path>')

async function request(path, init) {
  const response = await fetch(`${endpoint}${path}`, init)
  if (!response.ok) {
    throw new Error(`Management request ${path} failed with ${response.status}: ${await response.text()}`)
  }
  return response
}

const loginResponse = await request('/_admin/v1/auth/login', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ username: 'phase7-admin', password: 'phase7-admin-password' }),
})
const login = await loginResponse.json()

const credentialResponse = await request('/_admin/v1/access-keys', {
  method: 'POST',
  headers: {
    authorization: `Bearer ${login.token}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify({ owner: 'phase7-sdk' }),
})
const credential = await credentialResponse.json()

await writeFile(outputPath, JSON.stringify({
  endpoint,
  access_key: credential.access_key,
  secret_key: credential.secret_key,
  region: 'us-east-1',
  owner: credential.owner,
}), { encoding: 'utf8', mode: 0o600 })

console.log('Isolated ZigFS credential provisioned')
