export type QueryPair = readonly [name: string, value: string]

export interface RuntimeConfig {
  endpoint: string
  access_key: string
  secret_key: string
  region: string
  owner: string
}

export interface SigV4Vector {
  method: string
  path: string
  query: QueryPair[]
  headers: QueryPair[]
  signed_headers: string
  payload_hash: string
  access_key: string
  secret_key: string
  scope_date: string
  amz_date: string
  region: string
  service: string
  expected_signature: string
}

export interface RetryCase {
  operation: string
  method: string
  status: number
  body_replayable: boolean
  response_started: boolean
  cancelled: boolean
  expected: boolean
}

export interface StreamVector {
  object_size: string
  multipart_part_sizes: string[]
  chunk_size: number
  range_start: string
  range_end: string
  pattern_multiplier: number
  pattern_increment: number
  pattern_modulus: number
}

export interface Fixture {
  schema_version: number
  vector_revision: number
  sigv4: SigV4Vector
  uint64_values: string[]
  opaque_values: string[]
  errors: Array<{
    status: number
    xml: string
    code: string
    request_id: string
    retryable: boolean
  }>
  retry_cases: RetryCase[]
  stream: StreamVector
}
