import { useEffect, useMemo, useState } from 'react'
import { ApiError, createApiClient } from './api/client'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
import { LoginView } from './features/auth/LoginView'
import { BucketsView } from './features/buckets/BucketsView'
import { DashboardView } from './features/dashboard/DashboardView'
import { ObjectsView } from './features/objects/ObjectsView'
import { SettingsView } from './features/settings/SettingsView'
import { StorageView } from './features/storage/StorageView'
import { SystemView } from './features/system/SystemView'
import type { AdminSession } from './types/api'

type View = 'dashboard' | 'buckets' | 'objects' | 'access-keys' | 'storage' | 'system' | 'settings'
type Availability = 'checking' | 'ready' | 'offline' | 'not-ready'

export default function App() {
  const [session, setSession] = useState<AdminSession | null>()
  const [view, setView] = useState<View>('dashboard')
  const [selectedBucket, setSelectedBucket] = useState('')
  const [availability, setAvailability] = useState<Availability>('checking')
  const api = useMemo(() => createApiClient(), [])

  async function bootstrap() {
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
  }

  useEffect(() => {
    void bootstrap()
  }, [api])

  if (availability === 'offline' || availability === 'not-ready') {
    return <ServiceUnavailable state={availability} retry={() => void bootstrap()} />
  }

  if (session === undefined) {
    return <main className="session-loading" aria-label="正在验证登录状态" />
  }

  if (!session) {
    return <LoginView onLogin={async (username, password) => {
      setSession(await api.login(username, password))
    }} />
  }

  async function logout() {
    try {
      await api.logout()
    } finally {
      setSession(null)
    }
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark">ZF</span><strong>ZigFS</strong></div>
        <nav aria-label="Primary navigation">
          <button className={view === 'dashboard' ? 'active' : ''} onClick={() => setView('dashboard')}>Overview</button>
          <button className={view === 'buckets' ? 'active' : ''} onClick={() => setView('buckets')}>Buckets</button>
          <button className={view === 'objects' ? 'active' : ''} onClick={() => setView('objects')}>Objects</button>
          <button className={view === 'access-keys' ? 'active' : ''} onClick={() => setView('access-keys')}>Access Keys</button>
          <button className={view === 'storage' ? 'active' : ''} onClick={() => setView('storage')}>Storage</button>
          <button className={view === 'system' ? 'active' : ''} onClick={() => setView('system')}>System</button>
          <button className={view === 'settings' ? 'active' : ''} onClick={() => setView('settings')}>Settings</button>
        </nav>
        <button className="logout-button" onClick={() => void logout()}>退出</button>
      </aside>
      <main className="content">
        {view === 'dashboard' && <DashboardView api={api} />}
        {view === 'buckets' && <BucketsView api={api} onOpenBucket={(name) => {
          setSelectedBucket(name)
          setView('objects')
        }} />}
        {view === 'objects' && <ObjectsView api={api} initialBucket={selectedBucket} onBack={() => setView('buckets')} />}
        {view === 'access-keys' && <AccessKeysView api={api} />}
        {view === 'storage' && <StorageView api={api} />}
        {view === 'system' && <SystemView api={api} />}
        {view === 'settings' && <SettingsView api={api} />}
      </main>
    </div>
  )
}

function ServiceUnavailable({ state, retry }: { state: 'offline' | 'not-ready'; retry: () => void }) {
  return (
    <main className="service-state">
      <span className={`service-state-dot ${state}`} />
      <h1>{state === 'offline' ? 'ZigFS Offline' : 'ZigFS Not Ready'}</h1>
      <p>{state === 'offline' ? '无法连接 ZigFS。' : 'ZigFS 正在恢复存储与元数据。'}</p>
      <button className="primary-button" type="button" onClick={retry}>重试</button>
    </main>
  )
}
