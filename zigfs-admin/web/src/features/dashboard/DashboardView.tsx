import { t, getFormatLocale } from '@/locales'
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
    const stopLoading = startLoading(t('dashboard.loadingServiceInformation'))
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
          <p className="eyebrow">{t('dashboard.overview')}</p>
          <h2>{t('dashboard.serverInformation')}</h2>
          <p className="page-description">{t('dashboard.currentZigfsServiceStatusObjectCountsAndUptime')}</p>
        </div>
        <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={refreshing} aria-busy={refreshing}>
          <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />{t('dashboard.sync')}</button>
      </header>
      {system && (
        <>
          <div className="metric-grid">
            <Metric label={t('dashboard.storageSpace')} value={formatBytes(system.storage_used)} />
            <Metric label={t('dashboard.objects')} value={system.objects.toLocaleString(getFormatLocale())} />
            <Metric label={t('dashboard.buckets')} value={system.buckets.toLocaleString(getFormatLocale())} />
            <Metric label={t('dashboard.uptime')} value={formatDuration(system.uptime)} />
          </div>
          <div className="server-summary">
            <section className="panel table-panel">
              <div className="section-heading">
                <div><h3>{t('dashboard.zigfsServer')}</h3><p>{t('dashboard.currentInstanceInformationFromTheZigfsManagementApi')}</p></div>
                <span className={`status-indicator status-${health?.status ?? 'recovery'}`}>{health?.status ?? 'checking'}</span>
              </div>
              <dl className="definition-list">
                <div><dt>{t('dashboard.version')}</dt><dd>{system.version}</dd></div>
                <div><dt>{t('dashboard.storedObjects')}</dt><dd>{system.objects.toLocaleString(getFormatLocale())}</dd></div>
                <div><dt>{t('dashboard.storageUsed')}</dt><dd>{formatBytes(system.storage_used)}</dd></div>
                <div><dt>{t('dashboard.serviceUptime')}</dt><dd>{formatDuration(system.uptime)}</dd></div>
              </dl>
            </section>
            <section className="panel health-panel">
              <div className="health-panel-header"><h3>{t('dashboard.serviceHealth')}</h3><span className="status-dot" /></div>
              <dl className="health-list">
                <div><dt>{t('dashboard.status')}</dt><dd>{health?.status ?? 'checking'}</dd></div>
                <div><dt>{t('dashboard.recovery')}</dt><dd>{health?.recovery ?? '-'}</dd></div>
                <div><dt>{t('dashboard.reason')}</dt><dd>{health?.reason || t('dashboard.normal')}</dd></div>
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
  if (days > 0) return t('dashboard.valuedValueh', { '0': days, '1': hours })
  if (hours > 0) return t('dashboard.valuehValuem', { '0': hours, '1': minutes })
  return `${minutes}m`
}
