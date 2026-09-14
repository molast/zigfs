import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { useLoading } from '../../components/LoadingProvider'
import type { ManagementHealth, SystemInfo } from '../../types/api'

export function SystemView({ api }: { api: ApiClient }) {
  const { withLoading } = useLoading()
  const [system, setSystem] = useState<SystemInfo | null>(null)
  const [health, setHealth] = useState<ManagementHealth | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    withLoading('正在加载系统信息...', () => Promise.all([api.system(), api.managementHealth()]))
      .then(([systemInfo, healthInfo]) => {
        setSystem(systemInfo)
        setHealth(healthInfo)
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api, withLoading])

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Runtime</p><h2>System</h2><p className="page-description">服务版本、恢复状态和运行时规模。</p></div>
        {health && <span className={`status-indicator status-${health.status}`}>{health.status}</span>}
      </header>
      {error && <p className="error-banner">{error}</p>}
      {system && health && (
        <section className="panel table-panel"><dl className="definition-list">
          <div><dt>Version</dt><dd>{system.version}</dd></div>
          <div><dt>Uptime</dt><dd>{formatDuration(system.uptime)}</dd></div>
          <div><dt>Recovery</dt><dd>{health.recovery}</dd></div>
          <div><dt>Reason</dt><dd>{health.reason}</dd></div>
          <div><dt>Buckets</dt><dd>{system.buckets.toLocaleString()}</dd></div>
          <div><dt>Objects</dt><dd>{system.objects.toLocaleString()}</dd></div>
        </dl></section>
      )}
    </section>
  )
}

function formatDuration(seconds: number) {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  return `${days}d ${hours}h ${minutes}m`
}
