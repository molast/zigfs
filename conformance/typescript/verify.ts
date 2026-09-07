import { readFile } from 'node:fs/promises'
import { S3ConformanceClient } from './adapter.ts'
import { signatureForVector } from './sigv4.ts'
import type { Fixture, RetryCase, RuntimeConfig } from './types.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function xmlElement(xml: string, name: string): string | undefined {
  return xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1]
}

function shouldRetry(value: RetryCase): boolean {
  if (value.cancelled || value.response_started || value.status < 500) return false
  if (value.operation === 'create_multipart' || value.operation === 'complete_multipart') return false
  if ((value.method === 'PUT' || value.method === 'POST') && !value.body_replayable) return false
  return ['GET', 'HEAD', 'DELETE', 'PUT'].includes(value.method)
}

async function loadJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, 'utf8')) as T
}

async function verifySharedVectors(fixture: Fixture): Promise<void> {
  assert(fixture.schema_version === 1, 'unsupported fixture schema')
  assert(await signatureForVector(fixture.sigv4) === fixture.sigv4.expected_signature, 'SigV4 vector mismatch')

  const values = fixture.uint64_values.map((value) => BigInt(value))
  assert(values[1] > BigInt(Number.MAX_SAFE_INTEGER), 'uint64 vector did not cross JS safe integer limit')
  assert(values[2] === (1n << 64n) - 1n, 'uint64 maximum lost precision')
  assert(values.map(String).join(',') === fixture.uint64_values.join(','), 'uint64 round trip failed')

  for (const value of fixture.opaque_values) assert(`${value}` === value, 'opaque value changed')
  for (const value of fixture.errors) {
    assert(xmlElement(value.xml, 'Code') === value.code, `error code mismatch for ${value.code}`)
    assert(xmlElement(value.xml, 'RequestId') === value.request_id, `request ID mismatch for ${value.code}`)
    const retryableStatus = value.status >= 500 && value.code !== 'NotImplemented'
    assert(retryableStatus === value.retryable, `retryable mismatch for ${value.code}`)
  }
  for (const value of fixture.retry_cases) {
    assert(shouldRetry(value) === value.expected, `retry decision mismatch for ${value.operation}`)
  }
  const expectedChecksums = ['CRC32', 'CRC32C', 'CRC64NVME', 'SHA1', 'SHA256']
  assert(fixture.s3_contract.checksum_algorithms.map((value) => value.name).join(',') === expectedChecksums.join(','), 'checksum contract mismatch')
  assert(fixture.s3_contract.checksum_algorithms.every((value) => value.encoding === 'standard-base64' && value.header.startsWith('x-amz-checksum-')), 'checksum encoding contract mismatch')
  assert(fixture.s3_contract.session_token_header === 'x-amz-security-token', 'session token header contract mismatch')
  assert(fixture.s3_contract.post_policy_file_field === 'file', 'POST Policy file field contract mismatch')
  assert(fixture.s3_contract.post_policy_success_statuses.join(',') === '200,201,204', 'POST Policy status contract mismatch')
  assert(fixture.s3_contract.etag_examples.every((value) => value.startsWith('"') && value.endsWith('"')), 'ETag quote contract mismatch')
  const expectedOperations: Record<string, [string, number, string]> = {
    conditional_get_not_modified: ['GET', 304, 'empty_body_with_etag'],
    conditional_precondition_failed: ['PUT', 412, 's3_error'],
    copy_object: ['PUT', 200, 'CopyObjectResult'],
    delete_objects: ['POST', 200, 'DeleteResult'],
    post_policy_created: ['POST', 201, 'PostResponse'],
    post_policy_no_content: ['POST', 204, 'empty_body'],
  }
  for (const contract of fixture.s3_contract.operation_contracts) {
    const expected = expectedOperations[contract.operation]
    assert(expected !== undefined, `unknown S3 operation contract: ${contract.operation}`)
    assert(contract.method === expected[0] && contract.status === expected[1] && contract.response === expected[2], `S3 operation contract mismatch for ${contract.operation}`)
    delete expectedOperations[contract.operation]
  }
  assert(Object.keys(expectedOperations).length === 0, 'S3 operation contract incomplete')
}

const configPath = process.env.ZIGFS_CONFORMANCE_CONFIG
const fixturePath = process.env.ZIGFS_CONFORMANCE_FIXTURE
assert(configPath, 'ZIGFS_CONFORMANCE_CONFIG is required')
assert(fixturePath, 'ZIGFS_CONFORMANCE_FIXTURE is required')

const config = await loadJson<RuntimeConfig>(configPath)
const fixture = await loadJson<Fixture>(fixturePath)
await verifySharedVectors(fixture)

const suffix = Date.now().toString(36)
const bucket = `phase7-ts-${suffix}`
const objectKey = 'stream-object.bin'
const multipartKey = 'multipart-object.bin'
const client = new S3ConformanceClient(config, fixture.stream)
const cleanup = ['page-a', 'page-b', objectKey, multipartKey]

try {
  await client.createBucket(bucket)
  await client.putPattern(bucket, objectKey, BigInt(fixture.stream.object_size))
  await client.verifyPatternGet(bucket, objectKey, BigInt(fixture.stream.object_size))
  await client.verifyRange(bucket, objectKey)
  await client.verifyPagination(bucket)
  await client.verifyMultipart(bucket, multipartKey)
  await client.verifyMissingError(bucket)
  await client.verifyCancellation(bucket, objectKey)
} finally {
  for (const key of cleanup) await client.deleteObject(bucket, key).catch(() => undefined)
  await client.deleteBucket(bucket).catch(() => undefined)
}

console.log('TypeScript/Web conformance: PASS')
