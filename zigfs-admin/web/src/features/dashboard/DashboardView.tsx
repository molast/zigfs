import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { ManagementHealth, SystemInfo } from '../../types/api'

interface DashboardViewProps {
  api: ApiClient
}

export function DashboardView({ api }: DashboardViewProps) {
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

  if (error) return <p className="error-banner">{error}</p>
  if (!system) return <p className="loading-state">正在加载...</p>

  return (
    <section>
      <header className="page-header">
        <div>
          <p className="eyebrow">Overview</p>
          <h2>系统概览</h2>
          <p className="page-description">ZigFS 当前服务状态、对象规模和运行时间。</p>
        </div>
        <span className={`status-indicator status-${health?.status ?? 'recovery'}`}>{health?.status ?? 'checking'}</span>
      </header>
      <div className="metric-grid">
        <Metric label="Buckets" value={system.buckets.toLocaleString()} />
        <Metric label="Objects" value={system.objects.toLocaleString()} />
        <Metric label="Storage" value={formatBytes(system.storage_used)} />
        <Metric label="Uptime" value={formatDuration(system.uptime)} />
      </div>
      <div className="detail-band">
        <span>FS Version</span>
        <strong>{system.version}</strong>
      </div>
    </section>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index += 1
  }
  return `${value.toFixed(1)} ${units[index]}`
}

function formatDuration(seconds: number) {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  return days > 0 ? `${days}d ${hours}h` : `${hours}h`
}
