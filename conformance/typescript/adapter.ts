import { emptyPayloadHash, sha256Hex, signRequest } from './sigv4.ts'
import type { QueryPair, RuntimeConfig, StreamVector } from './types.ts'

const unsignedPayload = 'UNSIGNED-PAYLOAD'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function xmlElement(xml: string, name: string): string | undefined {
  const match = xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))
  return match?.[1]
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
}

function xmlElements(xml: string, name: string): string[] {
  return [...xml.matchAll(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`, 'g'))].map(
    (match) => match[1],
  )
}

function xmlEscape(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

function patternByte(offset: bigint, vector: StreamVector): number {
  return Number(
    (offset * BigInt(vector.pattern_multiplier) + BigInt(vector.pattern_increment)) %
      BigInt(vector.pattern_modulus),
  )
}

function patternStream(size: bigint, start: bigint, vector: StreamVector): ReadableStream<Uint8Array> {
  let offset = 0n
  return new ReadableStream({
    pull(controller) {
      if (offset === size) {
        controller.close()
        return
      }
      const remaining = size - offset
      const length = Number(remaining < BigInt(vector.chunk_size) ? remaining : BigInt(vector.chunk_size))
      const chunk = new Uint8Array(length)
      for (let index = 0; index < length; index += 1) {
        chunk[index] = patternByte(start + offset + BigInt(index), vector)
      }
      offset += BigInt(length)
      controller.enqueue(chunk)
    },
  })
}

interface StreamingRequestInit extends RequestInit {
  duplex: 'half'
}

export class S3ConformanceClient {
  private readonly config: RuntimeConfig
  private readonly vector: StreamVector

  constructor(config: RuntimeConfig, vector: StreamVector) {
    this.config = config
    this.vector = vector
  }

  private async request(
    method: string,
    path: string,
    query: QueryPair[] = [],
    init: RequestInit = {},
    payloadHash = emptyPayloadHash,
  ): Promise<Response> {
    const additionalHeaders: Record<string, string> = {}
    new Headers(init.headers).forEach((value, name) => { additionalHeaders[name] = value })
    const signed = await signRequest(this.config, method, path, query, payloadHash, additionalHeaders)
    const headers = new Headers(init.headers)
    signed.headers.forEach((value, name) => headers.set(name, value))
    return fetch(signed.url, { ...init, method, headers })
  }

  private async expect(response: Response, status: number, operation: string): Promise<Response> {
    if (response.status !== status) {
      throw new Error(`${operation}: expected ${status}, received ${response.status}: ${await response.text()}`)
    }
    return response
  }

  async createBucket(bucket: string): Promise<void> {
    await this.expect(await this.request('PUT', `/${bucket}`), 200, 'CreateBucket')
    await this.expect(await this.request('HEAD', `/${bucket}`), 200, 'HeadBucket')
  }

  async putPattern(bucket: string, key: string, size: bigint, start = 0n): Promise<string> {
    const body = patternStream(size, start, this.vector)
    const headers = { 'content-length': size.toString(), 'content-type': 'application/octet-stream' }
    const signed = await signRequest(this.config, 'PUT', `/${bucket}/${key}`, [], unsignedPayload)
    signed.headers.set('content-length', size.toString())
    signed.headers.set('content-type', 'application/octet-stream')
    const init: StreamingRequestInit = { method: 'PUT', headers: signed.headers, body, duplex: 'half' }
    const response = await this.expect(await fetch(signed.url, init), 200, 'PutObject')
    const etag = response.headers.get('etag')
    assert(etag, 'PutObject: missing ETag')
    return etag
  }

  async putBytes(bucket: string, key: string, value: Uint8Array): Promise<string> {
    const response = await this.expect(
      await this.request(
        'PUT',
        `/${bucket}/${key}`,
        [],
        { body: Uint8Array.from(value).buffer, headers: { 'content-length': value.byteLength.toString() } },
        await sha256Hex(value),
      ),
      200,
      'PutObject',
    )
    const etag = response.headers.get('etag')
    assert(etag, 'PutObject: missing ETag')
    return etag
  }

  async verifyPatternGet(bucket: string, key: string, size: bigint, start = 0n): Promise<void> {
    const response = await this.expect(await this.request('GET', `/${bucket}/${key}`), 200, 'GetObject')
    assert(response.body, 'GetObject: missing response stream')
    const reader = response.body.getReader()
    let offset = 0n
    while (true) {
      const result = await reader.read()
      if (result.done) break
      for (let index = 0; index < result.value.length; index += 1) {
        assert(
          result.value[index] === patternByte(start + offset + BigInt(index), this.vector),
          `GetObject: byte mismatch at ${offset + BigInt(index)}`,
        )
      }
      offset += BigInt(result.value.length)
    }
    assert(offset === size, `GetObject: expected ${size} bytes, received ${offset}`)
  }

  async verifyRange(bucket: string, key: string): Promise<void> {
    const start = BigInt(this.vector.range_start)
    const end = BigInt(this.vector.range_end)
    const response = await this.expect(
      await this.request('GET', `/${bucket}/${key}`, [], { headers: { range: `bytes=${start}-${end}` } }),
      206,
      'Range GetObject',
    )
    assert(response.headers.get('content-range') === `bytes ${start}-${end}/${this.vector.object_size}`, 'Range: invalid Content-Range')
    const bytes = new Uint8Array(await response.arrayBuffer())
    assert(BigInt(bytes.length) === end - start + 1n, 'Range: invalid body length')
    for (let index = 0; index < bytes.length; index += 1) {
      assert(bytes[index] === patternByte(start + BigInt(index), this.vector), 'Range: byte mismatch')
    }
  }

  async verifyPagination(bucket: string): Promise<void> {
    await this.putBytes(bucket, 'page-a', new TextEncoder().encode('a'))
    await this.putBytes(bucket, 'page-b', new TextEncoder().encode('b'))
    const first = await this.expect(
      await this.request('GET', `/${bucket}`, [['list-type', '2'], ['max-keys', '1'], ['prefix', 'page-']]),
      200,
      'ListObjectsV2 page 1',
    )
    const firstXml = await first.text()
    const token = xmlElement(firstXml, 'NextContinuationToken')
    assert(token, 'ListObjectsV2: missing continuation token')
    assert(xmlElement(firstXml, 'Key') === 'page-a', 'ListObjectsV2: unexpected first key')
    const second = await this.expect(
      await this.request('GET', `/${bucket}`, [
        ['list-type', '2'],
        ['max-keys', '1'],
        ['prefix', 'page-'],
        ['continuation-token', token],
      ]),
      200,
      'ListObjectsV2 page 2',
    )
    assert(xmlElement(await second.text(), 'Key') === 'page-b', 'ListObjectsV2: unexpected second key')
  }

  private async createMultipart(bucket: string, key: string): Promise<string> {
    const response = await this.expect(
      await this.request('POST', `/${bucket}/${key}`, [['uploads', '']]),
      200,
      'CreateMultipartUpload',
    )
    const uploadId = xmlElement(await response.text(), 'UploadId')
    assert(uploadId, 'CreateMultipartUpload: missing UploadId')
    return uploadId
  }

  private async uploadPart(
    bucket: string,
    key: string,
    uploadId: string,
    partNumber: number,
    size: bigint,
    start: bigint,
  ): Promise<string> {
    const body = patternStream(size, start, this.vector)
    const signed = await signRequest(
      this.config,
      'PUT',
      `/${bucket}/${key}`,
      [['partNumber', partNumber.toString()], ['uploadId', uploadId]],
      unsignedPayload,
    )
    signed.headers.set('content-length', size.toString())
    const response = await this.expect(
      await fetch(signed.url, { method: 'PUT', headers: signed.headers, body, duplex: 'half' } as StreamingRequestInit),
      200,
      `UploadPart ${partNumber}`,
    )
    const etag = response.headers.get('etag')
    assert(etag, `UploadPart ${partNumber}: missing ETag`)
    return etag
  }

  async verifyMultipart(bucket: string, key: string): Promise<void> {
    const uploadId = await this.createMultipart(bucket, key)
    const firstSize = BigInt(this.vector.multipart_part_sizes[0])
    const secondSize = BigInt(this.vector.multipart_part_sizes[1])
    const firstETag = await this.uploadPart(bucket, key, uploadId, 1, firstSize, 0n)
    const secondETag = await this.uploadPart(bucket, key, uploadId, 2, secondSize, firstSize)

    const list = await this.expect(
      await this.request('GET', `/${bucket}/${key}`, [['uploadId', uploadId]]),
      200,
      'ListParts',
    )
    const partNumbers = xmlElements(await list.text(), 'PartNumber')
    assert(partNumbers.join(',') === '1,2', `ListParts: unexpected parts ${partNumbers.join(',')}`)

    const completeBody = `<CompleteMultipartUpload><Part><ETag>${xmlEscape(firstETag)}</ETag><PartNumber>1</PartNumber></Part><Part><ETag>${xmlEscape(secondETag)}</ETag><PartNumber>2</PartNumber></Part></CompleteMultipartUpload>`
    await this.expect(
      await this.request(
        'POST',
        `/${bucket}/${key}`,
        [['uploadId', uploadId]],
        { body: completeBody, headers: { 'content-type': 'application/xml' } },
        await sha256Hex(completeBody),
      ),
      200,
      'CompleteMultipartUpload',
    )
    await this.verifyPatternGet(bucket, key, firstSize + secondSize)

    const abortedUpload = await this.createMultipart(bucket, `${key}-aborted`)
    await this.expect(
      await this.request('DELETE', `/${bucket}/${key}-aborted`, [['uploadId', abortedUpload]]),
      204,
      'AbortMultipartUpload',
    )
    const missing = await this.request('GET', `/${bucket}/${key}-aborted`, [['uploadId', abortedUpload]])
    assert(missing.status === 404, `aborted ListParts: expected 404, received ${missing.status}`)
    assert(xmlElement(await missing.text(), 'Code') === 'NoSuchUpload', 'aborted ListParts: wrong error')
  }

  async verifyMissingError(bucket: string): Promise<void> {
    const response = await this.request('GET', `/${bucket}/missing-object`)
    assert(response.status === 404, `missing object: expected 404, received ${response.status}`)
    const xml = await response.text()
    assert(xmlElement(xml, 'Code') === 'NoSuchKey', 'missing object: wrong error code')
    const requestId = xmlElement(xml, 'RequestId')
    assert(requestId && requestId === response.headers.get('x-amz-request-id'), 'missing object: Request ID mismatch')
  }

  async verifyCancellation(bucket: string, key: string): Promise<void> {
    const controller = new AbortController()
    const response = await this.expect(
      await this.request('GET', `/${bucket}/${key}`, [], { signal: controller.signal }),
      200,
      'cancel GetObject',
    )
    assert(response.body, 'cancel GetObject: missing stream')
    const reader = response.body.getReader()
    const first = await reader.read()
    assert(!first.done && first.value.length > 0, 'cancel GetObject: no first chunk')
    controller.abort()
    await reader.cancel().catch(() => undefined)
    await this.expect(await this.request('HEAD', `/${bucket}/${key}`), 200, 'HeadObject after cancel')
  }

  async deleteObject(bucket: string, key: string): Promise<void> {
    await this.expect(await this.request('DELETE', `/${bucket}/${key}`), 204, `DeleteObject ${key}`)
  }

  async deleteBucket(bucket: string): Promise<void> {
    await this.expect(await this.request('DELETE', `/${bucket}`), 204, 'DeleteBucket')
  }
}
