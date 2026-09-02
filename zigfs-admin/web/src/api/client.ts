import type {
  AccessKey,
  ApiErrorBody,
  Bucket,
  CreatedAccessKey,
  ObjectSummary,
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

export function createApiClient(token: string) {
  async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    headers.set('Authorization', `Bearer ${token}`)
    if (init.body) headers.set('Content-Type', 'application/json')

    const response = await fetch(path, {
      ...init,
      headers,
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
    system: () => request<SystemInfo>('/api/v1/system'),
    listBuckets: async () => (await request<{ items: Bucket[] }>('/api/v1/buckets')).items,
    createBucket: (name: string) =>
      request<Bucket>('/api/v1/buckets', {
        method: 'POST',
        body: JSON.stringify({ name }),
      }),
    deleteBucket: (name: string) =>
      request<void>(`/api/v1/buckets/${encodeURIComponent(name)}`, { method: 'DELETE' }),
    listObjects: async (bucket: string) =>
      (
        await request<{ items: ObjectSummary[] }>(
          `/api/v1/buckets/${encodeURIComponent(bucket)}/objects`,
        )
      ).items,
    listAccessKeys: async () =>
      (await request<{ items: AccessKey[] }>('/api/v1/access-keys')).items,
    createAccessKey: (name: string) =>
      request<CreatedAccessKey>('/api/v1/access-keys', {
        method: 'POST',
        body: JSON.stringify({ name }),
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
