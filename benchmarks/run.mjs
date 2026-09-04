import { execFile } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { promisify } from 'node:util'

import {
  emptyPayloadHash,
  sha256Hex,
  signRequest,
} from '../conformance/typescript/sigv4.ts'

const execFileAsync = promisify(execFile)
const KiB = 1024
const MiB = 1024 * KiB
const GiB = 1024 * MiB
const unsignedPayload = 'UNSIGNED-PAYLOAD'
const chunkSize = 64 * KiB

function fail(message) {
  throw new Error(message)
}

function parseArguments(values) {
  const options = {
    profile: 'smoke',
    endpoint: 'http://127.0.0.1:19080',
    region: 'us-east-1',
    adminUsername: 'phase8-admin',
    adminPassword: 'phase8-admin-password',
    output: '',
    pid: 0,
  }
  for (let index = 0; index < values.length; index += 1) {
    const name = values[index]
    const value = values[index + 1]
    if (!name.startsWith('--') || value === undefined) fail(`missing value for ${name}`)
    index += 1
    switch (name) {
      case '--profile': options.profile = value; break
      case '--endpoint': options.endpoint = value.replace(/\/$/, ''); break
      case '--region': options.region = value; break
      case '--admin-username': options.adminUsername = value; break
      case '--admin-password': options.adminPassword = value; break
      case '--output': options.output = value; break
      case '--pid': options.pid = Number.parseInt(value, 10); break
      default: fail(`unknown argument: ${name}`)
    }
  }
  if (!['smoke', 'full'].includes(options.profile)) fail('profile must be smoke or full')
  if (!Number.isSafeInteger(options.pid) || options.pid < 0) fail('pid must be a positive integer')
  if (!options.output) fail('--output is required')
  return options
}

async function managementRequest(endpoint, route, init) {
  const response = await fetch(`${endpoint}${route}`, init)
  if (!response.ok) {
    fail(`Management ${route} returned ${response.status}: ${await response.text()}`)
  }
  return response
}

async function provision(options) {
  const login = await managementRequest(options.endpoint, '/_admin/v1/auth/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      username: options.adminUsername,
      password: options.adminPassword,
    }),
  }).then((response) => response.json())
  const credential = await managementRequest(options.endpoint, '/_admin/v1/access-keys', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${login.token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ owner: 'phase8-benchmark' }),
  }).then((response) => response.json())
  return {
    token: login.token,
    config: {
      endpoint: options.endpoint,
      access_key: credential.access_key,
      secret_key: credential.secret_key,
      region: options.region,
      owner: credential.owner,
    },
  }
}

async function revoke(options, provisioned) {
  const accessKey = encodeURIComponent(provisioned.config.access_key)
  await managementRequest(options.endpoint, `/_admin/v1/access-keys/${accessKey}`, {
    method: 'DELETE',
    headers: { authorization: `Bearer ${provisioned.token}` },
  })
}

function repeatingStream(size, byte) {
  const completeChunk = new Uint8Array(chunkSize).fill(byte)
  let remaining = size
  return new ReadableStream({
    pull(controller) {
      if (remaining === 0) {
        controller.close()
        return
      }
      const length = Math.min(remaining, completeChunk.byteLength)
      controller.enqueue(length === completeChunk.byteLength ? completeChunk : completeChunk.subarray(0, length))
      remaining -= length
    },
  })
}

function xmlElement(xml, name) {
  return xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1]
}

function escapeXml(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

class S3BenchmarkClient {
  constructor(config) {
    this.config = config
  }

  async request(method, requestPath, query = [], options = {}) {
    const headers = { ...(options.headers ?? {}) }
    const payloadHash = options.payloadHash ?? emptyPayloadHash
    const signed = await signRequest(this.config, method, requestPath, query, payloadHash, headers)
    if (options.length !== undefined) signed.headers.set('content-length', String(options.length))
    const init = { method, headers: signed.headers }
    if (options.body !== undefined) {
      init.body = options.body
      init.duplex = 'half'
    }
    return fetch(signed.url, init)
  }

  async expect(response, statuses, operation) {
    if (!statuses.includes(response.status)) {
      fail(`${operation} returned ${response.status}: ${await response.text()}`)
    }
    return response
  }

  async drain(response) {
    if (!response.body) return 0
    const reader = response.body.getReader()
    let bytes = 0
    while (true) {
      const item = await reader.read()
      if (item.done) return bytes
      bytes += item.value.byteLength
    }
  }

  async createBucket(bucket) {
    const response = await this.request('PUT', `/${bucket}`)
    await this.expect(response, [200], 'CreateBucket')
    await this.drain(response)
  }

  async deleteBucket(bucket) {
    const response = await this.request('DELETE', `/${bucket}`)
    await this.expect(response, [204], 'DeleteBucket')
    await this.drain(response)
  }

  async put(bucket, key, size, byte) {
    const response = await this.request('PUT', `/${bucket}/${key}`, [], {
      body: repeatingStream(size, byte),
      headers: { 'content-type': 'application/octet-stream' },
      length: size,
      payloadHash: unsignedPayload,
    })
    await this.expect(response, [200], 'PutObject')
    await this.drain(response)
    return size
  }

  async get(bucket, key, expectedSize) {
    const response = await this.request('GET', `/${bucket}/${key}`)
    await this.expect(response, [200], 'GetObject')
    const bytes = await this.drain(response)
    if (bytes !== expectedSize) fail(`GetObject returned ${bytes} bytes, expected ${expectedSize}`)
    return bytes
  }

  async range(bucket, key, objectSize) {
    const rangeSize = Math.min(objectSize, MiB)
    const response = await this.request('GET', `/${bucket}/${key}`, [], {
      headers: { range: `bytes=0-${rangeSize - 1}` },
    })
    await this.expect(response, [206], 'Range GetObject')
    const bytes = await this.drain(response)
    if (bytes !== rangeSize) fail(`Range returned ${bytes} bytes, expected ${rangeSize}`)
    return bytes
  }

  async list(bucket, prefix) {
    const response = await this.request('GET', `/${bucket}`, [
      ['list-type', '2'],
      ['max-keys', '1000'],
      ['prefix', prefix],
    ])
    await this.expect(response, [200], 'ListObjectsV2')
    return this.drain(response)
  }

  async delete(bucket, key) {
    const response = await this.request('DELETE', `/${bucket}/${key}`)
    await this.expect(response, [204], 'DeleteObject')
    await this.drain(response)
    return 0
  }

  async createMultipart(bucket, key) {
    const response = await this.request('POST', `/${bucket}/${key}`, [['uploads', '']])
    await this.expect(response, [200], 'CreateMultipartUpload')
    const uploadId = xmlElement(await response.text(), 'UploadId')
    if (!uploadId) fail('CreateMultipartUpload did not return UploadId')
    return uploadId
  }

  async uploadPart(bucket, key, uploadId, number, size) {
    const response = await this.request('PUT', `/${bucket}/${key}`, [
      ['partNumber', String(number)],
      ['uploadId', uploadId],
    ], {
      body: repeatingStream(size, number % 251),
      length: size,
      payloadHash: unsignedPayload,
    })
    await this.expect(response, [200], `UploadPart ${number}`)
    await this.drain(response)
    const etag = response.headers.get('etag')
    if (!etag) fail(`UploadPart ${number} did not return ETag`)
    return { number, etag, size }
  }

  async completeMultipart(bucket, key, uploadId, parts) {
    const body = `<CompleteMultipartUpload>${parts.map((part) =>
      `<Part><ETag>${escapeXml(part.etag)}</ETag><PartNumber>${part.number}</PartNumber></Part>`,
    ).join('')}</CompleteMultipartUpload>`
    const response = await this.request('POST', `/${bucket}/${key}`, [['uploadId', uploadId]], {
      body,
      headers: { 'content-type': 'application/xml' },
      length: Buffer.byteLength(body),
      payloadHash: await sha256Hex(body),
    })
    await this.expect(response, [200], 'CompleteMultipartUpload')
    return this.drain(response)
  }
}

function percentile(sorted, fraction) {
  const index = Math.max(0, Math.ceil(sorted.length * fraction) - 1)
  return sorted[index]
}

function rounded(value) {
  return Math.round(value * 1000) / 1000
}

async function measure(operation, objectSize, requests, concurrency, action) {
  const latencies = []
  let transferred = 0
  let next = 0
  const started = process.hrtime.bigint()
  async function worker() {
    while (true) {
      const index = next
      next += 1
      if (index >= requests) return
      const requestStarted = process.hrtime.bigint()
      const bytes = await action(index)
      const requestEnded = process.hrtime.bigint()
      latencies.push(Number(requestEnded - requestStarted) / 1e6)
      transferred += bytes
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, requests) }, worker))
  const durationSeconds = Number(process.hrtime.bigint() - started) / 1e9
  latencies.sort((left, right) => left - right)
  return {
    operation,
    object_size_bytes: objectSize,
    requests,
    concurrency,
    duration_seconds: rounded(durationSeconds),
    requests_per_second: rounded(requests / durationSeconds),
    bytes_transferred: transferred,
    throughput_bytes_per_second: rounded(transferred / durationSeconds),
    latency_ms: {
      p50: rounded(percentile(latencies, 0.50)),
      p95: rounded(percentile(latencies, 0.95)),
      p99: rounded(percentile(latencies, 0.99)),
    },
  }
}

async function linuxDiskIo(pid) {
  if (process.platform !== 'linux' || pid === 0) return null
  try {
    const source = await readFile(`/proc/${pid}/io`, 'utf8')
    const values = Object.fromEntries(source.trim().split('\n').map((line) => {
      const [name, value] = line.split(':')
      return [name.trim(), Number.parseInt(value.trim(), 10)]
    }))
    return { read_bytes: values.read_bytes, write_bytes: values.write_bytes }
  } catch {
    return null
  }
}

class ResourceMonitor {
  constructor(pid) {
    this.pid = pid
    this.samples = []
    this.timer = null
    this.samplePending = false
    this.startIo = null
  }

  async sample() {
    if (this.pid === 0 || this.samplePending) return
    this.samplePending = true
    try {
      const { stdout } = await execFileAsync('ps', [
        '-o', 'rss=', '-o', '%cpu=', '-p', String(this.pid),
      ])
      const fields = stdout.trim().split(/\s+/)
      if (fields.length >= 2) {
        this.samples.push({ rss_bytes: Number(fields[0]) * KiB, cpu_percent: Number(fields[1]) })
      }
    } catch {
      // A vanished process is reported by the benchmark request path itself.
    } finally {
      this.samplePending = false
    }
  }

  async start() {
    this.startIo = await linuxDiskIo(this.pid)
    await this.sample()
    this.timer = setInterval(() => { void this.sample() }, 250)
  }

  async stop() {
    if (this.timer) clearInterval(this.timer)
    await this.sample()
    const endIo = await linuxDiskIo(this.pid)
    const rss = this.samples.map((sample) => sample.rss_bytes)
    const cpu = this.samples.map((sample) => sample.cpu_percent)
    return {
      process_id: this.pid || null,
      sample_interval_ms: 250,
      samples: this.samples.length,
      rss_bytes: rss.length ? { max: Math.max(...rss), average: rounded(rss.reduce((a, b) => a + b, 0) / rss.length) } : null,
      cpu_percent: cpu.length ? { max: Math.max(...cpu), average: rounded(cpu.reduce((a, b) => a + b, 0) / cpu.length) } : null,
      disk_io_bytes: this.startIo && endIo ? {
        read: Math.max(0, endIo.read_bytes - this.startIo.read_bytes),
        write: Math.max(0, endIo.write_bytes - this.startIo.write_bytes),
      } : null,
      disk_io_note: this.startIo && endIo
        ? 'Linux /proc process I/O counters; includes filesystem calls during the measured run.'
        : 'Unavailable on this platform; use host block-device telemetry for production baselines.',
    }
  }
}

function profileConfig(profile) {
  return {
    smallSizes: [KiB, 10 * KiB, 100 * KiB, MiB],
    smallConcurrencies: profile === 'full' ? [1, 8] : [1, 4],
    smallRequests: (concurrency) => profile === 'full'
      ? Math.max(32, concurrency * 16)
      : Math.max(4, concurrency * 2),
    largeSizes: profile === 'full' ? [100 * MiB, GiB, 10 * GiB] : [100 * MiB],
    listRequests: profile === 'full' ? 32 : 4,
    multipartSize: profile === 'full' ? 100 * MiB : 10 * MiB,
    multipartPartSize: profile === 'full' ? 10 * MiB : 5 * MiB,
    multipartConcurrency: profile === 'full' ? 4 : 2,
  }
}

async function executeBenchmark(client, bucket, profile, cleanupKeys) {
  const config = profileConfig(profile)
  const results = []
  let scenario = 0
  for (const size of config.smallSizes) {
    for (const concurrency of config.smallConcurrencies) {
      scenario += 1
      const prefix = `small-${size}-${concurrency}-${scenario}-`
      const requests = config.smallRequests(concurrency)
      const keys = Array.from({ length: requests }, (_, index) => `${prefix}${index}`)
      for (const key of keys) cleanupKeys.add(key)
      results.push(await measure('PutObject', size, requests, concurrency,
        (index) => client.put(bucket, keys[index], size, index % 251)))
      results.push(await measure('GetObject', size, requests, concurrency,
        (index) => client.get(bucket, keys[index], size)))
      results.push(await measure('RangeGetObject', Math.min(size, MiB), requests, concurrency,
        (index) => client.range(bucket, keys[index], size)))
      results.push(await measure('ListObjectsV2', 0, config.listRequests, concurrency,
        () => client.list(bucket, prefix)))
      results.push(await measure('DeleteObject', 0, requests, concurrency,
        (index) => client.delete(bucket, keys[index])))
      for (const key of keys) cleanupKeys.delete(key)
    }
  }

  for (const size of config.largeSizes) {
    scenario += 1
    const key = `large-${size}-${scenario}`
    cleanupKeys.add(key)
    results.push(await measure('PutObject', size, 1, 1, () => client.put(bucket, key, size, 0x5a)))
    results.push(await measure('GetObject', size, 1, 1, () => client.get(bucket, key, size)))
    results.push(await measure('RangeGetObject', MiB, 1, 1, () => client.range(bucket, key, size)))
    results.push(await measure('DeleteObject', 0, 1, 1, () => client.delete(bucket, key)))
    cleanupKeys.delete(key)
  }

  const multipartKey = `multipart-${config.multipartSize}`
  cleanupKeys.add(multipartKey)
  let uploadId = ''
  results.push(await measure('CreateMultipartUpload', 0, 1, 1, async () => {
    uploadId = await client.createMultipart(bucket, multipartKey)
    return 0
  }))
  const partCount = Math.ceil(config.multipartSize / config.multipartPartSize)
  const parts = new Array(partCount)
  results.push(await measure(
    'UploadPart',
    config.multipartPartSize,
    partCount,
    config.multipartConcurrency,
    async (index) => {
      const size = Math.min(config.multipartPartSize, config.multipartSize - index * config.multipartPartSize)
      parts[index] = await client.uploadPart(bucket, multipartKey, uploadId, index + 1, size)
      return size
    },
  ))
  results.push(await measure('CompleteMultipartUpload', config.multipartSize, 1, 1, async () => {
    await client.completeMultipart(bucket, multipartKey, uploadId, parts)
    return 0
  }))
  results.push(await measure('GetMultipartObject', config.multipartSize, 1, 1,
    () => client.get(bucket, multipartKey, config.multipartSize)))
  results.push(await measure('DeleteObject', 0, 1, 1,
    () => client.delete(bucket, multipartKey)))
  cleanupKeys.delete(multipartKey)
  return { config, results }
}

function printResult(result) {
  const size = result.object_size_bytes ? `${rounded(result.object_size_bytes / MiB)} MiB` : '-'
  const throughput = result.bytes_transferred
    ? `${rounded(result.throughput_bytes_per_second / MiB)} MiB/s`
    : '-'
  console.log(
    `${result.operation.padEnd(24)} size=${size.padStart(10)} c=${String(result.concurrency).padStart(2)}` +
    ` rps=${String(result.requests_per_second).padStart(9)} throughput=${throughput.padStart(14)}` +
    ` p50/p95/p99=${result.latency_ms.p50}/${result.latency_ms.p95}/${result.latency_ms.p99} ms`,
  )
}

const options = parseArguments(process.argv.slice(2))
const provisioned = await provision(options)
const client = new S3BenchmarkClient(provisioned.config)
const bucket = `phase8-bench-${Date.now().toString(36)}`
const cleanupKeys = new Set()
const monitor = new ResourceMonitor(options.pid)
let monitorStarted = false
let resourceUsage = null
let benchmark = null

try {
  await client.createBucket(bucket)
  await monitor.start()
  monitorStarted = true
  benchmark = await executeBenchmark(client, bucket, options.profile, cleanupKeys)
  resourceUsage = await monitor.stop()
  monitorStarted = false
} finally {
  if (monitorStarted) resourceUsage = await monitor.stop().catch(() => null)
  for (const key of cleanupKeys) await client.delete(bucket, key).catch(() => undefined)
  await client.deleteBucket(bucket).catch(() => undefined)
  await revoke(options, provisioned).catch(() => undefined)
}

const report = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  profile: options.profile,
  command: process.env.ZIGFS_BENCH_COMMAND ?? process.argv.join(' '),
  endpoint: options.endpoint,
  build_mode: process.env.ZIGFS_BENCH_BUILD_MODE ?? 'unknown',
  zig_version: process.env.ZIGFS_BENCH_ZIG_VERSION ?? 'unknown',
  stream_buffer_size_bytes: Number(process.env.ZIGFS_BENCH_STREAM_BUFFER_SIZE ?? 0) || null,
  workload: {
    small_object_sizes_bytes: benchmark.config.smallSizes,
    large_object_sizes_bytes: benchmark.config.largeSizes,
    small_concurrencies: benchmark.config.smallConcurrencies,
    multipart_size_bytes: benchmark.config.multipartSize,
    multipart_part_size_bytes: benchmark.config.multipartPartSize,
    multipart_concurrency: benchmark.config.multipartConcurrency,
  },
  host: {
    platform: process.platform,
    release: os.release(),
    architecture: os.arch(),
    cpu_model: os.cpus()[0]?.model ?? 'unknown',
    logical_cpu_count: os.cpus().length,
    total_memory_bytes: os.totalmem(),
    node_version: process.version,
  },
  resource_usage: resourceUsage,
  results: benchmark.results,
  notes: [
    'All file operations use the authenticated ZigFS S3 API with Signature V4.',
    'UNSIGNED-PAYLOAD avoids including client-side hashing in transfer latency; ZigFS still computes and persists object checksums.',
    'Results are environment-specific and are not a product-wide performance guarantee.',
  ],
}

await mkdir(path.dirname(options.output), { recursive: true })
await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`, { encoding: 'utf8' })
for (const result of report.results) printResult(result)
console.log(`Benchmark report: ${options.output}`)
