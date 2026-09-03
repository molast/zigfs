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
  enabled: boolean
  created_at: string
}

export interface CreatedAccessKey extends AccessKey {
  secret_key: string
}
