import type {
  AccessKey,
  AdminSession,
  ApiErrorBody,
  Bucket,
  CreatedAccessKey,
  CredentialPolicy,
  ListObjectsResponse,
  ListMultipartUploadsResponse,
  MultipartUpload,
  ObjectSummary,
  ManagementHealth,
  PresignObjectResponse,
  Settings,
  StorageInfo,
  SystemInfo,
} from '../types/api'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: ApiErrorBody,
  ) {
    super(body.message)
  }
}

export function createApiClient() {
  async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body) headers.set('Content-Type', 'application/json')

    const response = await fetch(path, {
      ...init,
      headers,
      credentials: 'same-origin',
    })

    if (!response.ok) {
      const fallback: ApiErrorBody = {
        code: 'RequestFailed',
        message: `Request failed with status ${response.status}`,
        request_id: response.headers.get('X-Request-ID') ?? '',
        details: {},
      }
      const body = (await response.json().catch(() => fallback)) as ApiErrorBody
      throw new ApiError(response.status, body)
    }
    if (response.status === 204) return undefined as T
    return (await response.json()) as T
  }

  return {
    ready: () => request<{ status: 'ready' }>('/health/ready'),
    login: (username: string, password: string) =>
      request<AdminSession>('/api/v1/auth/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      }),
    session: () => request<AdminSession>('/api/v1/auth/session'),
    logout: () => request<void>('/api/v1/auth/logout', { method: 'POST' }),
    system: () => request<SystemInfo>('/api/v1/system'),
    storage: () => request<StorageInfo>('/api/v1/storage'),
    managementHealth: () => request<ManagementHealth>('/api/v1/management-health'),
    settings: () => request<Settings>('/api/v1/settings'),
    listBuckets: async () => (await request<{ items: Bucket[] }>('/api/v1/buckets')).items,
    createBucket: (name: string, owner: string) =>
      request<Bucket>('/api/v1/buckets', {
        method: 'POST',
        body: JSON.stringify({ name, owner }),
      }),
    deleteBucket: (name: string) =>
      request<void>(`/api/v1/buckets/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    listObjects: (bucket: string, prefix = '', continuationToken = '') => {
      const query = new URLSearchParams()
      if (prefix) query.set('prefix', prefix)
      if (continuationToken) query.set('continuation_token', continuationToken)
      const suffix = query.size ? `?${query.toString()}` : ''
      return request<ListObjectsResponse>(
        `/api/v1/buckets/${encodeURIComponent(bucket)}/objects${suffix}`,
      )
    },
    presignObject: (
      accessKey: string,
      bucket: string,
      key: string,
      method: 'GET' | 'PUT' | 'DELETE',
      expiresSeconds: number,
      multipart?: { uploadId: string; partNumber: number },
    ) => request<PresignObjectResponse>('/api/v1/objects/presign', {
      method: 'POST',
      body: JSON.stringify({
        access_key: accessKey,
        bucket,
        key,
        method,
        expires_seconds: expiresSeconds,
        ...(multipart ? { upload_id: multipart.uploadId, part_number: multipart.partNumber } : {}),
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
    }),
    abortMultipartUpload: (uploadId: string, bucket: string, key: string) => {
      const query = new URLSearchParams({ bucket, key })
      return request<void>(
        `/api/v1/multipart-uploads/${encodeURIComponent(uploadId)}?${query.toString()}`,
        { method: 'DELETE' },
      )
    },
    listAccessKeys: async () =>
      (await request<{ items: AccessKey[] }>('/api/v1/access-keys')).items,
    createAccessKey: (owner: string, policy: CredentialPolicy, ttlSeconds?: number) =>
      request<CreatedAccessKey>('/api/v1/access-keys', {
        method: 'POST',
        body: JSON.stringify({ owner, policy, ...(ttlSeconds ? { ttl_seconds: ttlSeconds } : {}) }),
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
