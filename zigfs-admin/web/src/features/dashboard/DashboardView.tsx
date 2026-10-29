import { useErrorToast } from '../../components/ToastProvider'
import { useCallback, useEffect, useState } from 'react'
import { RefreshCw } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import { useLoading } from '../../components/LoadingProvider'
import type { ManagementHealth, SystemInfo } from '../../types/api'

interface DashboardViewProps {
  api: ApiClient
}

export function DashboardView({ api }: DashboardViewProps) {
  const { startLoading } = useLoading()
  const [system, setSystem] = useState<SystemInfo | null>(null)
  const [health, setHealth] = useState<ManagementHealth | null>(null)
  const notifyError = useErrorToast()
  const [refreshing, setRefreshing] = useState(false)

  const refresh = useCallback(async () => {
    const stopLoading = startLoading('正在加载服务信息...')
    try {
      setRefreshing(true)
      const [systemInfo, healthInfo] = await Promise.all([api.system(), api.managementHealth()])
      setSystem(systemInfo)
      setHealth(healthInfo)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setRefreshing(false)
      stopLoading()
    }
  }, [api, startLoading])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <section>
      <header className="page-header">
        <div>
          <p className="eyebrow">Overview</p>
          <h2>Server Information</h2>
          <p className="page-description">ZigFS 当前服务状态、对象规模和运行时间。</p>
        </div>
        <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={refreshing} aria-busy={refreshing}>
          <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />同步
        </button>
      </header>
      {system && (
        <>
          <div className="metric-grid">
            <Metric label="Storage Space" value={formatBytes(system.storage_used)} />
            <Metric label="Objects" value={system.objects.toLocaleString()} />
            <Metric label="Buckets" value={system.buckets.toLocaleString()} />
            <Metric label="Uptime" value={formatDuration(system.uptime)} />
          </div>
          <div className="server-summary">
            <section className="panel table-panel">
              <div className="section-heading">
                <div><h3>ZigFS Server</h3><p>由 FS 管理 API 返回的当前服务实例信息。</p></div>
                <span className={`status-indicator status-${health?.status ?? 'recovery'}`}>{health?.status ?? 'checking'}</span>
              </div>
              <dl className="definition-list">
                <div><dt>Version</dt><dd>{system.version}</dd></div>
                <div><dt>Stored objects</dt><dd>{system.objects.toLocaleString()}</dd></div>
                <div><dt>Storage used</dt><dd>{formatBytes(system.storage_used)}</dd></div>
                <div><dt>Service uptime</dt><dd>{formatDuration(system.uptime)}</dd></div>
              </dl>
            </section>
            <section className="panel health-panel">
              <div className="health-panel-header"><h3>Service Health</h3><span className="status-dot" /></div>
              <dl className="health-list">
                <div><dt>Status</dt><dd>{health?.status ?? 'checking'}</dd></div>
                <div><dt>Recovery</dt><dd>{health?.recovery ?? '-'}</dd></div>
                <div><dt>Reason</dt><dd>{health?.reason || 'Normal'}</dd></div>
              </dl>
            </section>
          </div>
        </>
      )}
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
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return `${days}d ${hours}h`
  if (hours > 0) return `${hours}h ${minutes}m`
  return `${minutes}m`
}
