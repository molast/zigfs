import type { DisplayPreferences } from '../lib/dateTime'
import type { AuditOptions, AuditQuery, AuditPage } from '@/types/api'
export interface LogConfig { level: string; format: string; output: string; directory: string; retention: string; maxSize: string; sizeUnit: string; cleanup: string; downloads: string; range: string }
export interface LogQuery { content: string; truncated: boolean; range: string }
import type { KmsDraft } from '@/features/settings/KmsSettingsPanel'
export interface KmsStatus { state: 'unconfigured' | 'configured' | 'running' | 'error'; errorMessage: string; healthChecked: boolean; healthy: boolean; configured: boolean; config: KmsDraft; tokenConfigured: boolean; staticSecretKeyConfigured: boolean }
export interface KmsKey { id: string; name: string; description: string; status: string; algorithm: string; usage: string; version: number; createdAt: string | null; rotatedAt: string | null; deletionDate: string | null; manageable: boolean }
export interface KmsKeyList { items: KmsKey[]; canCreate: boolean; canRekey: boolean }
export interface KmsCreateKey { name: string; description: string; setAsDefault: boolean }
export type KmsKeyAction = 'rotate' | 'schedule-deletion' | 'cancel-deletion' | 'delete'
import { t } from '@/locales'
export interface OIDCProvider {
  provider_id: string; display_name: string; enabled: boolean; configuration_url: string;
  client_id: string; client_secret: string; has_secret?: boolean; environment_managed?: boolean; scopes: string; audiences: string;
  dynamic_redirect: boolean; redirect_uri: string; claim_name: string; claim_prefix: string;
  role_policy: string; groups_claim: string; roles_claim: string; email_claim: string; username_claim: string;
}
export interface ManagedIdentity { name: string; description: string; enabled: boolean; policies: string[]; tags_json?: string; updated_at: number }
export interface ManagedUser extends ManagedIdentity { groups: string[] }
export interface ManagedGroup extends ManagedIdentity { members: string[] }
export interface UserWrite { name: string; description: string; enabled: boolean; policies: string[]; groups?: string[]; password?: string }
export type GroupWrite = Omit<ManagedGroup, 'updated_at'>
export interface ManagedPolicy { name: string; document: string }
export interface Organization { id: string; name: string; enabled: boolean; paths?: string[]; members?: string[] }
export interface Role { id: string; name: string; organization_id?: string; enabled: boolean; max_session_seconds: number; trust_policy: string; policies?: string[]; permissions_boundary?: string; tags_json?: string }
export interface AssumeRoleRequest { role_id: string; session_name: string; duration_seconds?: number; external_id?: string; source_identity?: string; session_tags_json?: string; transitive_tag_keys_json?: string; session_policy?: string }
export interface AssumeRoleResponse { access_key: string; secret_key: string; session_token: string; role_id: string; session_name: string; expires_at: number }
export interface RoleSession { access_key: string; role_id: string; session_name: string; subject_id: string; expires_at: number; revoked: boolean }
import type {
  AccessKey,
  AccessKeyCreate,
  AccessKeyUpdate,
  AdminSession,
  ApiErrorBody,
  Bucket,
  BucketConfiguration,
  BucketUsage,
  ListBucketEventsResponse,
  CreatedAccessKey,
  CredentialPolicy,
  ListObjectsResponse,
  ListMultipartUploadsResponse,
  MultipartUpload,
  ObjectSummary,
  ObjectVersion,
  ManagementHealth,
  PresignObjectResponse,
  Settings,
  StorageInfo,
  StorageScanReport,
  StorageScannerStatus,
  SystemInfo,
} from '../types/api'

const REQUEST_TIMEOUT_MS = 15000
// Complete reads and publishes the whole object; allow the BFF's 15-minute
// upstream timeout to return an error before aborting in the browser.
const MULTIPART_COMPLETE_TIMEOUT_MS = 16 * 60 * 1000

export interface AuthenticationValues {
  admin_session_ttl_seconds: number
  request_time_skew_seconds: number
}
export interface AuthenticationSettings {
  current: AuthenticationValues
  pending: AuthenticationValues
  restart_required: boolean
}
export interface DisplaySettings extends DisplayPreferences { supported_timezones: string[] }
export interface RegionSettings {
  s3_region: string
  pending_s3_region: string
  restart_required: boolean
}
export interface InstanceSettings {
  service_name: string
  description: string
  instance_id: string
  started_at_unix_seconds: number
  uptime_seconds: number
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: ApiErrorBody,
  ) {
    super(body.message)
  }
}

export function createApiClient() {
  let oidcRefresh: Promise<AdminSession> | undefined
  async function request<T>(path: string, init: RequestInit = {}, timeoutMs = REQUEST_TIMEOUT_MS): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body) headers.set('Content-Type', 'application/json')

    const controller = new AbortController()
    let timedOut = false
    const timeout = window.setTimeout(() => {
      timedOut = true
      controller.abort()
    }, timeoutMs)
    let response: Response
    try {
      response = await fetch(path, {
        ...init,
        headers,
        credentials: 'same-origin',
        signal: init.signal ?? controller.signal,
      })
    } catch (reason) {
      if (timedOut) throw new Error(t('api.requestTimedOutCheckThatZigfsIsRunning'))
      throw reason
    } finally {
      window.clearTimeout(timeout)
    }

    if (!response.ok) {
      const fallback: ApiErrorBody = {
        code: 'RequestFailed',
        message: t('api.requestFailedWithStatusValue', { '0': response.status }),
        request_id: response.headers.get('X-Request-ID') ?? '',
        details: {},
      }
      const body = (await response.json().catch(() => fallback)) as ApiErrorBody
      if (response.status === 401) window.dispatchEvent(new CustomEvent('zigfs:session-expired'))
      throw new ApiError(response.status, body)
    }
    if (init.method && init.method !== 'GET' && init.method !== 'HEAD') {
      window.dispatchEvent(new CustomEvent('zigfs:permissions-changed', { detail: { path, method: init.method } }))
    }
    if (response.status === 204) return undefined as T
    return (await response.json()) as T
  }

  return {
    oidcLoginProviders: () => request<{ items: { provider_id: string; display_name: string }[] }>('/api/v1/auth/oidc/providers'),
    validateOIDCProvider: (value: OIDCProvider) => request<{ issuer: string; login_verified: boolean }>('/api/v1/oidc/validate', { method: 'POST', body: JSON.stringify(value) }),
    listOIDCProviders: () => request<{ items: OIDCProvider[]; login_supported: boolean }>('/api/v1/oidc/providers'),
    createOIDCProvider: (value: OIDCProvider) => request<OIDCProvider>('/api/v1/oidc/providers', { method: 'POST', body: JSON.stringify(value) }),
    updateOIDCProvider: (value: OIDCProvider) => request<OIDCProvider>(`/api/v1/oidc/providers/${encodeURIComponent(value.provider_id)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    deleteOIDCProvider: (id: string) => request<void>(`/api/v1/oidc/providers/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    listOrganizations: async () => (await request<{ items: Organization[] }>('/api/v1/organizations')).items,
    createOrganization: (value: Organization) => request<Organization>('/api/v1/organizations', { method: 'POST', body: JSON.stringify(value) }),
    updateOrganization: (value: Organization) => request<Organization>(`/api/v1/organizations/${encodeURIComponent(value.name)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    deleteOrganization: (name: string) => request<void>(`/api/v1/organizations/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    listRoles: async () => (await request<{ items: Role[] }>('/api/v1/roles')).items,
    createRole: (value: Role) => request<Role>('/api/v1/roles', { method: 'POST', body: JSON.stringify(value) }),
    updateRole: (value: Role) => request<Role>(`/api/v1/roles/${encodeURIComponent(value.name)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    deleteRole: (name: string) => request<void>(`/api/v1/roles/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    assumeRole: (value: AssumeRoleRequest) => request<AssumeRoleResponse>('/api/v1/sts/assume-role', { method: 'POST', body: JSON.stringify(value) }),
    listRoleSessions: async () => (await request<{ items: RoleSession[] }>('/api/v1/role-sessions')).items,
    revokeRoleSession: (accessKey: string) => request<void>(`/api/v1/role-sessions/${encodeURIComponent(accessKey)}/revoke`, { method: 'POST' }),
    listUsers: async () => (await request<{ items: ManagedUser[] }>('/api/v1/users')).items,
    getUser: (name: string) => request<ManagedUser>(`/api/v1/users/${encodeURIComponent(name)}`),
    createUser: (value: UserWrite) => request<ManagedUser>('/api/v1/users', { method: 'POST', body: JSON.stringify(value) }),
    updateUser: (value: UserWrite) => request<ManagedUser>(`/api/v1/users/${encodeURIComponent(value.name)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    deleteUser: (name: string) => request<void>(`/api/v1/users/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    listGroups: async () => (await request<{ items: ManagedGroup[] }>('/api/v1/groups')).items,
    getGroup: (name: string) => request<ManagedGroup>(`/api/v1/groups/${encodeURIComponent(name)}`),
    createGroup: (value: GroupWrite) => request<ManagedGroup>('/api/v1/groups', { method: 'POST', body: JSON.stringify(value) }),
    updateGroup: (value: GroupWrite) => request<ManagedGroup>(`/api/v1/groups/${encodeURIComponent(value.name)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    deleteGroup: (name: string) => request<void>(`/api/v1/groups/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    listPolicies: async () => (await request<{ items: ManagedPolicy[] }>('/api/v1/policies')).items,
    getPolicy: (name: string) => request<ManagedPolicy>(`/api/v1/policies/${encodeURIComponent(name)}`),
    createPolicy: (policy: ManagedPolicy) => request<ManagedPolicy>('/api/v1/policies', { method: 'POST', body: JSON.stringify(policy) }),
    updatePolicy: (policy: ManagedPolicy) => request<ManagedPolicy>(`/api/v1/policies/${encodeURIComponent(policy.name)}`, { method: 'PATCH', body: JSON.stringify(policy) }),
    deletePolicy: (name: string) => request<void>(`/api/v1/policies/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    ready: () => request<{ status: 'ready' }>('/health/ready'),
    login: (username: string, password: string) =>
      request<AdminSession>('/api/v1/auth/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      }),
    stsLogin: (username: string, secretKey: string, sessionToken: string) =>
      request<AdminSession>('/api/v1/auth/sts-login', { method: 'POST', body: JSON.stringify({ username, secret_key: secretKey, session_token: sessionToken }) }),
    refreshOIDC: () => {
      if (!oidcRefresh) oidcRefresh = request<AdminSession>('/api/v1/auth/oidc/refresh', { method: 'POST' }).finally(() => { oidcRefresh = undefined })
      return oidcRefresh
    },
    endOIDCSession: () => request<{ logout_url: string }>('/api/v1/auth/oidc/end-session', { method: 'POST' }),
    session: () => request<AdminSession>('/api/v1/auth/session'),
    logout: () => request<void>('/api/v1/auth/logout', { method: 'POST' }),
    system: () => request<SystemInfo>('/api/v1/system'),
    storage: () => request<StorageInfo>('/api/v1/storage'),
    storageScanner: () => request<StorageScannerStatus>('/api/v1/storage/scanner'),
    runStorageGC: () => request<StorageScanReport>('/api/v1/storage/gc', { method: 'POST' }),
    managementHealth: () => request<ManagementHealth>('/api/v1/management-health'),
    auditLogSettings: () => request<LogConfig>('/api/v1/settings/audit-logs'),
    saveAuditLogSettings: (config: LogConfig) => request<LogConfig>('/api/v1/settings/audit-logs', { method: 'PUT', body: JSON.stringify({ ...config, output: 'file' }) }),
    queryAuditLogs: (download = false, range?: { from: number; to: number }) => request<LogQuery>(`/api/v1/settings/audit-logs/${download ? 'download' : 'query'}${range ? `?from=${range.from}&to=${range.to}` : ''}`),
    logSettings: () => request<LogConfig>('/api/v1/settings/logs'),
    saveLogSettings: (config: LogConfig) => request<LogConfig>('/api/v1/settings/logs', { method: 'PUT', body: JSON.stringify(config) }),
    queryLogs: (download = false, range?: { from: number; to: number }) => request<LogQuery>(`/api/v1/settings/logs/${download ? 'download' : 'query'}${range ? `?from=${range.from}&to=${range.to}` : ''}`),
    saveListeners: (value: { api_address: string; admin_listen_address: string; upstream_endpoint: string }) => request<void>('/api/v1/settings/listeners', { method: 'PUT', body: JSON.stringify(value) }),
    saveNetworkSettings: (value: { s3_public_endpoint: string; s3_virtual_hosted_style: boolean; trusted_proxies: string[] }) => request('/api/v1/settings/network', { method: 'PUT', body: JSON.stringify(value) }),
    authenticationSettings: () => request<AuthenticationSettings>('/api/v1/settings/authentication'),
    saveAuthenticationSettings: (value: AuthenticationValues) => request<AuthenticationSettings>('/api/v1/settings/authentication', { method: 'PUT', body: JSON.stringify(value) }),
    displaySettings: () => request<DisplaySettings>('/api/v1/settings/display'),
    saveDisplaySettings: (value: DisplayPreferences) => request<DisplaySettings>('/api/v1/settings/display', { method: 'PUT', body: JSON.stringify(value) }),
    regionSettings: () => request<RegionSettings>('/api/v1/settings/region'),
    saveRegionSettings: (s3_region: string) => request<RegionSettings>('/api/v1/settings/region', { method: 'PUT', body: JSON.stringify({ s3_region }) }),
    instanceSettings: () => request<InstanceSettings>('/api/v1/settings/instance'),
    saveInstanceSettings: (value: { service_name: string; description: string }) => request<InstanceSettings>('/api/v1/settings/instance', { method: 'PUT', body: JSON.stringify(value) }),
    settings: () => request<Settings>('/api/v1/settings'),
    stopKms: () => request<KmsStatus>('/api/v1/settings/kms/stop', { method: 'POST' }),
    clearKmsCache: () => request<KmsStatus>('/api/v1/settings/kms/clear-cache', { method: 'POST' }),
    kmsKeys: () => request<KmsKeyList>('/api/v1/settings/kms/keys'),
    createKmsKey: (input: KmsCreateKey) => request<KmsKey>('/api/v1/settings/kms/keys', { method: 'POST', body: JSON.stringify(input) }),
    kmsKeyAction: (id: string, action: KmsKeyAction) => request<{ ok: boolean }>('/api/v1/settings/kms/keys/action', { method: 'POST', body: JSON.stringify({ id, action }) }),
    startKms: () => request<KmsStatus>('/api/v1/settings/kms/start', { method: 'POST' }),
    kmsSettings: () => request<KmsStatus>('/api/v1/settings/kms'),
    saveKmsSettings: (config: KmsDraft) => request<KmsStatus>('/api/v1/settings/kms', { method: 'PUT', body: JSON.stringify(config) }),
    listBuckets: async () => (await request<{ items: Bucket[] }>('/api/v1/buckets')).items,
    createBucket: (value: { name: string; versioning?: boolean; object_locking?: boolean; max_bytes?: number; max_objects?: number }) =>
      request<Bucket>('/api/v1/buckets', {
        method: 'POST',
        body: JSON.stringify(value),
      }),
    deleteBucket: (name: string) =>
      request<void>(`/api/v1/buckets/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    getBucketPolicy: (name: string) => request<{ document: string }>(`/api/v1/buckets/${encodeURIComponent(name)}/policy`),
    putBucketPolicy: (name: string, document: string) => request<{ document: string }>(`/api/v1/buckets/${encodeURIComponent(name)}/policy`, { method: 'PUT', body: JSON.stringify({ document }) }),
    deleteBucketPolicy: (name: string) => request<void>(`/api/v1/buckets/${encodeURIComponent(name)}/policy`, { method: 'DELETE' }),
    getBucketConfiguration: (name: string) =>
      request<BucketConfiguration>(`/api/v1/buckets/${encodeURIComponent(name)}/configuration`),
    getBucketUsage: (name: string) =>
      request<BucketUsage>(`/api/v1/buckets/${encodeURIComponent(name)}/usage`),
    auditOptions: () => request<AuditOptions>('/api/v1/audit-events/options'),
    listAuditEvents: (filters: AuditQuery = {}) => {
      const query = new URLSearchParams()
      for (const [key, value] of Object.entries(filters)) if (value !== undefined && value !== '') query.set(key, String(value))
      return request<AuditPage>(`/api/v1/audit-events?${query.toString()}`)
    },
    listBucketEvents: (name: string, cursor = '', limit = 50, from = '', to = '', action = '', outcome = '') => {
      const query = new URLSearchParams({ limit: String(limit) })
      if (cursor) query.set('cursor', cursor)
      if (from) query.set('from', from)
      if (to) query.set('to', to)
      if (action) query.set('action', action)
      if (outcome) query.set('outcome', outcome)
      return request<ListBucketEventsResponse>(`/api/v1/buckets/${encodeURIComponent(name)}/events?${query.toString()}`)
    },
    updateBucketConfiguration: (
      name: string,
      update: { versioning?: 'Enabled' | 'Suspended'; access_policy?: 'Private' | 'Readonly' | 'Public' | 'Custom'; block_public_access?: boolean; tags_json?: string; clear_tags?: boolean; encryption?: 'Disabled' | 'Enabled' | 'KMS'; kms_key_id?: string; max_bytes?: number; max_objects?: number; retention_enabled?: boolean; retention_duration_seconds?: number; retention_mode?: 'GOVERNANCE' | 'COMPLIANCE'; object_locking?: boolean; replication_enabled?: boolean; lifecycle_configuration?: string; clear_lifecycle?: boolean },
    ) => request<BucketConfiguration>(`/api/v1/buckets/${encodeURIComponent(name)}/configuration`, {
      method: 'PATCH',
      body: JSON.stringify(update),
    }),
    listObjectVersions: async (bucket: string, prefix = '') => {
      const query = new URLSearchParams()
      if (prefix) query.set('prefix', prefix)
      const suffix = query.size ? `?${query.toString()}` : ''
      return (await request<{ items: ObjectVersion[] }>(
        `/api/v1/buckets/${encodeURIComponent(bucket)}/versions${suffix}`,
      )).items
    },
    listObjects: (bucket: string, prefix = '', continuationToken = '', search = '', maxKeys = 10, delimiter = '') => {
      const query = new URLSearchParams()
      if (prefix) query.set('prefix', prefix)
      if (search) query.set('search', search)
      query.set('max_keys', String(maxKeys))
      if (continuationToken) query.set('continuation_token', continuationToken)
      if (delimiter) query.set('delimiter', delimiter)
      const suffix = query.size ? `?${query.toString()}` : ''
      return request<ListObjectsResponse>(
        `/api/v1/buckets/${encodeURIComponent(bucket)}/objects${suffix}`,
      )
    },
    createDirectory: (bucket: string, key: string) =>
      request<{ type: 'directory'; key: string; last_modified: string }>(`/api/v1/buckets/${encodeURIComponent(bucket)}/directories`, {
        method: 'POST',
        body: JSON.stringify({ key }),
      }),
    deleteDirectory: (bucket: string, key: string, allVersions = false) =>
      request<void>(`/api/v1/buckets/${encodeURIComponent(bucket)}/directories?key=${encodeURIComponent(key)}&all_versions=${allVersions}`, {
        method: 'DELETE',
      }),
    forceCleanupDirectory: (bucket: string, key: string) =>
      request<void>(`/api/v1/buckets/${encodeURIComponent(bucket)}/directories/cleanup`, {
        method: 'POST',
        body: JSON.stringify({ key }),
      }),
    presignObject: (
      accessKey: string,
      bucket: string,
      key: string,
      method: 'GET' | 'PUT' | 'DELETE',
      expiresSeconds: number,
      options?: {
        uploadId?: string
        partNumber?: number
        versionId?: string
        tagging?: boolean
        download?: boolean
        copySource?: { bucket: string; key: string; versionId?: string }
      },
    ) => request<PresignObjectResponse>('/api/v1/objects/presign', {
      method: 'POST',
      body: JSON.stringify({
        access_key: accessKey,
        bucket,
        key,
        method,
        expires_seconds: expiresSeconds,
        ...(options?.uploadId && options.partNumber ? { upload_id: options.uploadId, part_number: options.partNumber } : {}),
        ...(options?.versionId ? { version_id: options.versionId } : {}),
        ...(options?.tagging ? { tagging: true } : {}),
        ...(options?.download ? { download: true } : {}),
        ...(options?.copySource ? {
          copy_source_bucket: options.copySource.bucket,
          copy_source_key: options.copySource.key,
          ...(options.copySource.versionId ? { copy_source_version_id: options.copySource.versionId } : {}),
        } : {}),
      }),
    }),
    createMultipartUpload: (bucket: string, key: string, contentType: string) =>
      request<MultipartUpload>('/api/v1/multipart-uploads', {
        method: 'POST',
        body: JSON.stringify({ bucket, key, content_type: contentType }),
      }),
    listMultipartUploads: (bucket: string, prefix = '', keyMarker = '', uploadIDMarker = '') => {
      const query = new URLSearchParams()
      if (prefix) query.set('prefix', prefix)
      if (keyMarker) query.set('key_marker', keyMarker)
      if (uploadIDMarker) query.set('upload_id_marker', uploadIDMarker)
      const suffix = query.size ? `?${query.toString()}` : ''
      return request<ListMultipartUploadsResponse>(
        `/api/v1/buckets/${encodeURIComponent(bucket)}/multipart-uploads${suffix}`,
      )
    },
    getMultipartUpload: (uploadId: string, bucket: string, key: string) => {
      const query = new URLSearchParams({ bucket, key })
      return request<MultipartUpload>(
        `/api/v1/multipart-uploads/${encodeURIComponent(uploadId)}?${query.toString()}`,
      )
    },
    completeMultipartUpload: (
      uploadId: string,
      bucket: string,
      key: string,
      parts: Array<{ part_number: number; etag: string }>,
    ) => request<ObjectSummary>(`/api/v1/multipart-uploads/${encodeURIComponent(uploadId)}/complete`, {
      method: 'POST',
      body: JSON.stringify({ bucket, key, parts }),
    }, MULTIPART_COMPLETE_TIMEOUT_MS),
    abortMultipartUpload: (uploadId: string, bucket: string, key: string) => {
      const query = new URLSearchParams({ bucket, key })
      return request<void>(
        `/api/v1/multipart-uploads/${encodeURIComponent(uploadId)}?${query.toString()}`,
        { method: 'DELETE' },
      )
    },
    listUserAccessKeys: async (name: string) =>
      (await request<{ items: AccessKey[] }>(`/api/v1/users/${encodeURIComponent(name)}/access-keys`)).items,
    createUserAccessKey: (name: string, value: AccessKeyCreate) =>
      request<CreatedAccessKey>(`/api/v1/users/${encodeURIComponent(name)}/access-keys`, {
        method: 'POST', body: JSON.stringify(value),
      }),
    updateUserAccessKey: (name: string, id: string, value: AccessKeyUpdate) =>
      request<AccessKey>(`/api/v1/users/${encodeURIComponent(name)}/access-keys/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    updateAccessKey: (id: string, value: AccessKeyUpdate) =>
      request<AccessKey>(`/api/v1/access-keys/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(value) }),
    setUserAccessKeyEnabled: (name: string, id: string, enabled: boolean) =>
      request<AccessKey>(`/api/v1/users/${encodeURIComponent(name)}/access-keys/${encodeURIComponent(id)}`, {
        method: 'PATCH', body: JSON.stringify({ enabled }),
      }),
    deleteUserAccessKey: (name: string, id: string) =>
      request<void>(`/api/v1/users/${encodeURIComponent(name)}/access-keys/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    listAccessKeys: async () =>
      (await request<{ items: AccessKey[] }>('/api/v1/access-keys')).items,
    createAccessKey: (value: AccessKeyCreate) =>
      request<CreatedAccessKey>('/api/v1/access-keys', {
        method: 'POST',
        body: JSON.stringify(value),
      }),
    setAccessKeyEnabled: (id: string, enabled: boolean) =>
      request<AccessKey>(`/api/v1/access-keys/${encodeURIComponent(id)}`, {
        method: 'PATCH',
        body: JSON.stringify({ enabled }),
      }),
    deleteAccessKey: (id: string) =>
      request<void>(`/api/v1/access-keys/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  }
}

export type ApiClient = ReturnType<typeof createApiClient>
