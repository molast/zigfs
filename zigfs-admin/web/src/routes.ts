export type View = 'dashboard' | 'buckets' | 'bucket-detail' | 'objects' | 'users' | 'user-groups' | 'access-keys' | 'policies' | 'storage' | 'system' | 'settings' | 'oidc-settings'

export interface AppRoute {
  view: View
  bucket: string
  prefix: string
}

const staticRoutes: Record<string, View> = {
  users: 'users',
  'user-groups': 'user-groups',
  'access-keys': 'access-keys',
  policies: 'policies',
  'oidc-settings': 'oidc-settings',
  storage: 'storage',
  system: 'system',
  settings: 'settings',
}

export function parseAppRoute(pathname: string, search = ''): AppRoute {
  const segments = pathname.split('/').filter(Boolean)
  const hasTrailingSlash = pathname.length > 1 && pathname.endsWith('/')
  const query = new URLSearchParams(search)
  if (segments.length === 0) return { view: 'dashboard', bucket: '', prefix: '' }

  if (segments[0] === 'buckets') {
    if (segments.length === 1) return { view: 'buckets', bucket: '', prefix: '' }

    const bucket = decodePathSegment(segments[1])
    if (!bucket) return { view: 'buckets', bucket: '', prefix: '' }
    // The bucket path is also its object root. Bucket configuration lives at
    // a separate sub-route so filesystem-style object paths remain natural.
    if (segments.length === 2 && query.get('view') === 'configuration') {
      return { view: 'bucket-detail', bucket, prefix: '' }
    }
    if (segments.length === 2) return { view: 'objects', bucket, prefix: '' }

    const objectSegments = segments.slice(2).map(decodePathSegment)
    const prefix = `${objectSegments.join('/')}${hasTrailingSlash ? '/' : ''}`
    return { view: 'objects', bucket, prefix }
  }

  const view = segments.length === 1 ? staticRoutes[segments[0]] : undefined
  return { view: view ?? 'dashboard', bucket: '', prefix: '' }
}

export function createAppRoute(view: View, bucket = '', prefix = ''): AppRoute {
  if (view === 'bucket-detail' || view === 'objects') {
    return bucket ? { view, bucket, prefix: view === 'objects' ? prefix : '' } : { view: 'buckets', bucket: '', prefix: '' }
  }
  return { view, bucket: '', prefix: '' }
}

export function appRoutePath(route: AppRoute): string {
  switch (route.view) {
    case 'dashboard': return '/'
    case 'buckets': return '/buckets'
    case 'bucket-detail': return route.bucket ? `/buckets/${encodeURIComponent(route.bucket)}?view=configuration` : '/buckets'
    case 'objects': {
      if (!route.bucket) return '/buckets'
      const normalizedPrefix = route.prefix.trim().replace(/^\/+/, '')
      const bucketPath = `/buckets/${encodeURIComponent(route.bucket)}`
      if (!normalizedPrefix) return bucketPath
      const prefixPath = normalizedPrefix.split('/').filter(Boolean).map(encodeURIComponent).join('/')
      return `${bucketPath}/${prefixPath}${normalizedPrefix.endsWith('/') ? '/' : ''}`
    }
    case 'users': return '/users'
    case 'user-groups': return '/user-groups'
    case 'access-keys': return '/access-keys'
    case 'policies': return '/policies'
    case 'oidc-settings': return '/oidc-settings'
    case 'storage': return '/storage'
    case 'system': return '/system'
    case 'settings': return '/settings'
  }
}

function decodePathSegment(segment: string): string {
  try {
    return decodeURIComponent(segment)
  } catch {
    return ''
  }
}
