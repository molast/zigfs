import type { DisplayPreferences } from '../lib/dateTime'
export interface ApiErrorBody {
  code: string
  message: string
  request_id: string
  details: Record<string, unknown>
}

export interface AdminSession {
  auth_source?: 'deployment' | 'local' | 'oidc' | 'sts'
  root_access_key?: string | null
  session_access_key?: string | null
  display_preferences?: DisplayPreferences | null
  display_name?: string
  email?: string
  federated?: boolean
  refreshable?: boolean
  subject_id: string
  is_root: boolean
  authenticated: boolean
  username: string
  expires_at: number
  capabilities?: { admin: boolean; kms: boolean; s3: boolean; sts: boolean }
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
  access_policy: 'Private' | 'Readonly' | 'Public' | 'Custom'
  object_ownership: 'BucketOwnerEnforced'
  block_public_access: boolean
  tags_json?: string
  kms_key_id?: string
  encryption: 'Disabled' | 'Enabled' | 'KMS'
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

export type AuditCategory = 'object_storage' | 'identity' | 'access_control' | 'bucket_management' | 'system_management' | 'kms' | 'security'
export type AuditStatus = 'success' | 'failure' | 'denied' | 'error' | 'unknown'
export interface AuditOperation { name: string; category: AuditCategory; resource_type: string; service: string; is_read_only: boolean }
export interface AuditOptions { categories: AuditCategory[]; operations: AuditOperation[] }
export interface StructuredAuditEvent extends AuditEvent {
  schema_version: string
  event_id: string
  event_time: string
  event_category: AuditCategory
  event_type: string
  event_action: string
  request: { request_id: string; method: string; protocol?: string | null; path: string; query: Record<string, string | null>; user_agent?: string | null; source_ip?: string | null }
  identity: { auth_type: string; principal_id?: string | null; principal_name?: string | null; access_key_id?: string | null; session_id?: string | null }
  resource: { type: string; bucket?: string | null; object_key?: string | null; version_id?: string | null; name?: string | null }
  operation: { name: string; service: string; is_read_only: boolean }
  response: { status: AuditStatus; http_status: number; error_code?: string | null; error_message?: string | null; duration_ms: number }
  metadata: { region?: string | null; server_id?: string | null; legacy?: boolean }
}
export interface AuditQuery { cursor?: string; limit?: number; from?: string; to?: string; category?: string; action?: string; outcome?: string; actor?: string; bucket?: string; request_id?: string; service?: string; event_type?: string; source_ip?: string }
export interface AuditPage { items: StructuredAuditEvent[]; next_cursor?: string | null }

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
  pending_api_address?: string
  api_restart_required?: boolean
  pending_admin_listen_address?: string
  admin_restart_required?: boolean
  upstream_endpoint?: string
  pending_upstream_endpoint?: string
  trusted_proxies?: string[]
  admin_listen_address?: string
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
  policy_document?: string
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
