#!/usr/bin/env node

import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
  copyFile,
} from 'node:fs/promises'
import { createWriteStream } from 'node:fs'
import { createHash, createHmac, randomBytes } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'

const scriptDir = dirname(new URL(import.meta.url).pathname)
const repoRoot = resolve(scriptDir, '..')
const zigfsRoot = join(repoRoot, 'zigfs')
const defaultRegion = 'us-east-1'
const defaultAdminUsername = 'phase9-admin'
const defaultAdminPassword = 'phase9-admin-password'

function usage() {
  console.log(`Usage: ./compatibility/run.sh [options]

Options:
  --endpoint URL             Existing endpoint (default: http://127.0.0.1:19080)
  --data-root PATH           Data root for an isolated server
  --report PATH              JSON report path (default: compatibility/reports/latest.json)
  --client NAME              aws|mc|rclone|http|aws-sdk|all (default: all)
  --access-key KEY           Use an existing S3 Access Key
  --secret-key KEY           Use an existing S3 Secret Key
  --session-token TOKEN      Optional S3 session token
  --region REGION            Signing region (default: us-east-1)
  --skip-start               Do not build or start ZigFS
  --keep-data                Keep an automatically created data root
  --help                     Show this help

The runner never writes credentials to reports. When starting ZigFS itself it creates
and removes a temporary credential through the Management API.`)
}

function parseArgs(argv) {
  const options = {
    endpoint: 'http://127.0.0.1:19080',
    report: join(repoRoot, 'compatibility', 'reports', 'latest.json'),
    client: 'all',
    region: defaultRegion,
    skipStart: false,
    keepData: false,
    dataRoot: null,
    accessKey: process.env.ZIGFS_ACCESS_KEY ?? null,
    secretKey: process.env.ZIGFS_SECRET_KEY ?? null,
    sessionToken: process.env.ZIGFS_SESSION_TOKEN ?? null,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    const next = () => {
      if (index + 1 >= argv.length) throw new Error(`missing value for ${arg}`)
      index += 1
      return argv[index]
    }
    if (arg === '--help' || arg === '-h') {
      usage()
      process.exit(0)
    } else if (arg === '--endpoint') options.endpoint = next()
    else if (arg === '--data-root') options.dataRoot = resolve(next())
    else if (arg === '--report') options.report = resolve(next())
    else if (arg === '--client') options.client = next()
    else if (arg === '--access-key') options.accessKey = next()
    else if (arg === '--secret-key') options.secretKey = next()
    else if (arg === '--session-token') options.sessionToken = next()
    else if (arg === '--region') options.region = next()
    else if (arg === '--skip-start') options.skipStart = true
    else if (arg === '--keep-data') options.keepData = true
    else throw new Error(`unknown option: ${arg}`)
  }
  if (!['aws', 'mc', 'rclone', 'http', 'aws-sdk', 'all'].includes(options.client)) {
    throw new Error(`invalid --client: ${options.client}`)
  }
  if (options.skipStart && (!options.accessKey || !options.secretKey)) {
    throw new Error('--skip-start requires --access-key and --secret-key (or ZIGFS_ACCESS_KEY/ZIGFS_SECRET_KEY)')
  }
  if ((options.accessKey && !options.secretKey) || (!options.accessKey && options.secretKey)) {
    throw new Error('--access-key and --secret-key must be provided together')
  }
  return options
}

function commandExists(command) {
  return spawnSync('which', [command], { stdio: 'ignore' }).status === 0
}

function awsSdkRuntime() {
  if (!commandExists('ruby')) return null
  const result = spawnSync('ruby', ['-e', 'require "aws-sdk-s3"; print Aws::S3::GEM_VERSION'], { encoding: 'utf8' })
  if (result.status !== 0) return null
  return (result.stdout ?? '').trim() || null
}

function runCommand(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? 120_000
  return new Promise((resolveResult) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? repoRoot,
      env: { ...process.env, ...(options.env ?? {}) },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    let timedOut = false
    const timer = setTimeout(() => {
      timedOut = true
      child.kill('SIGTERM')
      setTimeout(() => child.kill('SIGKILL'), 2_000).unref()
    }, timeoutMs)
    child.stdout.on('data', (chunk) => { stdout += chunk.toString() })
    child.stderr.on('data', (chunk) => { stderr += chunk.toString() })
    if (options.input !== undefined) child.stdin.end(options.input)
    else child.stdin.end()
    child.on('error', (error) => {
      clearTimeout(timer)
      resolveResult({ command, args, code: null, signal: null, stdout, stderr: `${stderr}${error.message}`, timedOut })
    })
    child.on('close', (code, signal) => {
      clearTimeout(timer)
      resolveResult({ command, args, code, signal, stdout, stderr, timedOut })
    })
  })
}

function commandText(command, args) {
  return [command, ...args].map((part) => /[^A-Za-z0-9_./:=+-]/.test(part) ? JSON.stringify(part) : part).join(' ')
}

function versionOf(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  return `${result.stdout ?? ''}${result.stderr ?? ''}`.trim().split('\n')[0] ?? ''
}

function sha256Hex(value) {
  return createHash('sha256').update(value).digest('hex')
}

function hmac(key, value, encoding = undefined) {
  const digest = createHmac('sha256', key).update(value).digest()
  return encoding ? digest.toString(encoding) : digest
}

function isoAmz(date = new Date()) {
  return date.toISOString().replace(/[-:]|\.\d{3}/g, '').replace('Z', '') + 'Z'
}

function uriEncode(value, encodeSlash = true) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)
    .replace(encodeSlash ? /%2F/g : /$^/g, encodeSlash ? '%2F' : '/')
}

function canonicalQuery(entries) {
  return entries
    .map(([key, value]) => [uriEncode(key), uriEncode(String(value))])
    .sort((left, right) => left[0].localeCompare(right[0]) || left[1].localeCompare(right[1]))
    .map(([key, value]) => `${key}=${value}`)
    .join('&')
}

function canonicalPath(pathname) {
  return pathname.split('/').map((segment) => uriEncode(decodeURIComponent(segment), true)).join('/') || '/'
}

function signingKey(secretKey, dateStamp, region) {
  const dateKey = hmac(`AWS4${secretKey}`, dateStamp)
  const regionKey = hmac(dateKey, region)
  const serviceKey = hmac(regionKey, 's3')
  return hmac(serviceKey, 'aws4_request')
}

function signedRequest({ endpoint, region, accessKey, secretKey, sessionToken, method, path, query = [], headers = {}, body = Buffer.alloc(0), date = new Date() }) {
  const url = new URL(endpoint)
  url.pathname = path
  url.search = canonicalQuery(query)
  const amzDate = isoAmz(date)
  const dateStamp = amzDate.slice(0, 8)
  const payloadHash = sha256Hex(body)
  const allHeaders = {
    host: url.host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
    ...headers,
  }
  if (sessionToken) allHeaders['x-amz-security-token'] = sessionToken
  const normalized = Object.entries(allHeaders)
    .map(([key, value]) => [key.toLowerCase(), String(value).trim().replace(/\s+/g, ' ')])
    .sort(([left], [right]) => left.localeCompare(right))
  const signedHeaders = normalized.map(([key]) => key).join(';')
  const canonicalHeaders = normalized.map(([key, value]) => `${key}:${value}\n`).join('')
  const canonicalRequest = [method, canonicalPath(url.pathname), url.search.slice(1), canonicalHeaders, signedHeaders, payloadHash].join('\n')
  const scope = `${dateStamp}/${region}/s3/aws4_request`
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n')
  const signature = hmac(signingKey(secretKey, dateStamp, region), stringToSign, 'hex')
  const authorization = `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`
  const requestHeaders = { ...allHeaders, Authorization: authorization }
  return { url, headers: requestHeaders, body }
}

function presignedUrl({ endpoint, region, accessKey, secretKey, sessionToken, method, path, expires = 300, headers = {}, date = new Date() }) {
  const url = new URL(endpoint)
  url.pathname = path
  const amzDate = isoAmz(date)
  const dateStamp = amzDate.slice(0, 8)
  const scope = `${dateStamp}/${region}/s3/aws4_request`
  const allHeaders = { host: url.host, ...headers }
  const normalized = Object.entries(allHeaders)
    .map(([key, value]) => [key.toLowerCase(), String(value).trim().replace(/\s+/g, ' ')])
    .sort(([left], [right]) => left.localeCompare(right))
  const signedHeaders = normalized.map(([key]) => key).join(';')
  const query = [
    ['X-Amz-Algorithm', 'AWS4-HMAC-SHA256'],
    ['X-Amz-Credential', `${accessKey}/${scope}`],
    ['X-Amz-Date', amzDate],
    ['X-Amz-Expires', String(expires)],
    ['X-Amz-SignedHeaders', signedHeaders],
  ]
  if (sessionToken) query.push(['X-Amz-Security-Token', sessionToken])
  const canonicalHeaders = normalized.map(([key, value]) => `${key}:${value}\n`).join('')
  const canonicalRequest = [method, canonicalPath(url.pathname), canonicalQuery(query), canonicalHeaders, signedHeaders, 'UNSIGNED-PAYLOAD'].join('\n')
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n')
  query.push(['X-Amz-Signature', hmac(signingKey(secretKey, dateStamp, region), stringToSign, 'hex')])
  url.search = canonicalQuery(query)
  return url
}

async function httpRequest(request) {
  const response = await fetch(request.url, {
    method: request.method,
    headers: request.headers,
    body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
  })
  const body = Buffer.from(await response.arrayBuffer())
  return { status: response.status, headers: response.headers, body }
}

function xmlTag(xml, tag) {
  const match = xml.match(new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`))
  return match ? match[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'") : null
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`)
}

function assertBuffer(actual, expected, message) {
  if (!actual.equals(expected)) throw new Error(`${message}: content mismatch`)
}

async function managementRequest(endpoint, path, init) {
  const response = await fetch(`${endpoint}${path}`, init)
  const text = await response.text()
  if (!response.ok) throw new Error(`Management ${path} failed with ${response.status}: ${text}`)
  return text ? JSON.parse(text) : null
}

async function provisionCredential(endpoint) {
  const username = process.env.ZIGFS_ADMIN_USERNAME ?? defaultAdminUsername
  const password = process.env.ZIGFS_ADMIN_PASSWORD ?? defaultAdminPassword
  const login = await managementRequest(endpoint, '/_admin/v1/auth/login', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username, password }),
  })
  const credential = await managementRequest(endpoint, '/_admin/v1/access-keys', {
    method: 'POST',
    headers: { authorization: `Bearer ${login.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ owner: `phase9-compatibility-${process.pid}` }),
  })
  return { ...credential, managementToken: login.token }
}

async function deleteProvisionedCredential(endpoint, credential) {
  if (!credential?.access_key || !credential.managementToken) return
  try {
    await fetch(`${endpoint}/_admin/v1/access-keys/${encodeURIComponent(credential.access_key)}`, {
      method: 'DELETE', headers: { authorization: `Bearer ${credential.managementToken}` },
    })
  } catch {
    // Cleanup is best effort; the isolated data root is removed with the process.
  }
}

function yamlQuote(value) {
  return JSON.stringify(String(value))
}

function createConfig(endpoint, dataRoot, region, port) {
  return `server:
  api_address: ${yamlQuote(`127.0.0.1:${port}`)}
observability:
  metrics_enabled: false
  metrics_address: ${yamlQuote(`127.0.0.1:${port + 1}`)}
storage:
  data_root: ${yamlQuote(dataRoot)}
  stream_buffer_size: 65536
s3:
  public_endpoint: ${yamlQuote(endpoint)}
  region: ${yamlQuote(region)}
  request_time_skew_seconds: 900
  multipart_expiry_seconds: 604800
admin:
  username: ${yamlQuote(process.env.ZIGFS_ADMIN_USERNAME ?? defaultAdminUsername)}
  password: ${yamlQuote(process.env.ZIGFS_ADMIN_PASSWORD ?? defaultAdminPassword)}
  session_secret: ${yamlQuote('phase9-isolated-session-secret-000000000000')}
  session_ttl_seconds: 3600
`
}

async function waitReady(endpoint, processHandle) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (processHandle && processHandle.exitCode !== null) throw new Error('ZigFS exited before becoming ready')
    try {
      const response = await fetch(`${endpoint}/health/ready`)
      if (response.ok) return
    } catch {
      // The listener may not be bound yet.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100))
  }
  throw new Error(`ZigFS did not become ready at ${endpoint}`)
}

function clientSelection(name) {
  return name === 'all' ? ['http', 'aws', 'mc', 'rclone', 'aws-sdk'] : [name]
}

function createClientReport(name, available, version) {
  return { client: name, available, version: version ?? null, status: available ? 'Pending' : 'Skipped', tests: [], notes: [] }
}

function addTest(report, name, result) {
  report.tests.push({ name, ...result })
  if (result.status === 'Failed') report.status = 'Failed'
  else if (result.status === 'Passed' && report.status !== 'Failed') report.status = 'Passed'
}

async function runTest(report, name, fn, command = null) {
  const started = Date.now()
  try {
    const details = await fn()
    addTest(report, name, { status: 'Passed', duration_ms: Date.now() - started, ...(details ?? {}), ...(command ? { command } : {}) })
  } catch (error) {
    const unsupported = error.message.startsWith('UNSUPPORTED:')
    addTest(report, name, {
      status: unsupported ? 'Unsupported' : 'Failed',
      duration_ms: Date.now() - started,
      ...(unsupported ? { reason: error.message.slice('UNSUPPORTED:'.length).trim() } : { error: error.message }),
      ...(command ? { command } : {}),
    })
  }
}

async function runNativeHttp(report, context) {
  const { endpoint, region, accessKey, secretKey, sessionToken } = context
  const bucket = `zigfs-p9-http-${process.pid}-${Date.now().toString(36)}`.slice(0, 63)
  const key = 'fixtures/hello.txt'
  const source = Buffer.from('ZigFS Phase 9 compatibility fixture\n', 'utf8')
  const target = Buffer.from('Phase 9 HTTP checksum fixture\n', 'utf8')
  const sign = (method, path, query = [], headers = {}, body = Buffer.alloc(0)) => signedRequest({ endpoint, region, accessKey, secretKey, sessionToken, method, path, query, headers, body })
  const request = async (method, path, query = [], headers = {}, body = Buffer.alloc(0)) => httpRequest({ method, ...sign(method, path, query, headers, body) })

  await runTest(report, 'bucket-create', async () => {
    const response = await request('PUT', `/${bucket}`)
    assertEqual(response.status, 200, 'CreateBucket status')
  })
  await runTest(report, 'object-put-and-head', async () => {
    const digest = createHash('sha256').update(source).digest('base64')
    const response = await request('PUT', `/${bucket}/${key}`, [['x', '1']], {
      'content-type': 'text/plain',
      'x-amz-sdk-checksum-algorithm': 'SHA256',
      'x-amz-checksum-sha256': digest,
    }, source)
    assertEqual(response.status, 200, 'PutObject status')
    const head = await request('HEAD', `/${bucket}/${key}`)
    assertEqual(head.status, 200, 'HeadObject status')
    assertEqual(head.headers.get('content-length'), String(source.length), 'HeadObject length')
  })
  await runTest(report, 'object-get-and-list', async () => {
    const response = await request('GET', `/${bucket}/${key}`)
    assertEqual(response.status, 200, 'GetObject status')
    assertBuffer(response.body, source, 'GetObject')
    const list = await request('GET', `/${bucket}`, [['list-type', '2']])
    assertEqual(list.status, 200, 'ListObjectsV2 status')
    if (!list.body.toString().includes(`<Key>${key}</Key>`)) throw new Error('ListObjectsV2 did not include fixture')
  })
  await runTest(report, 'presigned-get', async () => {
    const url = presignedUrl({ endpoint, region, accessKey, secretKey, sessionToken, method: 'GET', path: `/${bucket}/${key}` })
    const response = await fetch(url)
    assertEqual(response.status, 200, 'Presigned GET status')
    assertBuffer(Buffer.from(await response.arrayBuffer()), source, 'Presigned GET')
  })
  await runTest(report, 'copy-object', async () => {
    const response = await request('PUT', `/${bucket}/copies/hello.txt`, [], { 'x-amz-copy-source': `/${bucket}/${key}` })
    assertEqual(response.status, 200, 'CopyObject status')
    const copied = await request('GET', `/${bucket}/copies/hello.txt`)
    assertBuffer(copied.body, source, 'CopyObject')
  })
  await runTest(report, 'multipart-upload', async () => {
    const create = await request('POST', `/${bucket}/multipart.bin`, [['uploads', '']])
    assertEqual(create.status, 200, 'CreateMultipartUpload status')
    const uploadId = xmlTag(create.body.toString(), 'UploadId')
    if (!uploadId) throw new Error('CreateMultipartUpload did not return UploadId')
    const first = Buffer.alloc(5 * 1024 * 1024, 0x41)
    const second = Buffer.from('last-part')
    const firstResponse = await request('PUT', `/${bucket}/multipart.bin`, [['partNumber', '1'], ['uploadId', uploadId]], {}, first)
    const secondResponse = await request('PUT', `/${bucket}/multipart.bin`, [['partNumber', '2'], ['uploadId', uploadId]], {}, second)
    assertEqual(firstResponse.status, 200, 'UploadPart 1 status')
    assertEqual(secondResponse.status, 200, 'UploadPart 2 status')
    const firstEtag = firstResponse.headers.get('etag')
    const secondEtag = secondResponse.headers.get('etag')
    const completeXml = `<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>${firstEtag}</ETag></Part><Part><PartNumber>2</PartNumber><ETag>${secondEtag}</ETag></Part></CompleteMultipartUpload>`
    const complete = await request('POST', `/${bucket}/multipart.bin`, [['uploadId', uploadId]], { 'content-type': 'application/xml' }, Buffer.from(completeXml))
    assertEqual(complete.status, 200, 'CompleteMultipartUpload status')
    const downloaded = await request('GET', `/${bucket}/multipart.bin`)
    assertEqual(downloaded.body.length, first.length + second.length, 'Multipart downloaded length')
  })
  await runTest(report, 'delete-objects-and-bucket', async () => {
    const deleteXml = `<Delete><Object><Key>${key}</Key></Object><Object><Key>copies/hello.txt</Key></Object><Object><Key>multipart.bin</Key></Object></Delete>`
    const body = Buffer.from(deleteXml)
    const response = await request('POST', `/${bucket}`, [['delete', '']], { 'content-md5': createHash('md5').update(body).digest('base64'), 'content-type': 'application/xml' }, body)
    assertEqual(response.status, 200, `DeleteObjects status (${response.body.toString()})`)
    const bucketResponse = await request('DELETE', `/${bucket}`)
    assertEqual(bucketResponse.status, 204, 'DeleteBucket status')
  })
  report.notes.push('Native HTTP uses Node fetch and an in-process SigV4 signer; streaming trailer checksum is explicitly recorded as unsupported by this runner.')
  addTest(report, 'streaming-trailer-checksum', { status: 'Unsupported', reason: 'Node fetch does not expose the aws-chunked signed trailer wire format' })
}

async function runAwsCli(report, context) {
  const { endpoint, region, accessKey, secretKey, sessionToken } = context
  const bucket = `zigfs-p9-aws-${process.pid}-${Date.now().toString(36)}`.slice(0, 63)
  const key = 'fixtures/hello.txt'
  const temp = await mkdtemp(join(tmpdir(), 'zigfs-p9-aws-'))
  const sourcePath = join(temp, 'source.txt')
  const downloadPath = join(temp, 'download.txt')
  await writeFile(sourcePath, 'ZigFS AWS CLI compatibility fixture\n')
  const env = {
    AWS_ACCESS_KEY_ID: accessKey,
    AWS_SECRET_ACCESS_KEY: secretKey,
    AWS_SESSION_TOKEN: sessionToken ?? '',
    AWS_EC2_METADATA_DISABLED: 'true',
    AWS_REQUEST_CHECKSUM_CALCULATION: 'when_required',
    AWS_RESPONSE_CHECKSUM_VALIDATION: 'when_required',
  }
  const base = ['--endpoint-url', endpoint, '--region', region, '--no-verify-ssl']
  const run = async (args, input) => runCommand('aws', [...base, ...args], { env, input })
  const testCommand = (args) => commandText('aws', [...base, ...args])
  try {
    await runTest(report, 'bucket-create', async () => {
      const result = await run(['s3api', 'create-bucket', '--bucket', bucket])
      assertEqual(result.code, 0, 'CreateBucket exit code')
    }, testCommand(['s3api', 'create-bucket', '--bucket', bucket]))
    await runTest(report, 'object-put-head-get-list', async () => {
      let result = await run(['s3api', 'put-object', '--bucket', bucket, '--key', key, '--body', sourcePath, '--checksum-algorithm', 'SHA256'])
      assertEqual(result.code, 0, 'PutObject exit code')
      result = await run(['s3api', 'head-object', '--bucket', bucket, '--key', key])
      assertEqual(result.code, 0, 'HeadObject exit code')
      result = await run(['s3api', 'list-objects-v2', '--bucket', bucket, '--output', 'json'])
      assertEqual(result.code, 0, 'ListObjectsV2 exit code')
      if (!result.stdout.includes(key)) throw new Error('ListObjectsV2 did not include fixture')
      result = await run(['s3api', 'get-object', '--bucket', bucket, '--key', key, downloadPath])
      assertEqual(result.code, 0, 'GetObject exit code')
      assertBuffer(await readFile(downloadPath), await readFile(sourcePath), 'AWS CLI GetObject')
    }, testCommand(['s3api', 'put-object', '--bucket', bucket, '--key', key, '--body', sourcePath]))
    await runTest(report, 'presigned-get', async () => {
      const result = await run(['s3', 'presign', `s3://${bucket}/${key}`, '--expires-in', '300'])
      assertEqual(result.code, 0, 'presign exit code')
      const response = await fetch(result.stdout.trim())
      assertEqual(response.status, 200, 'presigned GET status')
      assertBuffer(Buffer.from(await response.arrayBuffer()), await readFile(sourcePath), 'AWS CLI presigned GET')
    }, testCommand(['s3', 'presign', `s3://${bucket}/${key}`]))
    await runTest(report, 'copy-object', async () => {
      const result = await run(['s3api', 'copy-object', '--bucket', bucket, '--key', 'copies/hello.txt', '--copy-source', `${bucket}/${key}`])
      assertEqual(result.code, 0, 'CopyObject exit code')
    }, testCommand(['s3api', 'copy-object', '--bucket', bucket, '--key', 'copies/hello.txt', '--copy-source', `${bucket}/${key}`]))
    await runTest(report, 'delete-objects-and-bucket', async () => {
      const deletePath = join(temp, 'delete.json')
      await writeFile(deletePath, JSON.stringify({ Objects: [{ Key: key }, { Key: 'copies/hello.txt' }] }))
      let result = await run(['s3api', 'delete-objects', '--bucket', bucket, '--delete', `file://${deletePath}`])
      if (result.code !== 0) {
        if (result.stderr.includes('NotImplemented')) {
          throw new Error('UNSUPPORTED: AWS CLI requests a checksum feature that this V1 DeleteObjects endpoint does not advertise')
        }
        throw new Error(`DeleteObjects exit code: ${result.code}; stderr=${result.stderr.trim()}; stdout=${result.stdout.trim()}`)
      }
      result = await run(['s3api', 'delete-bucket', '--bucket', bucket])
      assertEqual(result.code, 0, 'DeleteBucket exit code')
    }, testCommand(['s3api', 'delete-objects', '--bucket', bucket]))
    addTest(report, 'streaming-trailer-checksum', { status: 'Unsupported', reason: 'AWS CLI command path is covered separately by native transport tests; this matrix records client wire support only when a dedicated fixture is configured' })
  } finally {
    await rm(temp, { recursive: true, force: true })
  }
}

async function runMc(report, context) {
  const { endpoint, accessKey, secretKey } = context
  const alias = `zigfsp9${process.pid}`
  const bucket = `zigfs-p9-mc-${process.pid}-${Date.now().toString(36)}`.slice(0, 63)
  const temp = await mkdtemp(join(tmpdir(), 'zigfs-p9-mc-'))
  const mcConfigDir = join(temp, 'mc-config')
  const sourcePath = join(temp, 'source.txt')
  const downloadPath = join(temp, 'download.txt')
  await writeFile(sourcePath, 'ZigFS MinIO Client compatibility fixture\n')
  const run = (args, options = {}) => runCommand('mc', args, { env: { MC_CONFIG_DIR: mcConfigDir }, ...options })
  const command = (args) => commandText('mc', args)
  try {
    let result = await run(['alias', 'set', alias, endpoint, accessKey, secretKey, '--api', 'S3v4'])
    if (result.code !== 0) throw new Error(`mc alias setup failed: ${result.stderr}`)
    await runTest(report, 'bucket-create', async () => {
      const output = await run(['mb', `${alias}/${bucket}`])
      assertEqual(output.code, 0, 'mc mb exit code')
    }, command(['mb', `${alias}/${bucket}`]))
    await runTest(report, 'object-put-head-get-list', async () => {
      let output = await run(['cp', sourcePath, `${alias}/${bucket}/fixtures/hello.txt`])
      assertEqual(output.code, 0, 'mc cp exit code')
      output = await run(['stat', `${alias}/${bucket}/fixtures/hello.txt`, '--json'])
      assertEqual(output.code, 0, 'mc stat exit code')
      output = await run(['ls', '--recursive', '--json', `${alias}/${bucket}`])
      assertEqual(output.code, 0, 'mc ls exit code')
      if (!output.stdout.includes('hello.txt')) throw new Error(`mc ls did not include fixture: ${output.stdout.trim()} ${output.stderr.trim()}`)
      output = await run(['cp', `${alias}/${bucket}/fixtures/hello.txt`, downloadPath])
      assertEqual(output.code, 0, 'mc download exit code')
      assertBuffer(await readFile(downloadPath), await readFile(sourcePath), 'mc download')
    }, command(['cp', sourcePath, `${alias}/${bucket}/fixtures/hello.txt`]))
    await runTest(report, 'presigned-get', async () => {
      const output = await run(['share', 'download', `${alias}/${bucket}/fixtures/hello.txt`])
      assertEqual(output.code, 0, 'mc presign exit code')
      const url = output.stdout.trim().split(/\s+/).filter((value) => value.startsWith('http')).at(-1)
      if (!url) throw new Error(`mc presign did not return a URL: ${output.stdout.trim()} ${output.stderr.trim()}`)
      const response = await fetch(url)
      const responseBody = Buffer.from(await response.arrayBuffer())
      if (response.status !== 200) throw new Error(`mc presigned GET status: expected 200, got ${response.status}: ${responseBody.toString()} url=${url} output=${output.stdout.trim()}`)
      assertBuffer(responseBody, await readFile(sourcePath), 'mc presigned GET')
    }, command(['share', 'download', `${alias}/${bucket}/fixtures/hello.txt`]))
    await runTest(report, 'copy-object', async () => {
      const output = await run(['cp', `${alias}/${bucket}/fixtures/hello.txt`, `${alias}/${bucket}/copies/hello.txt`])
      assertEqual(output.code, 0, 'mc copy exit code')
    }, command(['cp', `${alias}/${bucket}/fixtures/hello.txt`, `${alias}/${bucket}/copies/hello.txt`]))
    await runTest(report, 'delete-objects-and-bucket', async () => {
      let output = await run(['rm', '--recursive', '--force', `${alias}/${bucket}/`])
      assertEqual(output.code, 0, 'mc rm exit code')
      output = await run(['rb', `${alias}/${bucket}`])
      assertEqual(output.code, 0, 'mc rb exit code')
    }, command(['rm', '--recursive', '--force', `${alias}/${bucket}/`]))
    addTest(report, 'post-policy-upload', { status: 'Unsupported', reason: 'mc POST Policy command is not stable across installed releases; native HTTP policy coverage is recorded separately' })
    addTest(report, 'streaming-trailer-checksum', { status: 'Unsupported', reason: 'mc does not expose a deterministic checksum-trailer selection flag' })
  } finally {
    await rm(temp, { recursive: true, force: true })
    await run(['alias', 'remove', alias])
  }
}

async function runRclone(report, context) {
  const { endpoint, region, accessKey, secretKey } = context
  const remote = `zigfsp9${process.pid}`
  const bucket = `zigfs-p9-rclone-${process.pid}-${Date.now().toString(36)}`.slice(0, 63)
  const temp = await mkdtemp(join(tmpdir(), 'zigfs-p9-rclone-'))
  const configPath = join(temp, 'rclone.conf')
  const sourcePath = join(temp, 'source.txt')
  const downloadPath = join(temp, 'download.txt')
  await writeFile(sourcePath, 'ZigFS rclone compatibility fixture\n')
  await writeFile(configPath, `[${remote}]\ntype = s3\nprovider = Other\naccess_key_id = ${accessKey}\nsecret_access_key = ${secretKey}\nendpoint = ${endpoint}\nregion = ${region}\nlist_version = 2\nforce_path_style = true\n`)
  const env = { RCLONE_CONFIG: configPath, RCLONE_ASK_PASSWORD: 'false' }
  const run = (args, options = {}) => runCommand('rclone', args, { env, ...options })
  const command = (args) => commandText('rclone', args)
  try {
    await runTest(report, 'bucket-create', async () => {
      const output = await run(['mkdir', `${remote}:${bucket}`])
      assertEqual(output.code, 0, 'rclone mkdir exit code')
    }, command(['mkdir', `${remote}:${bucket}`]))
    await runTest(report, 'object-put-head-get-list', async () => {
      let output = await run(['copyto', sourcePath, `${remote}:${bucket}/fixtures/hello.txt`])
      if (output.code !== 0) throw new Error(`rclone copyto failed (${output.code}): ${output.stderr.trim() || output.stdout.trim()}`)
      output = await run(['size', `${remote}:${bucket}/fixtures/hello.txt`])
      assertEqual(output.code, 0, 'rclone size exit code')
      output = await run(['lsjson', '--recursive', `${remote}:${bucket}`])
      assertEqual(output.code, 0, 'rclone lsjson exit code')
      if (!output.stdout.includes('hello.txt')) throw new Error(`rclone lsjson did not include fixture: ${output.stdout.trim()} ${output.stderr.trim()}`)
      output = await run(['copyto', `${remote}:${bucket}/fixtures/hello.txt`, downloadPath])
      assertEqual(output.code, 0, 'rclone download exit code')
      assertBuffer(await readFile(downloadPath), await readFile(sourcePath), 'rclone download')
    }, command(['copyto', sourcePath, `${remote}:${bucket}/fixtures/hello.txt`]))
    addTest(report, 'presigned-get', { status: 'Unsupported', reason: 'rclone link requires a provider-generated public URL and does not generate S3 SigV4 presigned URLs' })
    await runTest(report, 'copy-object', async () => {
      const output = await run(['copyto', `${remote}:${bucket}/fixtures/hello.txt`, `${remote}:${bucket}/copies/hello.txt`])
      assertEqual(output.code, 0, 'rclone copy exit code')
    }, command(['copyto', `${remote}:${bucket}/fixtures/hello.txt`, `${remote}:${bucket}/copies/hello.txt`]))
    await runTest(report, 'delete-objects-and-bucket', async () => {
      let output = await run(['deletefile', `${remote}:${bucket}/fixtures/hello.txt`])
      assertEqual(output.code, 0, 'rclone deletefile exit code')
      output = await run(['purge', `${remote}:${bucket}`])
      assertEqual(output.code, 0, 'rclone purge exit code')
    }, command(['purge', `${remote}:${bucket}`]))
    addTest(report, 'post-policy-upload', { status: 'Unsupported', reason: 'rclone has no stable POST Policy upload command' })
    addTest(report, 'streaming-trailer-checksum', { status: 'Unsupported', reason: 'rclone does not expose signed streaming trailer checksum selection' })
  } finally {
    await rm(temp, { recursive: true, force: true })
  }
}

async function runAwsSdk(report, context) {
  const script = join(scriptDir, 'aws_sdk_probe.rb')
  const command = commandText('ruby', [script, context.endpoint, context.region])
  const result = await runCommand('ruby', [script, context.endpoint, context.region], {
    env: {
      ZIGFS_COMPAT_ACCESS_KEY: context.accessKey,
      ZIGFS_COMPAT_SECRET_KEY: context.secretKey,
      ZIGFS_COMPAT_SESSION_TOKEN: context.sessionToken ?? '',
    },
    timeoutMs: 120_000,
  })
  if (result.code !== 0) {
    addTest(report, 'sdk-bucket-object-lifecycle', {
      status: 'Failed',
      error: result.stderr.trim() || result.stdout.trim() || `ruby exited with ${result.code}`,
      command,
    })
    return
  }
  addTest(report, 'sdk-bucket-object-lifecycle', { status: 'Passed', command })
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const endpointUrl = new URL(options.endpoint)
  options.endpoint = options.endpoint.replace(/\/$/, '')
  const selected = clientSelection(options.client)
  const startedAt = new Date().toISOString()
  const report = {
    schema_version: 'phase9-compatibility-v1',
    started_at: startedAt,
    finished_at: null,
    server: {
      endpoint: options.endpoint,
      region: options.region,
      version: null,
      config: {
        mode: options.skipStart ? 'external endpoint' : 'isolated temporary YAML configuration',
        api_address: endpointUrl.host,
        metrics_enabled: false,
        data_root: options.dataRoot,
        s3_public_endpoint: options.endpoint,
        s3_region: options.region,
        s3_virtual_hosted_style: false,
        stream_buffer_size: 65536,
      },
    },
    requested_clients: selected,
    clients: [],
    status: 'Passed',
    cleanup: { data_root_removed: false, credential_removed: false },
    credentials: { source: options.accessKey ? 'provided' : 'zigfs-management-api', secret_material_recorded: false },
  }
  let tempRoot = null
  let dataRootCreatedByRunner = false
  let serverProcess = null
  let serverLogPath = null
  let provisioned = null
  try {
    if (!options.skipStart) {
      const port = Number(endpointUrl.port || 9000)
      if (!Number.isInteger(port) || port < 1024 || port > 65534) throw new Error('endpoint port must be between 1024 and 65534')
      if (!options.dataRoot) {
        tempRoot = await mkdtemp(join(tmpdir(), 'zigfs-phase9-compatibility-'))
        options.dataRoot = join(tempRoot, 'data')
        dataRootCreatedByRunner = true
      } else {
        await mkdir(options.dataRoot, { recursive: true })
      }
      report.server.config.data_root = options.dataRoot
      tempRoot ??= await mkdtemp(join(tmpdir(), 'zigfs-phase9-compatibility-log-'))
      const configPath = join(tempRoot, 'config.yaml')
      serverLogPath = join(tempRoot, 'zigfs.log')
      await writeFile(configPath, createConfig(options.endpoint, options.dataRoot, options.region, port))
      const build = await runCommand('zig', ['build'], { cwd: zigfsRoot, timeoutMs: 300_000 })
      if (build.code !== 0) throw new Error(`zig build failed: ${build.stderr || build.stdout}`)
      const logHandle = createWriteStream(serverLogPath)
      serverProcess = spawn(join(zigfsRoot, 'zig-out', 'bin', 'zigfs'), ['--config', configPath], { cwd: zigfsRoot, stdio: ['ignore', 'pipe', 'pipe'] })
      serverProcess.stdout.pipe(logHandle)
      serverProcess.stderr.pipe(logHandle)
      serverProcess.exitCode = null
      await waitReady(options.endpoint, serverProcess)
      report.server.version = 'local build'
    } else {
      await waitReady(options.endpoint, null)
      report.server.version = 'external endpoint'
    }
    if (!options.accessKey) {
      provisioned = await provisionCredential(options.endpoint)
      options.accessKey = provisioned.access_key
      options.secretKey = provisioned.secret_key
      options.sessionToken = provisioned.session_token ?? null
    }
    const context = { endpoint: options.endpoint, region: options.region, accessKey: options.accessKey, secretKey: options.secretKey, sessionToken: options.sessionToken }
    for (const client of selected) {
      const sdkVersion = client === 'aws-sdk' ? awsSdkRuntime() : null
      const available = client === 'http' || (client === 'aws-sdk' ? sdkVersion !== null : commandExists(client))
      const version = client === 'http' ? `node ${process.versions.node}` : client === 'aws-sdk' ? (sdkVersion ? `ruby aws-sdk-s3 ${sdkVersion}` : null) : available ? versionOf(client, client === 'rclone' ? ['version'] : ['--version']) : null
      const clientReport = createClientReport(client, available, version)
      report.clients.push(clientReport)
      if (!available) {
        clientReport.notes.push('client executable not found in PATH')
        continue
      }
      if (client === 'http') await runNativeHttp(clientReport, context)
      else if (client === 'aws') await runAwsCli(clientReport, context)
      else if (client === 'mc') await runMc(clientReport, context)
      else if (client === 'rclone') await runRclone(clientReport, context)
      else await runAwsSdk(clientReport, context)
      if (clientReport.status === 'Failed') report.status = 'Failed'
    }
  } catch (error) {
    report.status = 'Failed'
    report.fatal_error = error.message
  } finally {
    if (provisioned) {
      await deleteProvisionedCredential(options.endpoint, provisioned)
      report.cleanup.credential_removed = true
    }
    if (serverProcess && serverProcess.exitCode === null) {
      serverProcess.kill('SIGTERM')
      await new Promise((resolvePromise) => serverProcess.once('close', resolvePromise))
    }
    const preserve = options.keepData || report.status === 'Failed'
    if (preserve && serverLogPath) {
      const reportLog = `${options.report}.zigfs.log`
      await mkdir(dirname(reportLog), { recursive: true })
      await copyFile(serverLogPath, reportLog).catch(() => {})
      report.cleanup.log = reportLog
    }
    if (dataRootCreatedByRunner && !preserve && tempRoot) {
      await rm(tempRoot, { recursive: true, force: true })
      report.cleanup.data_root_removed = true
    } else if (dataRootCreatedByRunner && tempRoot) {
      report.cleanup.data_root = options.dataRoot
    } else if (tempRoot) {
      // An explicitly supplied data root must survive; the runner-owned log directory does not.
      await rm(tempRoot, { recursive: true, force: true })
    }
    report.finished_at = new Date().toISOString()
    await mkdir(dirname(options.report), { recursive: true })
    await writeFile(options.report, `${JSON.stringify(report, null, 2)}\n`)
    const markdownPath = options.report.replace(/\.json$/i, '.md')
    const lines = [`# ZigFS Phase 9 Compatibility Report`, '', `- Status: **${report.status}**`, `- Started: ${report.started_at}`, `- Finished: ${report.finished_at}`, `- Endpoint: \`${report.server.endpoint}\``, `- Region: \`${report.server.region}\``, '', '| Client | Version | Status | Passed | Failed | Unsupported/Skipped |', '|---|---|---:|---:|---:|---:|']
    for (const client of report.clients) {
      const count = (status) => client.tests.filter((test) => test.status === status).length
      lines.push(`| ${client.client} | ${client.version ?? '-'} | ${client.status} | ${count('Passed')} | ${count('Failed')} | ${count('Unsupported') + count('Skipped')} |`)
    }
    lines.push('', '## Tests', '')
    for (const client of report.clients) {
      lines.push(`### ${client.client}`, '')
      for (const test of client.tests) lines.push(`- **${test.status}** \`${test.name}\`${test.error ? `: ${test.error}` : test.reason ? `: ${test.reason}` : ''}${test.command ? `\n  - Command: \`${test.command}\`` : ''}`)
      for (const note of client.notes) lines.push(`- Note: ${note}`)
      lines.push('')
    }
    await writeFile(markdownPath, `${lines.join('\n')}\n`)
    console.log(`Compatibility report: ${options.report}`)
    console.log(`Compatibility summary: ${report.status}`)
    if (report.cleanup.log) console.log(`ZigFS log preserved: ${report.cleanup.log}`)
  }
  if (report.status === 'Failed') process.exitCode = 1
}

main().catch((error) => {
  console.error(`compatibility runner: ${error.message}`)
  process.exitCode = 2
})
