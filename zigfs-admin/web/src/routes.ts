export type View = 'dashboard' | 'buckets' | 'bucket-detail' | 'objects' | 'access-keys' | 'storage' | 'system' | 'settings'

export interface AppRoute {
  view: View
  bucket: string
}

const staticRoutes: Record<string, View> = {
  'access-keys': 'access-keys',
  storage: 'storage',
  system: 'system',
  settings: 'settings',
}

export function parseAppRoute(pathname: string): AppRoute {
  const segments = pathname.split('/').filter(Boolean)
  if (segments.length === 0) return { view: 'dashboard', bucket: '' }

  if (segments[0] === 'buckets') {
    if (segments.length === 1) return { view: 'buckets', bucket: '' }

    const bucket = decodePathSegment(segments[1])
    if (!bucket) return { view: 'buckets', bucket: '' }
    if (segments.length === 2) return { view: 'bucket-detail', bucket }
    if (segments.length === 3 && segments[2] === 'objects') return { view: 'objects', bucket }
    return { view: 'buckets', bucket: '' }
  }

  const view = segments.length === 1 ? staticRoutes[segments[0]] : undefined
  return { view: view ?? 'dashboard', bucket: '' }
}

export function createAppRoute(view: View, bucket = ''): AppRoute {
  if (view === 'bucket-detail' || view === 'objects') {
    return bucket ? { view, bucket } : { view: 'buckets', bucket: '' }
  }
  return { view, bucket: '' }
}

export function appRoutePath(route: AppRoute): string {
  switch (route.view) {
    case 'dashboard': return '/'
    case 'buckets': return '/buckets'
    case 'bucket-detail': return route.bucket ? `/buckets/${encodeURIComponent(route.bucket)}` : '/buckets'
    case 'objects': return route.bucket ? `/buckets/${encodeURIComponent(route.bucket)}/objects` : '/buckets'
    case 'access-keys': return '/access-keys'
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
