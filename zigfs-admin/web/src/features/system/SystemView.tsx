import { Activity, Archive, CheckCircle2, ChevronDown, Database, Layers, RefreshCw, Server, TriangleAlert } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { Badge } from '../../components/ui/Badge'
import { Button } from '../../components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '../../components/ui/collapsible'
import { Progress } from '../../components/ui/progress'
import { Separator } from '../../components/ui/separator'
import type { ManagementHealth, Settings, StorageInfo, StorageScannerStatus, SystemInfo } from '../../types/api'

interface Snapshot {
  system: SystemInfo | null
  health: ManagementHealth | null
  storage: StorageInfo | null
  scanner: StorageScannerStatus | null
  settings: Settings | null
  failures: string[]
  refreshedAt: Date
}

export function SystemView({ api }: { api: ApiClient }) {
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
      const results = await Promise.allSettled([api.system(), api.managementHealth(), api.storage(), api.storageScanner(), api.settings()])
      if (!active.current) return
      const [system, health, storage, scanner, settings] = results
      const labels = ['System', 'Health', 'Storage', 'Scanner', 'Settings']
      const failures = results.flatMap((result, index) => result.status === 'rejected' ? [labels[index]] : [])
      setSnapshot({
        system: system.status === 'fulfilled' ? system.value : null,
        health: health.status === 'fulfilled' ? health.value : null,
        storage: storage.status === 'fulfilled' ? storage.value : null,
        scanner: scanner.status === 'fulfilled' ? scanner.value : null,
        settings: settings.status === 'fulfilled' ? settings.value : null,
        failures, refreshedAt: new Date(),
      })
      if (failures.length) notifyError(`无法刷新 ${failures.join('、')}，请重试。`)
    } finally {
      pending.current = false
      if (active.current) setBusy(false)
    }
  }, [api, notifyError])

  useEffect(() => {
    active.current = true
    void refresh()
    const timer = window.setInterval(() => void refresh(), 30_000)
    return () => { active.current = false; window.clearInterval(timer) }
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
  const healthy = health?.status === 'ready' && health.recovery === 'ready' && snapshot?.failures.length === 0 && scanner?.last_attempt_succeeded !== false
  const status = !snapshot ? 'Loading' : healthy ? 'Healthy' : health ? 'Needs attention' : 'Unknown'
  // Storage.used measures logical object bytes, not filesystem allocation.
  const physicalUsed = storage?.physical_used ?? null
  const capacityPercent = physicalUsed !== null && storage?.total && storage.total > 0 ? Math.min(100, physicalUsed / storage.total * 100) : null
  const scanState = !scanner ? 'Unknown' : scanner.running ? 'Running' : scanner.last_attempt_succeeded === false ? 'Failed' : scanner.last_scan ? 'Idle' : 'Not started'
  const diagnostics = [
    { name: 'Peer Health', state: 'Not applicable', detail: 'Single-node deployment; no cluster peers are configured.', source: 'deployment_topology' },
    { name: 'Storage Readiness', state: health ? health.status === 'ready' && health.recovery === 'ready' ? 'Healthy' : 'Needs attention' : 'Unknown', detail: health ? `Storage recovery: ${health.recovery}. ${health.reason || 'Storage reports ready.'}` : 'Storage readiness could not be retrieved.', source: 'runtime_readiness' },
    { name: 'Usage Freshness', state: !scanner ? 'Unknown' : scanner.last_attempt_succeeded === false ? 'Needs attention' : scanner.last_completed_at ? 'Reported' : 'Awaiting scan', detail: scanner?.last_attempt_succeeded === false ? 'The latest scan attempt failed. The last successful result is retained.' : scanner?.last_completed_at ? 'Namespace scan results are available. This timestamp records a successful scan, not an independent usage-cache freshness check.' : 'No successful scan has been reported since startup.', extra: scanner?.last_completed_at ? `Last successful scan: ${new Date(scanner.last_completed_at * 1000).toLocaleString()}` : undefined, source: 'storage_scanner' },
    { name: 'Listing and Metacache', state: 'Not reported', detail: 'Object listings use local metadata. Metacache health and listing latency diagnostics are not reported by this instance.', source: 'local_metadata', extra: 'Cluster quorum and internode timeout metrics do not apply to this single-node deployment.' },
    { name: 'Workload Admission', state: 'Not reported', detail: 'The current runtime does not publish per-class workload admission status.', source: 'runtime_admission' },
  ]

  return <section className="monitoring-page" aria-busy={busy}>
    <header className="monitoring-header">
      <h2>Running Status</h2>
      <div className="monitoring-refresh"><span>Last refreshed: {snapshot ? <time dateTime={snapshot.refreshedAt.toISOString()} title={snapshot.refreshedAt.toLocaleString()}>{relativeTime(snapshot.refreshedAt.getTime() / 1000, now)}</time> : '—'}</span><Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{busy ? 'Refreshing…' : 'Refresh'}</Button></div>
    </header>

    <Card className="monitoring-summary" role="status">
      <div>{healthy ? <CheckCircle2 aria-hidden="true" /> : <TriangleAlert aria-hidden="true" />}<strong>{!snapshot ? 'Loading service status…' : healthy ? 'Service is healthy' : health ? 'Service needs attention' : 'Service health is unknown'}</strong></div>
      <span>Single-node deployment · {snapshot?.failures.length ? `${snapshot.failures.length} data source(s) unavailable` : system ? '1 server reported' : 'Waiting for server data'}</span>
    </Card>

    <div className="monitoring-grid">
      <Card>
        <CardHeader><div className="monitoring-card-heading"><CardTitle>Service Health</CardTitle><Badge>{status}</Badge></div><CardDescription>Readiness and recovery status of this ZigFS instance.</CardDescription></CardHeader>
        <CardContent><div className="monitoring-grid monitoring-health-counts"><div><h4>Servers</h4><div className="monitoring-metrics"><Metric label="Reported" value={system ? '1' : '—'} /><Metric label="Ready" value={health ? health.status === 'ready' ? '1' : '0' : '—'} /></div></div><div><h4>Disks</h4><div className="monitoring-metrics"><Metric label="Online" value="Not reported" /><Metric label="Offline" value="Not reported" /></div></div></div><Separator /><div className="monitoring-metrics"><Metric label="Recovery" value={health?.recovery ?? 'Unknown'} /><Metric label="Version" value={system?.version ?? '—'} /></div></CardContent>
      </Card>
      <Card>
        <CardHeader><CardTitle>Storage Usage and Scanner</CardTitle><CardDescription>Review capacity pressure and scanner activity in one place.</CardDescription></CardHeader>
        <CardContent><div className="monitoring-primary-metric"><Database aria-hidden="true" /><div><span>Usable Capacity Used</span><strong>{physicalUsed !== null ? formatBytes(physicalUsed) : 'Not reported'}</strong></div></div>
          {capacityPercent !== null ? <div className="monitoring-capacity"><Progress value={capacityPercent} aria-label="Filesystem capacity used" /><span>{capacityPercent.toFixed(1)}% filesystem capacity used</span></div> : <p className="monitoring-muted">Filesystem utilization is not reported.</p>}
          <Separator /><div className="monitoring-metrics monitoring-three"><Metric label="Used" value={physicalUsed !== null ? formatBytes(physicalUsed) : 'Not reported'} /><Metric label="Available" value={storage?.available != null ? formatBytes(storage.available) : 'Not reported'} /><Metric label="Total Capacity" value={storage?.total != null ? formatBytes(storage.total) : 'Not reported'} /></div>
          <Separator /><div className="monitoring-metrics monitoring-three"><Metric label="Last Completed Scan" value={scanner?.last_completed_at ? relativeTime(scanner.last_completed_at, now) : 'No completed scan'} /><Metric label="Scanner Status" value={scanState} /><Metric label="Scan Duration" value={scanner?.last_duration_ms != null ? formatScanDuration(scanner.last_duration_ms) : 'Not reported'} /></div>
        </CardContent>
      </Card>
    </div>

    <Card>
      <CardHeader><div className="monitoring-card-heading"><CardTitle>Server List</CardTitle><span className="monitoring-muted">Reported: {system ? 1 : 0} · Expected: 1</span></div><CardDescription>Inspect the local server, API endpoint and recovery details.</CardDescription></CardHeader>
      <CardContent><Collapsible open={serverOpen} onOpenChange={setServerOpen}>
        <CollapsibleTrigger asChild><Button variant="ghost" className="monitoring-server-trigger"><span className="monitoring-server-identity"><Server aria-hidden="true" /><Badge>{health?.status ?? 'Unknown'}</Badge><span>{settings?.api_address ?? 'Local ZigFS server'}</span></span><span>Uptime: {system ? formatDuration(system.uptime) : '—'}</span><ChevronDown data-icon="inline-end" /></Button></CollapsibleTrigger>
        <CollapsibleContent><div className="monitoring-metrics monitoring-three monitoring-server-details"><Metric label="Public S3 Endpoint" value={settings?.s3_public_endpoint || 'Not configured'} /><Metric label="S3 Region" value={settings?.s3_region ?? '—'} /><Metric label="Version" value={system?.version ?? '—'} /></div><p className="monitoring-muted">{health?.reason || 'No recovery reason reported.'}</p>{health?.actions.map(action => <p key={action} className="monitoring-muted">{action}</p>)}</CollapsibleContent>
      </Collapsible></CardContent>
    </Card>

    <section aria-labelledby="monitoring-inventory"><h3 id="monitoring-inventory" className="monitoring-section-title">Inventory</h3><div className="monitoring-grid">
      <Card><CardHeader><div className="monitoring-card-heading"><CardDescription>Buckets</CardDescription><Archive aria-hidden="true" /></div></CardHeader><CardContent><strong className="monitoring-count">{system?.buckets.toLocaleString() ?? '—'}</strong></CardContent></Card>
      <Card><CardHeader><div className="monitoring-card-heading"><CardDescription>Objects</CardDescription><Layers aria-hidden="true" /></div></CardHeader><CardContent><strong className="monitoring-count">{system?.objects.toLocaleString() ?? '—'}</strong></CardContent></Card>
    </div></section>

    <Card><CardHeader><CardTitle>Storage Configuration</CardTitle><CardDescription>Local storage and lifecycle configuration for this instance.</CardDescription></CardHeader><CardContent><Separator /><div className="monitoring-metrics monitoring-three"><Metric label="Backend Type" value="Local filesystem" /><Metric label="Stream Buffer" value={settings ? formatBytes(settings.stream_buffer_size) : '—'} /><Metric label="Lifecycle Scan Interval" value={settings ? formatDuration(settings.lifecycle_scan_interval_seconds) : '—'} /></div><Separator /><div className="monitoring-metrics monitoring-three"><Metric label="Incomplete Upload Expiry" value={settings ? formatDuration(settings.multipart_expiry_seconds) : '—'} /><Metric label="Standard Storage Parity" value="Not applicable" /><Metric label="Reduced Redundancy Parity" value="Not applicable" /></div></CardContent></Card>

    <Card><Collapsible open={diagnosticsOpen} onOpenChange={setDiagnosticsOpen}>
      <CardHeader><div className="monitoring-card-heading"><div><CardTitle>Diagnostic Details</CardTitle><CardDescription>Reported diagnostics and their data sources; unsupported checks are identified below.</CardDescription></div><CollapsibleTrigger asChild><Button variant="ghost" size="sm">{diagnosticsOpen ? 'Collapse' : 'Expand'}<ChevronDown data-icon="inline-end" /></Button></CollapsibleTrigger></div></CardHeader>
      <CollapsibleContent><CardContent><div className="monitoring-diagnostics">{diagnostics.map(item => <div className="monitoring-diagnostic" key={item.name}><strong>{item.name}</strong><Badge>{item.state}</Badge><div><p>{item.detail}</p>{item.extra && <p className="monitoring-muted">{item.extra}</p>}<span>Source: {item.source}</span></div></div>)}</div></CardContent></CollapsibleContent>
    </Collapsible></Card>
    <p className="monitoring-footnote"><Activity aria-hidden="true" />Refreshes automatically every 30 seconds. Unreported measurements are not treated as zero.</p>
  </section>
}

function Metric({ label, value }: { label: string; value: string }) {
  return <div className="monitoring-metric"><span>{label}</span><strong>{value}</strong></div>
}
function formatDuration(seconds: number) {
  const value = Math.max(0, Math.floor(seconds))
  if (value < 60) return `${value}s`
  return `${Math.floor(value / 86400)}d ${Math.floor(value % 86400 / 3600)}h ${Math.floor(value % 3600 / 60)}m`
}
function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index++ }
  return `${value.toFixed(1)} ${units[index]}`
}

const relativeTimeFormatter = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })

function relativeTime(timestamp: number, now: number) {
  const seconds = Math.max(0, Math.floor(now / 1000 - timestamp))
  if (seconds < 10) return 'now'
  if (seconds < 60) return relativeTimeFormatter.format(-seconds, 'second')
  if (seconds < 3600) return relativeTimeFormatter.format(-Math.floor(seconds / 60), 'minute')
  if (seconds < 86400) return relativeTimeFormatter.format(-Math.floor(seconds / 3600), 'hour')
  if (seconds < 604800) return relativeTimeFormatter.format(-Math.floor(seconds / 86400), 'day')
  return new Date(timestamp * 1000).toLocaleDateString()
}
function formatScanDuration(milliseconds: number) {
  if (milliseconds < 1000) return '< 1 second'
  if (milliseconds < 60_000) return `${(milliseconds / 1000).toFixed(1)} seconds`
  return `${(milliseconds / 60_000).toFixed(1)} minutes`
}
