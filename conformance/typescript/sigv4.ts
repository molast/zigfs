import type { QueryPair, RuntimeConfig, SigV4Vector } from './types.ts'

const encoder = new TextEncoder()
export const emptyPayloadHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

function bytes(value: string | Uint8Array): Uint8Array<ArrayBuffer> {
  return typeof value === 'string' ? encoder.encode(value) : Uint8Array.from(value)
}

function hex(value: ArrayBuffer | Uint8Array): string {
  const view = value instanceof Uint8Array ? value : new Uint8Array(value)
  return Array.from(view, (item) => item.toString(16).padStart(2, '0')).join('')
}

export async function sha256Hex(value: string | Uint8Array): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', bytes(value)))
}

async function hmac(key: string | Uint8Array, value: string): Promise<Uint8Array<ArrayBuffer>> {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    bytes(key),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  return new Uint8Array(await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(value)))
}

function encodeComponent(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  )
}

export function canonicalQuery(query: QueryPair[]): string {
  return query
    .map(([name, value]) => [encodeComponent(name), encodeComponent(value)] as const)
    .sort(([leftName, leftValue], [rightName, rightValue]) =>
      leftName === rightName ? leftValue.localeCompare(rightValue) : leftName.localeCompare(rightName),
    )
    .map(([name, value]) => `${name}=${value}`)
    .join('&')
}

export function canonicalPath(path: string): string {
  return path.split('/').map(encodeComponent).join('/')
}

function normalizeHeaderValue(value: string): string {
  return value.trim().replace(/\s+/g, ' ')
}

async function signature(
  secretKey: string,
  scopeDate: string,
  region: string,
  service: string,
  stringToSign: string,
): Promise<string> {
  const dateKey = await hmac(`AWS4${secretKey}`, scopeDate)
  const regionKey = await hmac(dateKey, region)
  const serviceKey = await hmac(regionKey, service)
  const signingKey = await hmac(serviceKey, 'aws4_request')
  return hex(await hmac(signingKey, stringToSign))
}

export async function signatureForVector(vector: SigV4Vector): Promise<string> {
  const canonicalHeaders = vector.headers
    .map(([name, value]) => `${name.toLowerCase()}:${normalizeHeaderValue(value)}\n`)
    .join('')
  const canonicalRequest = [
    vector.method,
    vector.path,
    canonicalQuery(vector.query),
    canonicalHeaders,
    vector.signed_headers,
    vector.payload_hash,
  ].join('\n')
  const scope = `${vector.scope_date}/${vector.region}/${vector.service}/aws4_request`
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    vector.amz_date,
    scope,
    await sha256Hex(canonicalRequest),
  ].join('\n')
  return signature(vector.secret_key, vector.scope_date, vector.region, vector.service, stringToSign)
}

function timestamp(date: Date): { amzDate: string; scopeDate: string } {
  const iso = date.toISOString().replace(/[:-]|\.\d{3}/g, '')
  return { amzDate: iso, scopeDate: iso.slice(0, 8) }
}

export async function signRequest(
  config: RuntimeConfig,
  method: string,
  path: string,
  query: QueryPair[] = [],
  payloadHash = emptyPayloadHash,
  additionalHeaders: Record<string, string> = {},
): Promise<{ url: string; headers: Headers }> {
  const endpoint = new URL(config.endpoint)
  const { amzDate, scopeDate } = timestamp(new Date())
  const signed = new Map<string, string>([
    ['host', endpoint.host],
    ['x-amz-content-sha256', payloadHash],
    ['x-amz-date', amzDate],
  ])
  for (const [name, value] of Object.entries(additionalHeaders)) {
    if (name.toLowerCase().startsWith('x-amz-')) signed.set(name.toLowerCase(), value)
  }

  const names = [...signed.keys()].sort()
  const canonicalHeaders = names.map((name) => `${name}:${normalizeHeaderValue(signed.get(name)!)}\n`).join('')
  const signedHeaders = names.join(';')
  const canonicalRequest = [
    method,
    canonicalPath(path),
    canonicalQuery(query),
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n')
  const scope = `${scopeDate}/${config.region}/s3/aws4_request`
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    await sha256Hex(canonicalRequest),
  ].join('\n')
  const value = await signature(config.secret_key, scopeDate, config.region, 's3', stringToSign)
  const headers = new Headers(additionalHeaders)
  headers.set('x-amz-content-sha256', payloadHash)
  headers.set('x-amz-date', amzDate)
  headers.set(
    'authorization',
    `AWS4-HMAC-SHA256 Credential=${config.access_key}/${scope},SignedHeaders=${signedHeaders},Signature=${value}`,
  )

  const base = config.endpoint.replace(/\/$/, '')
  const queryString = canonicalQuery(query)
  return { url: `${base}${canonicalPath(path)}${queryString ? `?${queryString}` : ''}`, headers }
}
