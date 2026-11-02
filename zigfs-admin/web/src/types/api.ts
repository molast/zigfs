export interface ApiErrorBody {
  code: string
  message: string
  request_id: string
  details: Record<string, unknown>
}

export interface AdminSession {
  display_name?: string
  email?: string
  federated?: boolean
  refreshable?: boolean
  subject_id: string
  is_root: boolean
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
  versioning: 'Unversioned' | 'Enabled' | 'Suspended'
  lifecycle_enabled: boolean
}

export interface BucketConfiguration {
  name: string
  versioning: 'Unversioned' | 'Enabled' | 'Suspended'
  access_policy: 'Private' | 'Readonly' | 'Public'
  object_ownership: 'BucketOwnerEnforced'
  block_public_access: boolean
  tags_json?: string
  encryption: 'Disabled' | 'Enabled'
  max_bytes?: number
  max_objects?: number
  retention_enabled: boolean
  retention_duration_seconds?: number
  retention_mode?: 'GOVERNANCE' | 'COMPLIANCE'
  object_locking: boolean
  replication_status: 'UNAVAILABLE'
  replication_enabled: false
  replication_reason: 'SECOND_SITE_REQUIRED'
  lifecycle_configuration?: string
}

export interface BucketUsage {
  bytes: number
  objects: number
}

export interface AuditEvent {
  timestamp_unix_seconds: number
  request_id: string
  actor: string
  action: string
  target: string
  outcome: string
}

export interface ListBucketEventsResponse {
  items: AuditEvent[]
  next_cursor?: string
}

export interface ObjectVersion {
  key: string
  version_id: string
  is_latest: boolean
  is_delete_marker: boolean
  size: number
  last_modified: string
  retention_until_unix_seconds?: number
  retention_mode?: 'GOVERNANCE' | 'COMPLIANCE'
  legal_hold?: boolean
}

export interface ObjectSummary {
  key: string
  size: number
  etag: string
  last_modified: string
  retention_until_unix_seconds?: number
  retention_mode?: 'GOVERNANCE' | 'COMPLIANCE'
  legal_hold?: boolean
}

export interface AccessKey {
  policy_document: string
  name: string
  description: string
  inherit_policy: boolean
  id: string
  access_key: string
  secret_key?: string
  session_token?: string
  kind: 'permanent' | 'temporary'
  owner: string
  enabled: boolean
  policy: CredentialPolicy
  created_at: string
  expires_at?: string
}

export interface CredentialPolicy {
  bucket_read: boolean
  bucket_write: boolean
  object_read: boolean
  object_write: boolean
  bypass_governance_retention: boolean
}

export interface CreatedAccessKey extends AccessKey {
  secret_key: string
}

export interface ListObjectsResponse {
  items: ObjectSummary[]
  common_prefixes?: string[]
  directories?: DirectorySummary[]
  is_truncated: boolean
  continuation_token?: string
}

export interface DirectorySummary {
  type: 'directory'
  key: string
  last_modified: string
}

export interface PresignObjectResponse {
  url: string
  expires_at: string
  required_headers: Record<string, string>
}

export interface MultipartUploadSummary {
  upload_id: string
  bucket: string
  key: string
  initiated_at: string
}

export interface MultipartPart {
  part_number: number
  size: number
  etag: string
  last_modified: string
}

export interface MultipartUpload extends MultipartUploadSummary {
  content_type: string
  parts: MultipartPart[]
  uploaded_bytes: number
}

export interface ListMultipartUploadsResponse {
  items: MultipartUploadSummary[]
  is_truncated: boolean
  next_key_marker?: string
  next_upload_id_marker?: string
}

export interface StorageInfo {
  physical_used?: number | null
  measurement: 'logical_object_bytes'
  total: number | null
  used: number
  available: number | null
}

export interface StorageScanReport {
  partition: number | null
  partitions: number
  scanned_generations: number
  retained_generations: number
  removed_generations: number
  scanned_bytes: number
  retained_bytes: number
  removed_bytes: number
  expired_multipart_uploads: number
}

export interface StorageScannerStatus {
  running?: boolean
  last_completed_at?: number | null
  last_duration_ms?: number | null
  last_attempt_succeeded?: boolean | null
  partitions: number
  next_partition: number
  last_scan: StorageScanReport | null
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
  s3_virtual_hosted_style: boolean
  s3_region: string
  request_time_skew_seconds: number
  multipart_expiry_seconds: number
  lifecycle_scan_interval_seconds: number
  stream_buffer_size: number
  metrics_enabled: boolean
  metrics_address: string
  admin_session_ttl_seconds: number
  reload_required: true
}

export interface AccessKeyCreate {
  access_key: string
  secret_key: string
  name: string
  description: string
  expires_at?: string
  inherit_policy: boolean
  policy?: CredentialPolicy
}

export interface AccessKeyUpdate {
  enabled?: boolean
  name?: string
  description?: string
  inherit_policy?: boolean
  expires_at?: string
  clear_expiry?: boolean
  policy_document?: string
}
