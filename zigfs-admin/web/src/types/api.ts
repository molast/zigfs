export interface ApiErrorBody {
  code: string
  message: string
  request_id: string
  details: Record<string, unknown>
}

export interface AdminSession {
  authenticated: boolean
  username: string
  expires_at: number
}

export interface SystemInfo {
  version: string
  uptime: number
  storage_used: number
  objects: number
  buckets: number
}

export interface Bucket {
  name: string
  owner: string
  created_at: string
}

export interface ObjectSummary {
  key: string
  size: number
  etag: string
  last_modified: string
}

export interface AccessKey {
  id: string
  access_key: string
  owner: string
  enabled: boolean
  policy: CredentialPolicy
  created_at: string
}

export interface CredentialPolicy {
  bucket_read: boolean
  bucket_write: boolean
  object_read: boolean
  object_write: boolean
}

export interface CreatedAccessKey extends AccessKey {
  secret_key: string
}

export interface ListObjectsResponse {
  items: ObjectSummary[]
  continuation_token?: string
}

export interface PresignObjectResponse {
  url: string
  expires_at: string
}

export interface StorageInfo {
  measurement: 'logical_object_bytes'
  total: number | null
  used: number
  available: number | null
}

export interface ManagementHealth {
  status: 'ready' | 'degraded' | 'recovery'
  recovery: 'initializing' | 'recovering' | 'ready' | 'recovery_required'
  reason: string
  actions: string[]
}

export interface Settings {
  api_address: string
  s3_public_endpoint: string
  s3_region: string
  request_time_skew_seconds: number
  multipart_expiry_seconds: number
  stream_buffer_size: number
  metrics_enabled: boolean
  metrics_address: string
  admin_session_ttl_seconds: number
  reload_required: true
}
