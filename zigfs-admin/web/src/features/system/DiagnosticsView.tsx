import { serviceHealth } from './diagnostics'
import { formatDate, formatDateTime } from '@/lib/dateTime'
import { t, getFormatLocale } from '@/locales'
import {
  Archive,
  CheckCircle2,
  ChevronDown,
  Database,
  Layers,
  RefreshCw,
  Server,
  TriangleAlert,
} from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { Badge } from '../../components/ui/Badge'
import { Button } from '../../components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '../../components/ui/collapsible'
import { Progress } from '../../components/ui/progress'
import { Separator } from '../../components/ui/separator'
import type {
  ManagementHealth,
  Settings,
  StorageInfo,
  StorageScannerStatus,
  SystemInfo,
} from '../../types/api'

interface Snapshot {
  system: SystemInfo | null
  health: ManagementHealth | null
  storage: StorageInfo | null
  scanner: StorageScannerStatus | null
  settings: Settings | null
  failures: string[]
  refreshedAt: Date
}

export function DiagnosticsView({
  api,
  diagnosticsOnly = false,
}: {
  api: ApiClient
  diagnosticsOnly?: boolean
}) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const [busy, setBusy] = useState(false)
  const [now, setNow] = useState(() => Date.now())
  const [serverOpen, setServerOpen] = useState(false)
  const [diagnosticsOpen, setDiagnosticsOpen] = useState(false)
  const active = useRef(false)
  const pending = useRef(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    if (pending.current) return
    pending.current = true
    setBusy(true)
    try {
      const results = await Promise.allSettled([
        api.system(),
        api.managementHealth(),
        diagnosticsOnly ? Promise.resolve(null) : api.storage(),
        diagnosticsOnly ? Promise.resolve(null) : api.storageScanner(),
        diagnosticsOnly ? Promise.resolve(null) : api.settings(),
      ])
      if (!active.current) return
      const [system, health, storage, scanner, settings] = results
      const labels = [
        t('common.system'),
        t('common.health'),
        t('common.storage'),
        t('common.scanner'),
        t('common.settings'),
      ]
      const failures = results.flatMap((result, index) =>
        result.status === 'rejected' ? [labels[index]] : [],
      )
      setSnapshot({
        system: system.status === 'fulfilled' ? system.value : null,
        health: health.status === 'fulfilled' ? health.value : null,
        storage: storage.status === 'fulfilled' ? storage.value : null,
        scanner: scanner.status === 'fulfilled' ? scanner.value : null,
        settings: settings.status === 'fulfilled' ? settings.value : null,
        failures,
        refreshedAt: new Date(),
      })
      if (failures.length)
        notifyError(t('system.unableToRefreshValuePleaseTryAgain', { '0': failures.join('、') }))
    } finally {
      pending.current = false
      if (active.current) setBusy(false)
    }
  }, [api, notifyError, diagnosticsOnly])

  useEffect(() => {
    active.current = true
    void refresh()
    const timer = window.setInterval(() => void refresh(), 30_000)
    return () => {
      active.current = false
      window.clearInterval(timer)
    }
  }, [refresh])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 5_000)
    return () => window.clearInterval(timer)
  }, [])

  const system = snapshot?.system
  const health = snapshot?.health
  const storage = snapshot?.storage
  const scanner = snapshot?.scanner
  const settings = snapshot?.settings
  const runtime = health?.diagnostics
  const volume = runtime?.storage
  const metadata = runtime?.metadata
  const http = runtime?.http
  const healthState = serviceHealth(
    health,
    snapshot?.failures.length ?? 0,
    scanner?.last_attempt_succeeded,
  )
  const healthy = healthState === 'healthy'
  const status = !snapshot
    ? t('system.loading')
    : t(
        healthy
          ? 'system.healthy'
          : healthState === 'attention'
            ? 'system.needsAttention'
            : 'system.unknown',
      )
  const metricCount = (value: number | null | undefined) =>
    value == null ? t('system.unknown') : value.toLocaleString(getFormatLocale())
  const requestSummary = (value: import('../../types/api').OperationMetrics) =>
    t('system.requestMetrics', {
      active: metricCount(value.active),
      completed: metricCount(value.completed),
      failed: metricCount(value.failed),
    })
  // Storage.used measures logical object bytes, not filesystem allocation.
  const physicalUsed = storage?.physical_used ?? null
  const capacityPercent =
    physicalUsed !== null && storage?.total && storage.total > 0
      ? Math.min(100, (physicalUsed / storage.total) * 100)
      : null
  const scanState = !scanner
    ? t('system.unknown')
    : scanner.running
      ? t('system.running')
      : scanner.last_attempt_succeeded === false
        ? t('system.failed')
        : scanner.last_scan
          ? t('system.idle')
          : t('system.notStarted')
  const diagnostics = [
    {
      name: t('system.peerHealth'),
      state: t('system.notApplicable'),
      detail: t('system.singleNodeDeploymentNoClusterPeersAreConfigured'),
      source: 'deployment_topology',
    },
    {
      name: t('system.storageReadiness'),
      state: health
        ? health.status === 'ready' && health.recovery === 'ready'
          ? t('system.healthy')
          : t('system.needsAttention')
        : t('system.unknown'),
      detail: health
        ? t('system.storageRecoveryValueValue', {
            '0': health.recovery,
            '1': health.reason || t('common.storageReportsReady'),
          })
        : t('system.storageReadinessCouldNotBeRetrieved'),
      source: 'runtime_readiness',
    },
    {
      name: t('system.usageFreshness'),
      state: !scanner
        ? t('system.unknown')
        : scanner.last_attempt_succeeded === false
          ? t('system.needsAttention')
          : scanner.last_completed_at
            ? t('system.reported')
            : t('system.awaitingScan'),
      detail:
        scanner?.last_attempt_succeeded === false
          ? t('system.theLatestScanAttemptFailedTheLastSuccessfulResult')
          : scanner?.last_completed_at
            ? t('system.namespaceScanResultsAreAvailableThisTimestampRecordsA')
            : t('system.noSuccessfulScanHasBeenReportedSinceStartup'),
      extra: scanner?.last_completed_at
        ? t('system.lastSuccessfulScanValue', {
            '0': formatDateTime(scanner.last_completed_at * 1000),
          })
        : undefined,
      source: 'storage_scanner',
    },
    {
      name: t('system.dataFilesystem'),
      state: t(
        !volume || volume.state === 'unknown'
          ? 'system.unknown'
          : volume.state === 'offline'
            ? 'system.offline'
            : volume.read_only
              ? 'system.filesystemReadOnly'
              : 'system.online',
      ),
      detail: t('system.filesystemProbeHelp'),
      source: 'data_root_fstatvfs',
    },
    {
      name: t('system.localIndexAndListings'),
      state: t(
        !metadata ? 'system.unknown' : metadata.ready ? 'system.ready' : 'system.needsAttention',
      ),
      detail: metadata
        ? t('system.indexMetrics', {
            buckets: metricCount(metadata.buckets),
            objects: metricCount(metadata.objects),
            directories: metricCount(metadata.directories),
          })
        : t('system.diagnosticsUnavailable'),
      source: 'metadata_index',
      extra: metadata
        ? t('system.listingMetrics', {
            active: metricCount(metadata.listings.active),
            completed: metricCount(metadata.listings.completed),
            failed: metricCount(metadata.listings.failed),
            duration:
              metadata.listings.last_duration_ms == null
                ? t('system.noListingRequests')
                : formatScanDuration(metadata.listings.last_duration_ms),
            outcome: t(
              metadata.listings.last_succeeded == null
                ? 'system.noListingRequests'
                : metadata.listings.last_succeeded
                  ? 'system.lastListingSucceeded'
                  : 'system.lastListingFailed',
            ),
          })
        : undefined,
    },
    {
      name: t('system.httpAdmission'),
      state: t(http ? 'system.reported' : 'system.unknown'),
      detail: http
        ? t('system.connectionMetrics', {
            active: metricCount(http.active_connections),
            accepted: metricCount(http.accepted_connections),
            rejected: metricCount(http.rejected_connections),
          })
        : t('system.diagnosticsUnavailable'),
      source: 'http_runtime',
      extra: http
        ? t('system.httpRequestMetrics', {
            s3: requestSummary(http.s3),
            management: requestSummary(http.management),
          })
        : undefined,
    },
  ]

  return (
    <section className="monitoring-page" aria-busy={busy}>
      <header className="monitoring-header">
        <h2>{t('system.runningStatus')}</h2>
        <div className="monitoring-refresh">
          <span>
            {t('system.lastRefreshed')}{' '}
            {snapshot ? (
              <time
                dateTime={snapshot.refreshedAt.toISOString()}
                title={formatDateTime(snapshot.refreshedAt)}
              >
                {relativeTime(snapshot.refreshedAt.getTime() / 1000, now)}
              </time>
            ) : (
              '—'
            )}
          </span>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}>
            <RefreshCw data-icon="inline-start" />
            {busy ? t('system.refreshing') : t('system.refresh')}
          </Button>
        </div>
      </header>

      <Card
        help={t('system.readinessAndRecoveryStatusOfThisZigfsInstance')}
        className="monitoring-summary"
        role="status"
      >
        <div>
          {healthy ? <CheckCircle2 aria-hidden="true" /> : <TriangleAlert aria-hidden="true" />}
          <strong>
            {!snapshot
              ? t('system.loadingServiceStatus')
              : healthy
                ? t('system.serviceIsHealthy')
                : healthState === 'attention'
                  ? t('system.serviceNeedsAttention')
                  : t('system.serviceHealthIsUnknown')}
          </strong>
        </div>
        <span>
          {t('system.singleNodeDeployment')}{' '}
          {snapshot?.failures.length
            ? t('system.valueDataSourceSUnavailable', { '0': snapshot.failures.length })
            : system
              ? t('system.oneServerReported')
              : t('system.waitingForServerData')}
        </span>
      </Card>

      <div className="monitoring-grid">
        <Card help={t('system.readinessAndRecoveryStatusOfThisZigfsInstance')}>
          <CardHeader>
            <div className="monitoring-card-heading">
              <CardTitle>{t('system.serviceHealth')}</CardTitle>
              <Badge>{status}</Badge>
            </div>
            <CardDescription>
              {t('system.readinessAndRecoveryStatusOfThisZigfsInstance')}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="monitoring-grid monitoring-health-counts">
              <div>
                <h4>{t('system.servers')}</h4>
                <div className="monitoring-metrics">
                  <Metric label={t('system.reported')} value={system ? '1' : '—'} />
                  <Metric
                    label={t('system.ready')}
                    value={health ? (health.status === 'ready' ? '1' : '0') : '—'}
                  />
                </div>
              </div>
              <div>
                <h4>{t('system.dataFilesystems')}</h4>
                <div className="monitoring-metrics">
                  <Metric label={t('system.online')} value={metricCount(volume?.online)} />
                  <Metric label={t('system.offline')} value={metricCount(volume?.offline)} />
                </div>
              </div>
            </div>
            <Separator />
            <div className="monitoring-metrics">
              <Metric
                label={t('system.recovery')}
                value={health?.recovery ?? t('common.unknown')}
              />
              <Metric label={t('system.version')} value={system?.version ?? '—'} />
            </div>
          </CardContent>
        </Card>
        {!diagnosticsOnly && (
          <Card help={t('system.reviewCapacityPressureAndScannerActivityInOnePlace')}>
            <CardHeader>
              <CardTitle>{t('system.storageUsageAndScanner')}</CardTitle>
              <CardDescription>
                {t('system.reviewCapacityPressureAndScannerActivityInOnePlace')}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="monitoring-primary-metric">
                <Database aria-hidden="true" />
                <div>
                  <span>{t('system.usableCapacityUsed')}</span>
                  <strong>
                    {physicalUsed !== null ? formatBytes(physicalUsed) : t('system.notReported')}
                  </strong>
                </div>
              </div>
              {capacityPercent !== null ? (
                <div className="monitoring-capacity">
                  <Progress
                    value={capacityPercent}
                    aria-label={t('system.filesystemCapacityUsed')}
                  />
                  <span>
                    {capacityPercent.toFixed(1)}
                    {t('system.filesystemCapacityUsedPercentLabel')}
                  </span>
                </div>
              ) : (
                <p className="monitoring-muted">{t('system.filesystemUtilizationIsNotReported')}</p>
              )}
              <Separator />
              <div className="monitoring-metrics monitoring-three">
                <Metric
                  label={t('system.used')}
                  value={
                    physicalUsed !== null ? formatBytes(physicalUsed) : t('common.notReported')
                  }
                />
                <Metric
                  label={t('system.available')}
                  value={
                    storage?.available != null
                      ? formatBytes(storage.available)
                      : t('common.notReported')
                  }
                />
                <Metric
                  label={t('system.totalCapacity')}
                  value={
                    storage?.total != null ? formatBytes(storage.total) : t('common.notReported')
                  }
                />
              </div>
              <Separator />
              <div className="monitoring-metrics monitoring-three">
                <Metric
                  label={t('system.lastCompletedScan')}
                  value={
                    scanner?.last_completed_at
                      ? relativeTime(scanner.last_completed_at, now)
                      : t('common.noCompletedScan')
                  }
                />
                <Metric label={t('system.scannerStatus')} value={scanState} />
                <Metric
                  label={t('system.scanDuration')}
                  value={
                    scanner?.last_duration_ms != null
                      ? formatScanDuration(scanner.last_duration_ms)
                      : t('common.notReported')
                  }
                />
              </div>
            </CardContent>
          </Card>
        )}
      </div>

      <Card help={t('system.inspectTheLocalServerApiEndpointAndRecoveryDetails')}>
        <CardHeader>
          <div className="monitoring-card-heading">
            <CardTitle>{t('system.serverList')}</CardTitle>
            <span className="monitoring-muted">
              {t('system.reportedLabel')} {system ? 1 : 0} {t('system.expected1')}
            </span>
          </div>
          <CardDescription>
            {t('system.inspectTheLocalServerApiEndpointAndRecoveryDetails')}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Collapsible open={serverOpen} onOpenChange={setServerOpen}>
            <CollapsibleTrigger asChild>
              <Button variant="ghost" className="monitoring-server-trigger">
                <span className="monitoring-server-identity">
                  <Server aria-hidden="true" />
                  <Badge>{health?.status ?? t('system.unknown')}</Badge>
                  <span>{settings?.api_address ?? t('system.localZigfsServer')}</span>
                </span>
                <span>
                  {t('system.uptime')} {system ? formatDuration(system.uptime) : '—'}
                </span>
                <ChevronDown data-icon="inline-end" />
              </Button>
            </CollapsibleTrigger>
            <CollapsibleContent>
              <div className="monitoring-metrics monitoring-three monitoring-server-details">
                <Metric
                  label={t('system.publicS3Endpoint')}
                  value={settings?.s3_public_endpoint || t('common.notConfigured')}
                />
                <Metric label={t('system.s3Region')} value={settings?.s3_region ?? '—'} />
                <Metric label={t('system.version')} value={system?.version ?? '—'} />
              </div>
              <p className="monitoring-muted">
                {health?.reason || t('system.noRecoveryReasonReported')}
              </p>
              {health?.actions.map((action) => (
                <p key={action} className="monitoring-muted">
                  {action}
                </p>
              ))}
            </CollapsibleContent>
          </Collapsible>
        </CardContent>
      </Card>

      <section aria-labelledby="monitoring-inventory">
        <h3 id="monitoring-inventory" className="monitoring-section-title">
          {t('system.inventory')}
        </h3>
        <div className="monitoring-grid">
          <Card help={t('monitor.infoBuckets')}>
            <CardHeader>
              <div className="monitoring-card-heading">
                <CardDescription>{t('system.buckets')}</CardDescription>
                <Archive aria-hidden="true" />
              </div>
            </CardHeader>
            <CardContent>
              <strong className="monitoring-count">
                {system?.buckets.toLocaleString(getFormatLocale()) ?? '—'}
              </strong>
            </CardContent>
          </Card>
          <Card help={t('monitor.infoObjects')}>
            <CardHeader>
              <div className="monitoring-card-heading">
                <CardDescription>{t('system.objects')}</CardDescription>
                <Layers aria-hidden="true" />
              </div>
            </CardHeader>
            <CardContent>
              <strong className="monitoring-count">
                {system?.objects.toLocaleString(getFormatLocale()) ?? '—'}
              </strong>
            </CardContent>
          </Card>
        </div>
      </section>

      {!diagnosticsOnly && (
        <Card help={t('system.localStorageAndLifecycleConfigurationForThisInstance')}>
          <CardHeader>
            <CardTitle>{t('system.storageConfiguration')}</CardTitle>
            <CardDescription>
              {t('system.localStorageAndLifecycleConfigurationForThisInstance')}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Separator />
            <div className="monitoring-metrics monitoring-three">
              <Metric label={t('system.backendType')} value="Local filesystem" />
              <Metric
                label={t('system.streamBuffer')}
                value={settings ? formatBytes(settings.stream_buffer_size) : '—'}
              />
              <Metric
                label={t('system.lifecycleScanInterval')}
                value={settings ? formatDuration(settings.lifecycle_scan_interval_seconds) : '—'}
              />
            </div>
            <Separator />
            <div className="monitoring-metrics monitoring-three">
              <Metric
                label={t('system.incompleteUploadExpiry')}
                value={settings ? formatDuration(settings.multipart_expiry_seconds) : '—'}
              />
              <Metric label={t('system.standardStorageParity')} value="Not applicable" />
              <Metric label={t('system.reducedRedundancyParity')} value="Not applicable" />
            </div>
          </CardContent>
        </Card>
      )}

      <Card help={t('system.reportedDiagnosticsAndTheirDataSourcesUnsupportedChecksAre')}>
        <Collapsible open={diagnosticsOpen} onOpenChange={setDiagnosticsOpen}>
          <CardHeader>
            <div className="monitoring-card-heading">
              <div>
                <CardTitle>{t('system.diagnosticDetails')}</CardTitle>
                <CardDescription>
                  {t('system.reportedDiagnosticsAndTheirDataSourcesUnsupportedChecksAre')}
                </CardDescription>
              </div>
              <CollapsibleTrigger asChild>
                <Button variant="ghost" size="sm">
                  {diagnosticsOpen ? t('system.collapse') : t('system.expand')}
                  <ChevronDown data-icon="inline-end" />
                </Button>
              </CollapsibleTrigger>
            </div>
          </CardHeader>
          <CollapsibleContent>
            <CardContent>
              <div className="monitoring-diagnostics">
                {diagnostics.map((item) => (
                  <div className="monitoring-diagnostic" key={item.name}>
                    <strong>{item.name}</strong>
                    <Badge>{item.state}</Badge>
                    <div>
                      <p>{item.detail}</p>
                      {item.extra && <p className="monitoring-muted">{item.extra}</p>}
                      <span>
                        {t('system.source')} {item.source}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
              <p className="monitoring-muted">{t('system.runtimeMetricsHelp')}</p>
            </CardContent>
          </CollapsibleContent>
        </Collapsible>
      </Card>
    </section>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="monitoring-metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}
function formatDuration(seconds: number) {
  const value = Math.max(0, Math.floor(seconds))
  if (value < 60) return `${value}s`
  return t('system.valuedValuehValuem', {
    '0': Math.floor(value / 86400),
    '1': Math.floor((value % 86400) / 3600),
    '2': Math.floor((value % 3600) / 60),
  })
}
function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index++
  }
  return `${value.toFixed(1)} ${units[index]}`
}

function relativeTime(timestamp: number, now: number) {
  const relativeTimeFormatter = new Intl.RelativeTimeFormat(getFormatLocale(), { numeric: 'auto' })
  const seconds = Math.max(0, Math.floor(now / 1000 - timestamp))
  if (seconds < 10) return t('common.now')
  if (seconds < 60) return relativeTimeFormatter.format(-seconds, 'second')
  if (seconds < 3600) return relativeTimeFormatter.format(-Math.floor(seconds / 60), 'minute')
  if (seconds < 86400) return relativeTimeFormatter.format(-Math.floor(seconds / 3600), 'hour')
  if (seconds < 604800) return relativeTimeFormatter.format(-Math.floor(seconds / 86400), 'day')
  return formatDate(timestamp * 1000)
}
function formatScanDuration(milliseconds: number) {
  if (milliseconds < 1000) return t('common.lessThanOneSecond')
  if (milliseconds < 60_000)
    return t('system.valueSeconds', { '0': (milliseconds / 1000).toFixed(1) })
  return t('system.valueMinutes', { '0': (milliseconds / 60_000).toFixed(1) })
}
