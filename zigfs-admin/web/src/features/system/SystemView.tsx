import { Children, useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { Activity, Pause, Play, RefreshCw } from 'lucide-react'
import { Area, AreaChart, CartesianGrid, Line, LineChart, XAxis, YAxis } from 'recharts'
import type { ApiClient } from '@/api/client'
import { useErrorToast } from '@/components/ToastProvider'
import { Badge } from '@/components/ui/Badge'
import { Button } from '@/components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/Card'
import { ChartContainer, ChartLegend, ChartLegendContent, ChartTooltip, ChartTooltipContent } from '@/components/ui/chart'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty'
import { LevelMeter } from '@/components/ui/level-meter'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { getFormatLocale, t } from '@/locales'
import type { Monitoring, MonitorPoint } from '@/types/api'
import { formatMonitorBytes, historyWithGaps, operationPercentile, formatMonitorTime, monitorLevel } from './monitoring'
import { MonitorSection } from './MonitorSection'
import { PerformanceDiagnostics } from './PerformanceDiagnostics'
import { DiagnosticsView } from './DiagnosticsView'

type Field = Exclude<keyof MonitorPoint, 'timestamp' | 'run_id' | 'user_cpu_seconds' | 'kernel_cpu_seconds' | 'allocated_bytes' | 'freed_bytes' | 'reallocations'>
const fieldLabels: Record<Field, Parameters<typeof t>[0]> = {
  workers: 'monitor.workers',
  workers_busy: 'monitor.workersBusy',
  host_cpu: 'monitor.hostCpu',
  process_cpu: 'monitor.processCpu',
  memory_used: 'monitor.memoryUsed',
  memory_total: 'monitor.memoryTotal',
  rss: 'monitor.rss',
  virtual_bytes: 'monitor.virtualBytes',
  peak_rss: 'monitor.peakRss',
  heap: 'monitor.heap',
  heap_peak: 'monitor.heapPeak',
  allocations: 'monitor.allocations',
  frees: 'monitor.frees',
  allocation_failures: 'monitor.allocationFailures',
  cores: 'monitor.cores',
  threads: 'monitor.threads',
  descriptors: 'monitor.descriptors',
  descriptor_limit: 'monitor.descriptorLimit',
  storage_used: 'monitor.storageUsed',
  storage_total: 'monitor.storageTotal',
  storage_available: 'monitor.storageAvailable',
  load1: 'monitor.load1',
  load5: 'monitor.load5',
  load15: 'monitor.load15',
  disk_read: 'monitor.diskRead',
  disk_write: 'monitor.diskWrite',
  network_receive: 'monitor.networkReceive',
  network_transmit: 'monitor.networkTransmit',
  upload: 'monitor.upload',
  download: 'monitor.download',
  qps: 'monitor.qps',
  error_percent: 'monitor.errorPercent',
  client_error_percent: 'monitor.clientErrorPercent',
  p50: 'monitor.p50',
  p95: 'monitor.p95',
  p99: 'monitor.p99',
  active_requests: 'monitor.activeRequests',
  active_connections: 'monitor.activeConnections',
}
const number = (value: number | null | undefined, digits = 1) => value == null ? '—' : value.toLocaleString(getFormatLocale(), { maximumFractionDigits: digits })
const bytes = (value: number | null | undefined) => formatMonitorBytes(value, getFormatLocale())
const percent = (used: number | null | undefined, total: number | null | undefined) => used == null || total == null || total <= 0 ? null : used / total * 100
const clock = (timestamp: unknown) => formatMonitorTime(timestamp, getFormatLocale())

export function SystemView({ api, diagnosticsOnly = false }: { api: ApiClient; diagnosticsOnly?: boolean }) {
  const [snapshot, setSnapshot] = useState<Monitoring | null>(null)
  const [range, setRange] = useState('3600')
  const [paused, setPaused] = useState(false)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)
  const [now, setNow] = useState(Date.now())
  const refreshRef = useRef<() => void>(() => {})
  const notifyError = useErrorToast()

  useEffect(() => {
    let disposed = false
    let pending = false
    const refresh = async () => {
      if (pending) return
      pending = true
      setBusy(true)
      try {
        const result = await api.monitoring(Number(range))
        if (!disposed) { setSnapshot(result); setFailed(false) }
      } catch {
        if (!disposed) { setFailed(true); notifyError(t('monitor.refreshError')) }
      } finally {
        pending = false
        if (!disposed) setBusy(false)
      }
    }
    refreshRef.current = () => void refresh()
    void refresh()
    return () => { disposed = true }
  }, [api, range, notifyError])
  useEffect(() => {
    if (paused) return
    const timer = window.setInterval(() => { if (!document.hidden) refreshRef.current() }, 5000)
    return () => window.clearInterval(timer)
  }, [paused])
  useEffect(() => { const timer = window.setInterval(() => setNow(Date.now()), 1000); return () => window.clearInterval(timer) }, [])
  const refresh = useCallback(() => refreshRef.current(), [])
  const p = snapshot?.latest
  const stale = failed || (p != null && now / 1000 - p.timestamp > 15)
  const points = historyWithGaps(snapshot?.history ?? [], snapshot?.history_step_seconds ?? 10)
  const memoryPercent = percent(p?.memory_used, p?.memory_total)
  const diskPercent = percent(p?.storage_used, p?.storage_total)
  const series = (...keys: Field[]) => keys.map(key => ({ key, label: t(fieldLabels[key]) }))
  const level = (field: Field, limit?: number | null) => {
    const metric = monitorLevel(p, snapshot?.history ?? [], field, limit)
    const format = (value: number | null) => ['rss', 'heap', 'storage_available'].includes(field) ? bytes(value) : field === 'process_cpu' ? `${number(value)}%` : number(value)
    return <LevelMeter key={`${field}-${p?.run_id}`} {...metric} frozen={paused || stale}
      label={t(fieldLabels[field])} valueText={format(metric.value)}
      description={metric.value == null ? t('monitor.levelUnavailable') : t('monitor.levelHelp', { max: format(metric.max), peak: format(metric.peak) })} />
  }

  return <section className="monitor-dashboard" aria-busy={busy}>
    <header className="monitoring-header flex-wrap">
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
        <div className="flex flex-col gap-1"><h2>{t('monitor.title')}</h2><p className="text-xs text-muted-foreground">{t('monitor.subtitle')}</p></div>
        <div className="flex flex-col gap-1 text-xs text-muted-foreground" role="status">
          <span>{t('monitor.sampledAt', { time: p ? clock(p.timestamp) : '—' })}</span>
          <span>{t('monitor.retention', { seconds: snapshot?.sample_interval_seconds ?? 1 })}</span>
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {snapshot?.persistence && <Badge variant={snapshot.persistence.state === 'unavailable' ? 'destructive' : 'default'}>{t(snapshot.persistence.state === 'healthy' ? 'monitor.historySaved' : snapshot.persistence.state === 'unavailable' ? 'monitor.historyUnavailable' : 'monitor.historyPending')}</Badge>}
        <Badge variant={stale ? 'destructive' : 'default'}>{t(paused ? 'monitor.paused' : stale ? 'monitor.stale' : p ? 'monitor.live' : 'system.loading')}</Badge>
        <Select value={range} onValueChange={setRange}><SelectTrigger size="xs" aria-label={t('monitor.timeRange')}><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{['300', '900', '3600', '21600', '86400'].map(value => <SelectItem value={value} key={value}>{t(`monitor.range${value}` as 'monitor.range300')}</SelectItem>)}</SelectGroup></SelectContent></Select>
        <Button size="sm" variant="outline" onClick={() => setPaused(value => !value)} aria-label={t(paused ? 'monitor.resume' : 'monitor.pause')}>{paused ? <Play /> : <Pause />}{t(paused ? 'monitor.resume' : 'monitor.pause')}</Button>
        <Button size="sm" variant="outline" onClick={refresh} disabled={busy}><RefreshCw />{t('system.refresh')}</Button>
      </div>
    </header>
    {!snapshot ? failed ? <Empty><EmptyHeader><EmptyTitle>{t('monitor.unavailable')}</EmptyTitle><EmptyDescription>{t('monitor.retryHelp')}</EmptyDescription></EmptyHeader><Button variant="outline" onClick={refresh}>{t('system.refresh')}</Button></Empty> : <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">{[0, 1, 2, 3].map(i => <Skeleton key={i} className="h-40" />)}</div> : <>
      <MonitorSection title={t('monitor.overview')} panels={16} defaultOpen>
      <div className="monitor-gauges">
        <ResourceCard kind="cpu" points={points.filter(point => point.timestamp >= (p?.timestamp ?? 0) - 60)} title={t('monitor.hostCpu')} value={p?.host_cpu} detail={t('monitor.cpuScope', { cores: number(p?.cores, 0) })} />
        <ResourceCard kind="memory" title={t('monitor.hostMemory')} value={memoryPercent} detail={`${bytes(p?.memory_used)} / ${bytes(p?.memory_total)}`} />
        <ResourceCard kind="disk" title={t('monitor.filesystem')} value={diskPercent} detail={`${bytes(p?.storage_used)} / ${bytes(p?.storage_total)}`} />
        <ResourceCard kind="rss" points={points.filter(point => point.timestamp >= (p?.timestamp ?? 0) - 60)} title={t('monitor.rss')} value={p?.rss} detail={t('monitor.memoryDetail', { peak: bytes(p?.peak_rss), virtual: bytes(p?.virtual_bytes) })} />
      </div>
      <div className="monitor-stats">
        <Stat meter={level('process_cpu', (p?.cores ?? 1) * 100)} title={t('monitor.processCpu')} value={p?.process_cpu == null ? '—' : `${number(p.process_cpu)}%`} detail={t('monitor.processCpuScope')} />
        <Stat meter={level('descriptors', p?.descriptor_limit)} title={t('monitor.descriptors')} value={number(p?.descriptors, 0)} detail={`${number(p?.descriptors, 0)} / ${number(p?.descriptor_limit, 0)}`} />
        <Stat meter={level('heap', p?.heap_peak)} title={t('monitor.heap')} value={bytes(p?.heap)} detail={t('monitor.peakValue', { value: bytes(p?.heap_peak) })} />
        <Stat meter={level('threads')} title={t('monitor.threads')} value={number(p?.threads, 0)} detail={t('monitor.osThreads')} />
        <Stat meter={level('qps')} title={t('monitor.qps')} value={number(p?.qps)} detail={t('monitor.s3Only')} />
        <Stat meter={level('active_requests')} title={t('monitor.activeRequests')} value={number(p?.active_requests, 0)} detail={t('monitor.connections', { count: number(p?.active_connections, 0) })} />
        <Stat title={t('monitor.allocations')} value={number(p?.allocations, 0)} detail={t('monitor.freesValue', { count: number(p?.frees, 0) })} />
        <Stat title={t('monitor.allocationFailures')} value={number(p?.allocation_failures, 0)} detail={t('monitor.sinceStart')} />
      </div>
      <div className="monitor-stats">
        <Stat title={t('monitor.uptime')} value={`${number(Math.max(0, (p?.timestamp ?? snapshot.started_at) - snapshot.started_at) / 3600)} h`} detail={new Date(snapshot.started_at * 1000).toLocaleString(getFormatLocale())} />
        <Stat title={t('monitor.load')} value={`${number(p?.load1)} / ${number(p?.load5)} / ${number(p?.load15)}`} detail={t('monitor.loadHelp')} />
        <Stat meter={level('storage_available', p?.storage_total)} title={t('monitor.storageAvailable')} value={bytes(p?.storage_available)} detail={t('monitor.filesystemScope')} />
        <Stat meter={level('workers', p?.threads)} title={t('monitor.workers')} value={number(p?.workers, 0)} detail={t('monitor.workerHelp', { count: number(p?.workers_busy, 0) })} />
      </div>
      </MonitorSection>
      <Section title={t('monitor.resources')} description={t('monitor.resourceHelp')}>
        <Trend title={t('monitor.cpuChart')} points={points} series={series('host_cpu', 'process_cpu')} unit="%" />
        <Trend title={t('monitor.memoryChart')} points={points} series={series('rss', 'heap')} unit="bytes" />
        <Trend title={t('monitor.diskChart')} points={points} series={series('disk_read', 'disk_write')} unit="bytes/s" />
        <Trend title={t('monitor.networkChart')} points={points} series={series('network_receive', 'network_transmit')} unit="bytes/s" />
      </Section>
      <Section title={t('monitor.requests')} description={t('monitor.requestHelp')}>
        <Trend title={t('monitor.qps')} points={points} series={series('qps')} unit="req/s" />
        <Trend title={t('monitor.latency')} points={points} series={series('p50', 'p95', 'p99')} unit="ms" requestMetric />
        <Trend title={t('monitor.errorChart')} points={points} series={series('error_percent', 'client_error_percent')} unit="%" requestMetric />
        <Trend title={t('monitor.transferChart')} points={points} series={series('upload', 'download')} unit="bytes/s" />
      </Section>
      <MonitorSection title={t('monitor.operationSummary')} panels={2}>
      <Card><CardHeader><CardTitle>{t('monitor.operationSummary')}</CardTitle><CardDescription>{t('monitor.operationHelp')}</CardDescription></CardHeader><CardContent><Table><TableHeader><TableRow>{['service', 'completed', 'active', 'errors', 'clientErrors', 'mean'].map(key => <TableHead key={key}>{t(`monitor.${key}` as 'monitor.service')}</TableHead>)}</TableRow></TableHeader><TableBody>{(['s3', 'management', 'listings'] as const).map(key => {
        const row = snapshot[key]
        return <TableRow key={key}><TableCell>{t(`monitor.${key}`)}</TableCell><TableCell>{number(row.completed, 0)}</TableCell><TableCell>{number(row.active, 0)}</TableCell><TableCell>{number(row.failed, 0)}</TableCell><TableCell>{key === 'listings' ? '—' : number(row.client_errors, 0)}</TableCell><TableCell>{row.completed ? `${number(row.duration_ms / row.completed, 2)} ms` : '—'}</TableCell></TableRow>
      })}</TableBody></Table></CardContent></Card>
      <Card><CardHeader><CardTitle>{t('monitor.s3Operations')}</CardTitle><CardDescription>{t('monitor.operationHelp')}</CardDescription></CardHeader><CardContent><Table><TableHeader><TableRow>{['operation', 'completed', 'active', 'errors', 'clientErrors', 'mean', 'p50', 'p95', 'p99', 'upload', 'download'].map(key => <TableHead key={key}>{t(`monitor.${key}` as 'monitor.service')}</TableHead>)}</TableRow></TableHeader><TableBody>{snapshot.operations.filter(row => row.metrics.completed > 0 || row.metrics.active > 0).map(({ name, metrics: row }) => <TableRow key={name}><TableCell>{name}</TableCell><TableCell>{number(row.completed, 0)}</TableCell><TableCell>{number(row.active, 0)}</TableCell><TableCell>{number(row.failed, 0)}</TableCell><TableCell>{number(row.client_errors, 0)}</TableCell><TableCell>{row.completed ? `${number(row.duration_ms / row.completed, 2)} ms` : '—'}</TableCell>{[0.5, 0.95, 0.99].map(q => <TableCell key={q}>{operationPercentile(row, q) == null ? '—' : `${number(operationPercentile(row, q))} ms`}</TableCell>)}<TableCell>{['put_object', 'post_policy_upload', 'upload_part'].includes(name) ? bytes(row.uploaded_bytes) : '—'}</TableCell><TableCell>{name === 'get_object' ? bytes(row.downloaded_bytes) : '—'}</TableCell></TableRow>)}{snapshot.operations.every(row => row.metrics.completed === 0 && row.metrics.active === 0) && <TableRow><TableCell colSpan={11}>{t('monitor.noSamples')}</TableCell></TableRow>}</TableBody></Table></CardContent></Card>

      </MonitorSection>
      <PerformanceDiagnostics api={api} snapshot={snapshot} readOnly={diagnosticsOnly} refresh={refresh} />
    </>}
    <MonitorSection title={t('system.diagnosticDetails')} panels={1}><DiagnosticsView api={api} diagnosticsOnly={diagnosticsOnly} /></MonitorSection>
    <p className="flex items-center gap-2 text-xs text-muted-foreground"><Activity aria-hidden="true" className="size-4 shrink-0" />{t('monitor.footnote')}</p>
  </section>
}

function Stat({ title, value, detail, meter }: { title: string; value: string; detail: string; meter?: ReactNode }) {
  return <Card className="monitor-overview-card"><CardHeader><CardDescription>{title}</CardDescription></CardHeader><CardContent><div className="monitor-stat-reading"><div className="monitor-stat-value">{value}</div>{meter}</div><p className="mt-2 text-xs text-muted-foreground">{detail}</p></CardContent></Card>
}
function ResourceCard({ kind, title, value, detail, points = [] }: { kind: 'cpu' | 'memory' | 'disk' | 'rss'; title: string; value: number | null | undefined; detail: string; points?: MonitorPoint[] }) {
  const bounded = value == null || !Number.isFinite(value) ? null : Math.max(0, Math.min(100, value))
  const color = bounded == null ? 'var(--muted)' : bounded >= 90 ? 'var(--destructive)' : bounded >= 70 ? 'var(--warning)' : 'var(--success)'
  const display = kind === 'rss' ? bytes(value) : bounded == null ? '—' : `${number(bounded)}%`
  const trendField = kind === 'rss' ? 'rss' : 'host_cpu'
  return <Card className="monitor-overview-card"><CardHeader><CardTitle>{title}</CardTitle></CardHeader><CardContent>
    <div className={`monitor-resource-graphic monitor-resource-${kind}`}>
      {kind === 'memory' || kind === 'disk' ? <>
        <svg className="monitor-memory-ring" viewBox="0 0 80 80" role="img" aria-label={`${title}: ${display}`}>
          <circle cx="40" cy="40" r="30" fill="none" stroke="var(--muted)" strokeWidth="9" />
          {bounded != null && <circle cx="40" cy="40" r="30" fill="none" stroke={color} strokeWidth="9" pathLength="100" strokeDasharray={`${bounded} 100`} transform="rotate(-90 40 40)" />}
        </svg><div><strong className="monitor-resource-value">{display}</strong><span className="monitor-resource-caption">{t('monitor.usedShare')}</span>{kind === 'disk' && <span className="monitor-resource-caption">{t('monitor.remainingShare', { value: bounded == null ? '—' : `${number(100 - bounded)}%` })}</span>}</div>
      </> : <>
        <div className="monitor-resource-reading"><strong className="monitor-resource-value">{display}</strong><span className="monitor-resource-caption">{t('monitor.lastMinute')}</span></div>
        <ChartContainer config={{ [trendField]: { label: title, color: 'var(--chart-2)' } }} className="monitor-cpu-sparkline">
          <AreaChart accessibilityLayer data={points} margin={{ top: 3, right: 3, bottom: 3, left: 3 }}>
            <YAxis hide domain={[0, kind === 'rss' ? 'auto' : 100]} /><XAxis hide dataKey="timestamp" type="number" domain={['dataMin', 'dataMax']} />
            <ChartTooltip content={<ChartTooltipContent labelFormatter={(_label, payload) => clock(payload[0]?.payload?.timestamp)} valueFormatter={v => kind === 'rss' ? bytes(typeof v === 'number' ? v : null) : `${number(typeof v === 'number' ? v : null)}%`} />} />
            <Area dataKey={trendField} type="linear" stroke={`var(--color-${trendField})`} fill={`var(--color-${trendField})`} fillOpacity={0.15} strokeWidth={1} dot={false} activeDot={{ r: 3 }} connectNulls={false} isAnimationActive={false} />
          </AreaChart>
        </ChartContainer>
      </>}
    </div><p className="mt-3 text-xs text-muted-foreground">{detail}</p>
  </CardContent></Card>
}

function Section({ title, description, children }: { title: string; description: string; children: React.ReactNode }) {
  return <MonitorSection title={title} description={description} panels={Children.count(children)}><div className="monitor-trends">{children}</div></MonitorSection>
}
function Trend({ title, points, series, unit, requestMetric = false }: { title: string; points: MonitorPoint[]; series: { key: Field; label: string }[]; unit: string; requestMetric?: boolean }) {
  const config = Object.fromEntries(series.map((s, i) => [s.key, { label: s.label, color: `var(--chart-${i + 1})` }]))
  const hasData = points.some(p => series.some(s => p[s.key] != null))
  const requestActivity = points.some(p => (p.qps ?? 0) > 0)
  const format = (value: number) => unit.startsWith('bytes') ? bytes(value).replace(' ', '\u00a0') : number(value)
  return <Card><CardHeader><CardTitle>{title}</CardTitle><CardDescription>{unit === 'bytes' ? 'B' : unit === 'bytes/s' ? 'B/s' : unit}</CardDescription></CardHeader><CardContent>
    {hasData ? <ChartContainer config={config} className="h-52 w-full aspect-auto"><LineChart accessibilityLayer data={points} margin={{ left: 0, right: 12, top: 16 }}><CartesianGrid vertical={false} /><XAxis dataKey="timestamp" type="number" domain={['dataMin', 'dataMax']} tickFormatter={clock} minTickGap={45} tickLine={false} axisLine={false} /><YAxis tickFormatter={format} width={80} tickLine={false} axisLine={false} domain={[0, 'auto']} /><ChartTooltip content={<ChartTooltipContent labelFormatter={(_label, payload) => <span data-slot="monitor-tooltip-time">{clock(payload[0]?.payload?.timestamp)}</span>} valueFormatter={value => typeof value === 'number' ? `${format(value)}${unit === '%' ? '%' : unit === 'ms' ? ' ms' : unit === 'bytes/s' ? '/s' : unit === 'req/s' ? ' req/s' : ''}` : '—'} />} /><ChartLegend content={<ChartLegendContent />} />{series.map(s => <Line key={s.key} type="linear" dataKey={s.key} stroke={`var(--color-${s.key})`} strokeWidth={1} dot={false} activeDot={{ r: 3, strokeWidth: 0, fill: `var(--color-${s.key})` }} connectNulls={false} isAnimationActive={false} />)}</LineChart></ChartContainer> : <Empty className="h-52"><EmptyHeader><EmptyTitle>{t(requestMetric && !requestActivity ? 'monitor.noRequestSamples' : 'monitor.noSamples')}</EmptyTitle><EmptyDescription>{t(requestMetric ? requestActivity ? 'monitor.requestSamplesUnavailable' : 'monitor.noRequestSamplesHelp' : 'monitor.noSamplesHelp')}</EmptyDescription></EmptyHeader></Empty>}
  </CardContent></Card>
}
