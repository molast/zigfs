import { useEffect, useMemo, useState } from 'react'
import { createApiClient } from './api/client'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
import { LoginView } from './features/auth/LoginView'
import { BucketsView } from './features/buckets/BucketsView'
import { DashboardView } from './features/dashboard/DashboardView'
import type { AdminSession } from './types/api'

type View = 'dashboard' | 'buckets' | 'access-keys'

export default function App() {
  const [session, setSession] = useState<AdminSession | null>()
  const [view, setView] = useState<View>('dashboard')
  const api = useMemo(() => createApiClient(), [])

  useEffect(() => {
    api.session().then(setSession).catch(() => setSession(null))
  }, [api])

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
          <button className={view === 'access-keys' ? 'active' : ''} onClick={() => setView('access-keys')}>Access Keys</button>
        </nav>
        <button className="logout-button" onClick={() => void logout()}>退出</button>
      </aside>
      <main className="content">
        {view === 'dashboard' && <DashboardView api={api} />}
        {view === 'buckets' && <BucketsView api={api} />}
        {view === 'access-keys' && <AccessKeysView api={api} />}
      </main>
    </div>
  )
}
