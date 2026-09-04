import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { ManagementHealth, SystemInfo } from '../../types/api'

export function SystemView({ api }: { api: ApiClient }) {
  const [system, setSystem] = useState<SystemInfo | null>(null)
  const [health, setHealth] = useState<ManagementHealth | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    Promise.all([api.system(), api.managementHealth()])
      .then(([systemInfo, healthInfo]) => {
        setSystem(systemInfo)
        setHealth(healthInfo)
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api])

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Runtime</p><h2>System</h2></div>
        {health && <span className={`status-indicator status-${health.status}`}>{health.status}</span>}
      </header>
      {error && <p className="error-banner">{error}</p>}
      {system && health && (
        <dl className="definition-list">
          <div><dt>Version</dt><dd>{system.version}</dd></div>
          <div><dt>Uptime</dt><dd>{formatDuration(system.uptime)}</dd></div>
          <div><dt>Recovery</dt><dd>{health.recovery}</dd></div>
          <div><dt>Reason</dt><dd>{health.reason}</dd></div>
          <div><dt>Buckets</dt><dd>{system.buckets.toLocaleString()}</dd></div>
          <div><dt>Objects</dt><dd>{system.objects.toLocaleString()}</dd></div>
        </dl>
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
