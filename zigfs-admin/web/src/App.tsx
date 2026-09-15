import { useEffect, useMemo, useState } from 'react'
import {
  Activity,
  ChevronDown,
  FolderOpen,
  HardDrive,
  KeyRound,
  LayoutDashboard,
  LogOut,
  Menu,
  Moon,
  PanelLeftClose,
  PanelLeftOpen,
  Settings,
  Sun,
  X,
  type LucideIcon,
} from 'lucide-react'
import { ApiError, createApiClient } from './api/client'
import { useLoading } from './components/LoadingProvider'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
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
  { label: '访问控制', items: [{ view: 'access-keys', label: 'Access Keys', icon: KeyRound }] },
  {
    label: '服务状态',
    items: [
      { view: 'storage', label: 'Storage', icon: HardDrive },
      { view: 'system', label: 'System', icon: Activity },
    ],
  },
  { label: '配置', items: [{ view: 'settings', label: 'Settings', icon: Settings }] },
]

const viewMeta: Record<View, { section: string; label: string }> = {
  dashboard: { section: 'System', label: 'Overview' },
  buckets: { section: 'Buckets', label: 'All Buckets' },
  'bucket-detail': { section: 'Buckets', label: 'Summary' },
  objects: { section: 'Buckets', label: 'Objects' },
  'access-keys': { section: 'Access Control', label: 'Access Keys' },
  storage: { section: 'System', label: 'Storage' },
  system: { section: 'System', label: 'Runtime' },
  settings: { section: 'Configuration', label: 'Settings' },
}

export default function App() {
  const { withLoading } = useLoading()
  const [session, setSession] = useState<AdminSession | null>()
  const [route, setRoute] = useState<AppRoute>(() => parseAppRoute(window.location.pathname))
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
          if (reason instanceof ApiError && reason.status === 401) setSession(null)
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
    const syncRoute = () => setRoute(parseAppRoute(window.location.pathname))
    window.addEventListener('popstate', syncRoute)
    return () => window.removeEventListener('popstate', syncRoute)
  }, [])

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
        await api.logout()
      } finally {
        setSession(null)
      }
    })
  }

  function navigate(nextView: View, bucket = '') {
    const nextRoute = createAppRoute(nextView, bucket)
    const path = appRoutePath(nextRoute)
    if (window.location.pathname !== path) window.history.pushState(null, '', path)
    setRoute(nextRoute)
    setMobileSidebarOpen(false)
  }

  const { view, bucket: selectedBucket } = route
  const meta = viewMeta[view]
  const isBucketsActive = view === 'buckets' || view === 'bucket-detail' || view === 'objects'

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
          {navigation.map((group) => (
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
              <span>{meta.section}</span><b>/</b>
              {(view === 'bucket-detail' || view === 'objects') && selectedBucket ? <><span>{selectedBucket}</span><b>/</b></> : null}
              <strong>{meta.label}</strong>
            </div>
          </div>
          <div className="topbar-actions">
            <span className="connection-state"><span className="status-dot" /> FS Ready</span>
            <button className="topbar-icon" type="button" title={darkTheme ? '切换浅色主题' : '切换深色主题'} aria-label={darkTheme ? '切换浅色主题' : '切换深色主题'} onClick={() => setDarkTheme((current) => !current)}>
              {darkTheme ? <Sun aria-hidden="true" /> : <Moon aria-hidden="true" />}
            </button>
            <details className="user-menu">
              <summary aria-label="用户菜单"><span className="user-avatar">{session.username.slice(0, 1).toUpperCase()}</span><span className="user-name">{session.username}</span><ChevronDown className="user-menu-chevron" aria-hidden="true" /></summary>
              <div className="user-menu-popover">
                <span>当前管理员</span>
                <strong>{session.username}</strong>
                <button type="button" onClick={() => void logout()}>退出登录</button>
              </div>
            </details>
          </div>
        </header>

        <main className="content">
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
          {view === 'objects' && <ObjectsView api={api} initialBucket={selectedBucket} onBack={() => navigate('bucket-detail', selectedBucket)} />}
          {view === 'access-keys' && <AccessKeysView api={api} />}
          {view === 'storage' && <StorageView api={api} />}
          {view === 'system' && <SystemView api={api} />}
          {view === 'settings' && <SettingsView api={api} />}
        </main>
      </div>
    </div>
  )
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
