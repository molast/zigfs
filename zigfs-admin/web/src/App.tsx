import { useMemo, useState } from 'react'
import { createApiClient } from './api/client'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
import { LoginView } from './features/auth/LoginView'
import { BucketsView } from './features/buckets/BucketsView'
import { DashboardView } from './features/dashboard/DashboardView'

type View = 'dashboard' | 'buckets' | 'access-keys'

export default function App() {
  const [token, setToken] = useState(() => sessionStorage.getItem('zigfs-admin-token') ?? '')
  const [view, setView] = useState<View>('dashboard')
  const api = useMemo(() => createApiClient(token), [token])

  if (!token) {
    return <LoginView onLogin={(value) => {
      sessionStorage.setItem('zigfs-admin-token', value)
      setToken(value)
    }} />
  }

  function logout() {
    sessionStorage.removeItem('zigfs-admin-token')
    setToken('')
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
        <button className="logout-button" onClick={logout}>退出</button>
      </aside>
      <main className="content">
        {view === 'dashboard' && <DashboardView api={api} />}
        {view === 'buckets' && <BucketsView api={api} />}
        {view === 'access-keys' && <AccessKeysView api={api} />}
      </main>
    </div>
  )
}
