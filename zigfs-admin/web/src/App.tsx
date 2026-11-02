import { useEffect, useMemo, useState } from 'react'
import {
  Activity,
  ChevronDown,
  FolderOpen,
  Fingerprint,
  HardDrive,
  KeyRound,
  LayoutDashboard,
  LogOut,
  Menu,
  Moon,
  PanelLeftClose,
  PanelLeftOpen,
  ShieldCheck,
  Settings,
  Sun,
  ContactRound,
  UsersRound,
  X,
  type LucideIcon,
} from 'lucide-react'
import { ApiError, createApiClient } from './api/client'
import { useErrorToast } from './components/ToastProvider'
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuGroup, DropdownMenuItem } from './components/ui/dropdown-menu'
import { Button } from './components/ui/Button'
import { useLoading } from './components/LoadingProvider'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
import { IdentitiesView } from './features/identities/IdentitiesView'
import { OIDCSettingsView } from './features/settings/OIDCSettingsView'
import { PoliciesView } from './features/policies/PoliciesView'
import { LoginView } from './features/auth/LoginView'
import { BucketDetailView } from './features/buckets/BucketDetailView'
import { BucketsView } from './features/buckets/BucketsView'
import { DashboardView } from './features/dashboard/DashboardView'
import { ObjectsView } from './features/objects/ObjectsView'
import { SettingsView } from './features/settings/SettingsView'
import { StorageView } from './features/storage/StorageView'
import { SystemView } from './features/system/SystemView'
import { appRoutePath, createAppRoute, parseAppRoute, type AppRoute, type View } from './routes'
import type { AdminSession } from './types/api'

type Availability = 'checking' | 'ready' | 'offline' | 'not-ready'

const THEME_STORAGE_KEY = 'zigfs-admin-theme'

function readDarkTheme(): boolean {
  try {
    return window.localStorage.getItem(THEME_STORAGE_KEY) === 'dark'
  } catch {
    return false
  }
}

interface NavItem {
  view: View
  label: string
  icon: LucideIcon
}

const navigation: Array<{ label: string; items: NavItem[] }> = [
  { label: '工作台', items: [{ view: 'dashboard', label: 'Overview', icon: LayoutDashboard }] },
  { label: '对象存储', items: [{ view: 'buckets', label: 'Buckets', icon: FolderOpen }] },
  { label: '访问控制', items: [
    { view: 'users', label: 'Users', icon: ContactRound },
    { view: 'user-groups', label: 'User Groups', icon: UsersRound },
    { view: 'access-keys', label: 'Access Keys', icon: KeyRound },
    { view: 'policies', label: 'Policies', icon: ShieldCheck },
  ] },
  {
    label: '服务状态',
    items: [
      { view: 'storage', label: 'Storage', icon: HardDrive },
      { view: 'system', label: 'Monitoring', icon: Activity },
    ],
  },
  { label: '配置', items: [
    { view: 'oidc-settings', label: 'OpenID', icon: Fingerprint },
    // Keep System Setting as the final item in the navigation list.
    { view: 'settings', label: 'System Setting', icon: Settings },
  ] },
]

const viewMeta: Record<View, { section: string; label: string }> = {
  dashboard: { section: 'System', label: 'Overview' },
  buckets: { section: 'Buckets', label: 'All Buckets' },
  'bucket-detail': { section: 'Buckets', label: 'Summary' },
  objects: { section: 'Buckets', label: 'Objects' },
  users: { section: 'Access Control', label: 'Users' },
  'user-groups': { section: 'Access Control', label: 'User Groups' },
  'access-keys': { section: 'Access Control', label: 'Access Keys' },
  policies: { section: 'Access Control', label: 'Policies' },
  storage: { section: 'System', label: 'Storage' },
  system: { section: 'Monitoring', label: 'Running Status' },
  settings: { section: 'Configuration', label: 'System Setting' },
  'oidc-settings': { section: 'Configuration', label: 'OpenID' },
}

export default function App() {
  const { withLoading } = useLoading()
  const notifyError = useErrorToast()
  const [session, setSession] = useState<AdminSession | null>()
  const [route, setRoute] = useState<AppRoute>(() => parseAppRoute(window.location.pathname, window.location.search))
  const [availability, setAvailability] = useState<Availability>('checking')
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false)
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false)
  const [darkTheme, setDarkTheme] = useState(readDarkTheme)
  const api = useMemo(() => createApiClient(), [])

  useEffect(() => {
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, darkTheme ? 'dark' : 'light')
    } catch {
      // Storage may be unavailable in private or restricted browser contexts.
    }
    document.documentElement.dataset.theme = darkTheme ? 'dark' : 'light'
  }, [darkTheme])

  async function bootstrap() {
    await withLoading('正在连接 ZigFS...', async () => {
      setAvailability('checking')
      try {
        await api.ready()
        setAvailability('ready')
        try {
          setSession(await api.session())
        } catch (reason) {
          if (reason instanceof ApiError && reason.status === 401) {
            try { setSession(await api.refreshOIDC()) } catch { setSession(null) }
          }
          else throw reason
        }
      } catch (reason) {
        setSession(undefined)
        setAvailability(reason instanceof ApiError && reason.body.code === 'StorageNotReady' ? 'not-ready' : 'offline')
      }
    })
  }

  useEffect(() => {
    void bootstrap()
  }, [api])

  useEffect(() => {
    let renewing = false
    let active = true
    const expire = async () => {
      if (!session?.federated) { setSession(null); return }
      if (renewing) return
      renewing = true
      try {
        const next = await api.refreshOIDC()
        if (active) setSession(next)
      } catch { if (active) setSession(null) }
      finally { renewing = false }
    }
    window.addEventListener('zigfs:session-expired', expire)
    return () => { active = false; window.removeEventListener('zigfs:session-expired', expire) }
  }, [api, session?.federated])

  useEffect(() => {
    const invalidate = () => {
      // Feature views own their server state; this event tells them to drop
      // cached capability/permission data after any mutating API call.
      window.dispatchEvent(new CustomEvent('zigfs:capabilities-invalidated'))
    }
    window.addEventListener('zigfs:permissions-changed', invalidate)
    return () => window.removeEventListener('zigfs:permissions-changed', invalidate)
  }, [])

  useEffect(() => {
    const syncRoute = () => setRoute(parseAppRoute(window.location.pathname, window.location.search))
    window.addEventListener('popstate', syncRoute)
    return () => window.removeEventListener('popstate', syncRoute)
  }, [])

  useEffect(() => {
    if (!session?.federated || !session.refreshable) return
    let active = true
    let pending = false
    const renew = async () => {
      if (pending) return
      pending = true
      try {
        const next = await api.refreshOIDC()
        if (active) setSession(next)
      } catch (error) {
        if (active) {
          notifyError(error instanceof Error ? error.message : '操作失败，请重试')
          if (error instanceof ApiError && error.status === 401) setSession(null)
        }
      } finally { pending = false }
    }
    const timer = window.setInterval(() => void renew(), 30_000)
    const onFocus = () => void renew()
    window.addEventListener('focus', onFocus)
    return () => { active = false; window.clearInterval(timer); window.removeEventListener('focus', onFocus) }
  }, [api, session?.federated, session?.refreshable, notifyError])

  if (availability === 'offline' || availability === 'not-ready') {
    return <ServiceUnavailable state={availability} retry={() => void bootstrap()} />
  }

  if (session === undefined) {
    return <main className="session-loading" aria-label="正在验证登录状态"><img className="session-logo" src="/zigfs-logo.svg" alt="ZigFS" /></main>
  }

  if (!session) {
    return <LoginView onLogin={async (username, password) => {
      setSession(await api.login(username, password))
    }} />
  }

  async function logout() {
    await withLoading('正在退出登录...', async () => {
      try {
        if (session?.federated) {
          const result = await api.endOIDCSession()
          setSession(null)
          if (result.logout_url) window.location.assign(result.logout_url)
        } else { await api.logout(); setSession(null) }
      } catch (error) { notifyError(error instanceof Error ? error.message : '操作失败，请重试') }
    })
  }

  function navigate(nextView: View, bucket = '', prefix = '') {
    const nextRoute = createAppRoute(nextView, bucket, prefix)
    const path = appRoutePath(nextRoute)
    const currentPath = `${window.location.pathname}${window.location.search}`
    if (currentPath !== path) window.history.pushState(null, '', path)
    setRoute(nextRoute)
    setMobileSidebarOpen(false)
  }

  const { view, bucket: selectedBucket, prefix: selectedPrefix } = route
  const meta = viewMeta[view]
  const isBucketsActive = view === 'buckets' || view === 'bucket-detail' || view === 'objects'
  const visibleNavigation = session.is_root ? navigation : navigation.filter(group => group.label !== '服务状态' && group.label !== '配置')
  const restrictedView = !session.is_root && (view === 'storage' || view === 'system' || view === 'settings' || view === 'oidc-settings')

  return (
    <div className={`app-shell${sidebarCollapsed ? ' sidebar-collapsed' : ''}${mobileSidebarOpen ? ' sidebar-open' : ''}${darkTheme ? ' theme-dark' : ''}`}>
      <button className="sidebar-backdrop" type="button" aria-label="关闭导航" onClick={() => setMobileSidebarOpen(false)} />
      <aside className="sidebar">
        <div className="sidebar-brand">
          <img className="brand-logo" src="/zigfs-logo.svg" alt="" aria-hidden="true" />
          <div className="brand-copy"><strong>ZigFS</strong><span>Object Storage</span></div>
          <button className="mobile-close" type="button" aria-label="关闭导航" onClick={() => setMobileSidebarOpen(false)}><X aria-hidden="true" /></button>
        </div>
        <nav aria-label="Primary navigation">
          {visibleNavigation.map((group) => (
            <div className="nav-group" key={group.label}>
              <span className="nav-section-label">{group.label}</span>
              {group.items.map((item) => {
                const active = item.view === 'buckets' ? isBucketsActive : view === item.view
                const Icon = item.icon
                return (
                  <button
                    className={`nav-item${active ? ' active' : ''}`}
                    key={item.view}
                    type="button"
                    title={sidebarCollapsed ? item.label : undefined}
                    onClick={() => navigate(item.view)}
                  >
                    <Icon className="nav-icon" aria-hidden="true" strokeWidth={1.8} />
                    <span className="nav-label">{item.label}</span>
                  </button>
                )
              })}
            </div>
          ))}
        </nav>
        <div className="sidebar-footer">
          <div className="sidebar-version"><span className="status-dot" /> <span>ZigFS v0.1.0</span></div>
          <button className="logout-button" type="button" onClick={() => void logout()}>
            <LogOut className="nav-icon" aria-hidden="true" strokeWidth={1.8} /><span className="nav-label">退出登录</span>
          </button>
        </div>
      </aside>

      <div className="workspace">
        <header className="app-topbar">
          <div className="topbar-leading">
            <button className="topbar-icon desktop-sidebar-toggle" type="button" aria-label={sidebarCollapsed ? '展开导航' : '收起导航'} onClick={() => setSidebarCollapsed((current) => !current)}>
              {sidebarCollapsed ? <PanelLeftOpen aria-hidden="true" /> : <PanelLeftClose aria-hidden="true" />}
            </button>
            <button className="topbar-icon mobile-sidebar-toggle" type="button" aria-label="打开导航" onClick={() => setMobileSidebarOpen(true)}><Menu aria-hidden="true" /></button>
            <div className="breadcrumbs" aria-label="Breadcrumb">
              {view === 'objects' && selectedBucket ? <><span>Buckets</span><b>/</b><strong>{selectedBucket}</strong></> : <>
                <span>{meta.section}</span><b>/</b>
                {(view === 'bucket-detail' || view === 'objects') && selectedBucket ? <><span>{selectedBucket}</span><b>/</b></> : null}
                <strong>{meta.label}</strong>
              </>}
            </div>
          </div>
          <div className="topbar-actions">
            <span className="connection-state"><span className="status-dot" /> FS Ready</span>
            <button className="topbar-icon" type="button" title={darkTheme ? '切换浅色主题' : '切换深色主题'} aria-label={darkTheme ? '切换浅色主题' : '切换深色主题'} onClick={() => setDarkTheme((current) => !current)}>
              {darkTheme ? <Sun aria-hidden="true" /> : <Moon aria-hidden="true" />}
            </button>
            <DropdownMenu>
              <DropdownMenuTrigger asChild><Button variant="ghost" aria-label="用户菜单">{session.display_name || session.username}<ChevronDown data-icon="inline-end" /></Button></DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuLabel><div>{session.display_name || session.username}</div>{session.email && <div>{session.email}</div>}</DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuGroup><DropdownMenuItem onSelect={() => void logout()}>退出登录</DropdownMenuItem></DropdownMenuGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>

        <main className={`content${view === 'bucket-detail' ? ' content-bucket-detail' : view === 'oidc-settings' ? ' content-oidc' : ''}`}>
          {view === 'dashboard' && <DashboardView api={api} />}
          {view === 'buckets' && <BucketsView api={api} onOpenBucket={(name) => {
            navigate('bucket-detail', name)
          }} />}
          {view === 'bucket-detail' && <BucketDetailView
            api={api}
            bucketName={selectedBucket}
            onBack={() => navigate('buckets')}
            onOpenObjects={() => navigate('objects', selectedBucket)}
            onDeleted={() => navigate('buckets')}
          />}
          {view === 'objects' && <ObjectsView api={api} initialBucket={selectedBucket} initialPrefix={selectedPrefix} onNavigatePath={(prefix) => navigate('objects', selectedBucket, prefix)} onBack={() => navigate('bucket-detail', selectedBucket)} />}
          {view === 'access-keys' && <AccessKeysView api={api} />}
          {view === 'users' && <IdentitiesView key="users" kind="users" api={api} />}
          {view === 'user-groups' && <IdentitiesView key="groups" kind="groups" api={api} />}
          {view === 'policies' && <PoliciesView api={api} />}
          {!restrictedView && view === 'oidc-settings' && <OIDCSettingsView api={api} />}
          {restrictedView && <AccessDeniedView />}
          {!restrictedView && view === 'storage' && <StorageView api={api} />}
          {!restrictedView && view === 'system' && <SystemView api={api} />}
          {!restrictedView && view === 'settings' && <SettingsView api={api} />}
        </main>
      </div>
    </div>
  )
}

function AccessDeniedView() {
  return <section className="service-state" aria-live="polite"><h1>无权访问</h1><p>当前身份没有该管理页面所需的权限。</p></section>
}

function ServiceUnavailable({ state, retry }: { state: 'offline' | 'not-ready'; retry: () => void }) {
  return (
    <main className="service-state">
      <img className="service-logo" src="/zigfs-logo.svg" alt="ZigFS" />
      <span className={`service-state-dot ${state}`} />
      <h1>{state === 'offline' ? 'ZigFS Offline' : 'ZigFS Not Ready'}</h1>
      <p>{state === 'offline' ? '无法连接 ZigFS。' : 'ZigFS 正在恢复存储与元数据。'}</p>
      <button className="primary-button" type="button" onClick={retry}>重试</button>
    </main>
  )
}
