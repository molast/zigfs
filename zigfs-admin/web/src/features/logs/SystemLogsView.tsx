import { browserTimezone, formatDateTime, formatTime } from '@/lib/dateTime'
import { useEffect, useMemo, useState } from 'react'
import { Bar, BarChart, CartesianGrid, XAxis, YAxis } from 'recharts'
import { Download, Play, Copy } from 'lucide-react'
import type { ApiClient, LogConfig, LogQuery } from '@/api/client'
import { t } from '@/locales'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from '@/components/ui/Card'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Badge } from '@/components/ui/Badge'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Switch } from '@/components/ui/switch'
import { Table, TableHeader, TableHead, TableRow, TableBody, TableCell } from '@/components/ui/table'
import { Sheet, SheetHeader, SheetTitle, SheetDescription, SheetContent } from '@/components/ui/sheet'
import { ChartContainer, ChartTooltip, ChartTooltipContent, ChartLegend, ChartLegendContent } from '@/components/ui/chart'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { Textarea } from '@/components/ui/Textarea'
import { parseSystemLogs, filterSystemLogs, logHistogram, logLevels, type SystemLog } from './systemLogs'

const defaults = { range: '1h', from: '', to: '', level: 'all', component: 'all', source: 'all', keyword: '' }
type Filters = typeof defaults
function timeRange(filters: Filters) {
  const to = filters.range === 'custom' ? Math.floor(Date.parse(filters.to) / 1000) : Math.floor(Date.now() / 1000)
  const from = filters.range === 'custom' ? Math.floor(Date.parse(filters.from) / 1000) : to - ({ '5m': 300, '15m': 900, '1h': 3600, '24h': 86400 }[filters.range] ?? 3600)
  return { from, to }
}
const chartConfig = {
  ERROR: { label: 'ERROR', color: 'var(--destructive)' }, WARN: { label: 'WARN', color: 'var(--chart-4)' }, INFO: { label: 'INFO', color: 'var(--chart-2)' },
  DEBUG: { label: 'DEBUG', color: 'var(--chart-3)' }, TRACE: { label: 'TRACE', color: 'var(--chart-5)' }, UNKNOWN: { label: 'UNKNOWN', color: 'var(--muted-foreground)' },
}

export function SystemLogsView({ api }: { api: ApiClient }) {
  const [draft, setDraft] = useState(defaults)
  const [applied, setApplied] = useState(defaults)
  const [reload, setReload] = useState(0)
  const [live, setLive] = useState(false)
  const [busy, setBusy] = useState(false)
  const [downloading, setDownloading] = useState(false)
  const [data, setData] = useState<{ query: LogQuery; config: LogConfig; range: { from: number; to: number } } | null>(null)
  const [selected, setSelected] = useState<SystemLog | null>(null)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(50)
  const [oldest, setOldest] = useState(false)
  const [wrap, setWrap] = useState(false)
  const notifyError = useErrorToast()
  const toast = useToast()
  useEffect(() => {
    let disposed = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const load = async () => {
      if (disposed) return
      if (document.hidden && live) { timer = setTimeout(load, 5000); return }
      setBusy(true)
      try {
        const range = timeRange(applied)
        const [query, config] = await Promise.all([api.queryLogs(false, range), api.logSettings()])
        if (!disposed) setData({ query, config, range })
      } catch (error) {
        if (!disposed) { notifyError(error instanceof Error ? error.message : t('systemLogs.loadFailed')); setLive(false) }
      } finally {
        if (!disposed) {
          setBusy(false)
          if (live) timer = setTimeout(load, 5000)
        }
      }
    }
    void load()
    return () => { disposed = true; clearTimeout(timer) }
  }, [api, applied, reload, live, notifyError])
  const logs = useMemo(() => parseSystemLogs(data?.query.content ?? ''), [data])
  const filtered = useMemo(() => filterSystemLogs(logs, applied).sort((a, b) => ((Date.parse(a.timestamp ?? '') || 0) - (Date.parse(b.timestamp ?? '') || 0)) * (oldest ? 1 : -1)), [logs, applied, oldest])
  const histogram = useMemo(() => data ? logHistogram(filtered, data.range.from, data.range.to) : [], [filtered, data])
  const pages = Math.max(1, Math.ceil(filtered.length / pageSize))
  const current = Math.min(page, pages)
  const visible = filtered.slice((current - 1) * pageSize, current * pageSize)
  const components = [...new Set(['api', 'auth', 'iam', 'storage', 'network', 'kms', 'observability', 'server', ...logs.map(log => log.source.component)])].sort()
  const sources = [...new Set(['application', ...logs.map(log => log.source.type)])]
  const update = (key: keyof Filters, value: string) => setDraft(previous => ({ ...previous, [key]: value }))
  const all = { value: 'all', label: t('audit.all') }
  const select = (key: keyof Filters, label: string, options: { value: string; label: string }[]) => <Field><FieldLabel htmlFor={`system-log-${key}`}>{label}</FieldLabel><OptionSelect id={`system-log-${key}`} value={draft[key]} onValueChange={value => update(key, value)} options={options} /></Field>
  const apply = () => {
    const range = timeRange(draft)
    if (!Number.isFinite(range.from) || !Number.isFinite(range.to) || range.from < 0 || range.to < range.from) { notifyError(t('systemLogs.invalidRange')); return }
    setData(null); setApplied({ ...draft }); setPage(1); setSelected(null)
    if (draft.range === 'custom') setLive(false)
  }
  const download = async () => {
    if (!data) return
    setDownloading(true)
    try {
      // Fetch through the download endpoint so ZigFS enforces download permissions.
      const result = await api.queryLogs(true, data.range)
      const content = filterSystemLogs(parseSystemLogs(result.content), applied).map(({ raw: _raw, ...log }) => JSON.stringify(log)).join('\n')
      const url = URL.createObjectURL(new Blob([content], { type: 'application/x-ndjson' }))
      const link = document.createElement('a'); link.href = url; link.download = 'zigfs-system-logs.jsonl'; link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      if (result.truncated) toast(t('systemLogs.downloadTruncated'))
    } catch (error) { notifyError(error instanceof Error ? error.message : t('systemLogs.downloadFailed')) }
    finally { setDownloading(false) }
  }
  const copy = async () => {
    if (!selected) return
    try { await navigator.clipboard.writeText(selected.raw); toast(t('common.copied')) }
    catch { notifyError(t('systemLogs.copyFailed')) }
  }
  return <section className="flex flex-col gap-4">
    <Card>
      <CardHeader><CardTitle>{t('systemLogs.title')}</CardTitle><CardDescription>{t('systemLogs.description')}</CardDescription></CardHeader>
      <CardContent>
        <form className="flex flex-col gap-4" onSubmit={event => { event.preventDefault(); apply() }}>
          <FieldGroup density="compact" className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
            {select('range', t('audit.range'), [{ value: '5m', label: t('systemLogs.last5m') }, { value: '15m', label: t('systemLogs.last15m') }, { value: '1h', label: t('audit.lastHour') }, { value: '24h', label: t('audit.lastDay') }, { value: 'custom', label: t('systemLogs.custom') }])}
            {select('level', t('systemLogs.level'), [all, ...logLevels.map(value => ({ value, label: value }))])}
            {select('component', t('systemLogs.component'), [all, ...components.map(value => ({ value, label: value }))])}
            {select('source', t('systemLogs.source'), [all, ...sources.map(value => ({ value, label: value }))])}
            <Field><FieldLabel htmlFor="system-log-keyword">{t('systemLogs.keyword')}</FieldLabel><Input id="system-log-keyword" value={draft.keyword} onChange={event => update('keyword', event.target.value)} placeholder={t('systemLogs.searchPlaceholder')} /></Field>
            {draft.range === 'custom' && <><Field><FieldLabel htmlFor="system-log-from">{t('systemLogs.from')} ({browserTimezone()})</FieldLabel><Input id="system-log-from" type="datetime-local" value={draft.from} onChange={event => update('from', event.target.value)} /></Field><Field><FieldLabel htmlFor="system-log-to">{t('systemLogs.to')} ({browserTimezone()})</FieldLabel><Input id="system-log-to" type="datetime-local" value={draft.to} onChange={event => update('to', event.target.value)} /></Field></>}
          </FieldGroup>
          <div className="flex flex-wrap items-center justify-end gap-2">
            <Field orientation="horizontal" className="w-auto"><Switch id="system-log-live" checked={live} disabled={applied.range === 'custom'} onCheckedChange={value => { setLive(value); setPage(1) }} /><FieldLabel htmlFor="system-log-live">{t('systemLogs.live')}</FieldLabel></Field>
            <Button type="submit" disabled={busy}><Play data-icon="inline-start" />{t('systemLogs.run')}</Button>
            <Button type="button" variant="outline" disabled={busy} onClick={() => { setData(null); setDraft(defaults); setApplied({ ...defaults }); setPage(1) }}>{t('audit.reset')}</Button>
            <Button type="button" variant="outline" disabled={busy} onClick={() => setReload(value => value + 1)}>{t('audit.refresh')}</Button>
          </div>
        </form>
        {data?.config.output === 'console' && <FieldDescription className="mt-3">{t('systemLogs.consoleOnly')}</FieldDescription>}
        {data?.query.truncated && <FieldDescription className="mt-3">{t('systemLogs.truncated')}</FieldDescription>}
      </CardContent>
    </Card>
    <Card>
      <CardHeader><CardTitle>{t('systemLogs.volume')}</CardTitle><CardDescription>{t('systemLogs.counts', { total: filtered.length, errors: filtered.filter(log => log.level === 'ERROR').length, warnings: filtered.filter(log => log.level === 'WARN').length })}</CardDescription></CardHeader>
      <CardContent><ChartContainer config={chartConfig} className="h-52 w-full"><BarChart data={histogram} accessibilityLayer><CartesianGrid vertical={false} /><XAxis dataKey="timestamp" tickFormatter={value => formatTime(value)} minTickGap={45} /><YAxis allowDecimals={false} width={32} /><ChartTooltip content={<ChartTooltipContent labelFormatter={value => formatDateTime(Number(value))} />} /><ChartLegend content={<ChartLegendContent />} />{logLevels.map(level => <Bar key={level} dataKey={level} stackId="logs" fill={`var(--color-${level})`} isAnimationActive={false} />)}</BarChart></ChartContainer></CardContent>
    </Card>
    <Card>
      <CardHeader><CardTitle>{t('systemLogs.entries')}</CardTitle>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <Field orientation="horizontal" className="w-auto"><Switch id="system-log-wrap" checked={wrap} onCheckedChange={setWrap} /><FieldLabel htmlFor="system-log-wrap">{t('systemLogs.wrap')}</FieldLabel></Field>
          <div className="flex gap-2"><OptionSelect aria-label={t('systemLogs.order')} value={oldest ? 'oldest' : 'newest'} onValueChange={value => { setOldest(value === 'oldest'); setPage(1) }} options={[{ value: 'newest', label: t('systemLogs.newest') }, { value: 'oldest', label: t('systemLogs.oldest') }]} /><Button variant="outline" disabled={!data || downloading || data.config.downloads !== 'enabled'} onClick={() => void download()}><Download data-icon="inline-start" />{t('systemLogs.download')}</Button></div>
        </div>
      </CardHeader>
      <CardContent className="[&_[data-slot=table-container]]:max-h-[32rem] [&_[data-slot=table-container]]:overflow-auto"><Table><TableHeader><TableRow>{(['time', 'level', 'service', 'component', 'message', 'correlation'] as const).map(key => <TableHead key={key}>{t(`systemLogs.${key}`)}</TableHead>)}<TableHead>{t('audit.details')}</TableHead></TableRow></TableHeader>
        <TableBody>{visible.map((log, index) => <TableRow key={`${current}-${index}`}>
          <TableCell className="whitespace-nowrap">{log.timestamp ? formatDateTime(log.timestamp) : '—'}</TableCell>
          <TableCell><Badge variant={log.level === 'ERROR' ? 'destructive' : 'default'}>{log.level}</Badge></TableCell>
          <TableCell><div>{log.service.name}</div><FieldDescription>{log.service.instance_id ?? '—'}</FieldDescription></TableCell><TableCell>{log.source.component}</TableCell>
          <TableCell className="max-w-lg"><div className={wrap ? 'font-mono whitespace-pre-wrap break-all' : 'font-mono truncate'}>{log.message}</div></TableCell>
          <TableCell className="max-w-40 truncate">{log.context.request_id || log.context.trace_id || '—'}</TableCell>
          <TableCell><Button variant="ghost" size="sm" onClick={() => setSelected(log)}>{t('audit.details')}</Button></TableCell>
        </TableRow>)}{visible.length === 0 && <TableRow><TableCell colSpan={7}>{busy ? t('systemLogs.loading') : t('systemLogs.empty')}</TableCell></TableRow>}</TableBody>
      </Table></CardContent>
      <CardFooter className="flex flex-wrap justify-between gap-3"><div className="flex items-center gap-2"><FieldLabel htmlFor="system-log-page-size">{t('audit.rowsPerPage')}</FieldLabel><OptionSelect id="system-log-page-size" value={String(pageSize)} onValueChange={value => { setPageSize(Number(value)); setPage(1) }} options={[10, 25, 50, 100].map(value => ({ value: String(value), label: String(value) }))} /></div><nav aria-label={t('ui.pagination')} className="flex flex-wrap items-center gap-2"><CardDescription>{t('common.pagination', { page: current, total: pages })}</CardDescription><Button variant="outline" size="sm" disabled={current === 1} onClick={() => setPage(1)}>{t('common.first')}</Button><Button variant="outline" size="sm" disabled={current === 1} onClick={() => setPage(current - 1)}>{t('audit.previous')}</Button><Button variant="outline" size="sm" disabled={current === pages} onClick={() => setPage(current + 1)}>{t('audit.next')}</Button></nav></CardFooter>
    </Card>
    <Sheet open={!!selected} onOpenChange={open => { if (!open) setSelected(null) }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
        <SheetHeader><SheetTitle>{t('systemLogs.details')}</SheetTitle><SheetDescription>{formatDateTime(selected?.timestamp)}</SheetDescription></SheetHeader>
        {selected && <div className="flex flex-col gap-4 px-4 pb-4">
          <Field><FieldLabel>{t('systemLogs.message')}</FieldLabel><pre className="whitespace-pre-wrap break-all">{selected.message}</pre></Field>
          {selected.error && <Card><CardHeader><CardTitle>{t('systemLogs.errorDetails')}</CardTitle></CardHeader><CardContent className="flex flex-col gap-3">
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2">
              <dt>{t('systemLogs.errorCode')}</dt><dd className="break-all">{selected.error.code ?? '—'}</dd>
              <dt>{t('systemLogs.errorType')}</dt><dd>{selected.error.type ?? '—'}</dd>
              <dt>{t('systemLogs.sourceLocation')}</dt><dd className="break-all">{selected.source.file ? `${selected.source.file}:${selected.source.line ?? ''}` : '—'}{selected.source.function ? ` (${selected.source.function})` : ''}</dd>
            </dl>
            <Field><FieldLabel>{t('systemLogs.stackTrace')}</FieldLabel>
              {selected.error.stack_trace ? <><FieldDescription>{selected.error.trace_kind === 'error_return' ? t('systemLogs.errorReturnTrace') : selected.error.trace_kind === 'reporting_site' ? t('systemLogs.reportingTrace') : t('systemLogs.recordedTrace')}</FieldDescription><pre data-testid="system-log-stack" className="max-h-96 overflow-auto whitespace-pre-wrap break-all">{selected.error.stack_trace}</pre></> : <FieldDescription>{t('systemLogs.noStack')}</FieldDescription>}
            </Field>
          </CardContent></Card>}
          <Collapsible><CollapsibleTrigger asChild><Button variant="outline" size="sm">{t('systemLogs.normalized')}</Button></CollapsibleTrigger><CollapsibleContent className="pt-2"><Textarea aria-label={t('systemLogs.normalized')} id="system-log-normalized" readOnly rows={20} value={JSON.stringify(Object.fromEntries(Object.entries(selected).filter(([key]) => key !== 'raw')), null, 2)} /></CollapsibleContent></Collapsible>
          <Collapsible><CollapsibleTrigger asChild><Button variant="outline" size="sm">{t('systemLogs.raw')}</Button></CollapsibleTrigger><CollapsibleContent className="pt-2"><Textarea aria-label={t('systemLogs.raw')} id="system-log-raw" readOnly rows={8} value={selected.raw} /></CollapsibleContent></Collapsible>
          <Button variant="outline" onClick={() => void copy()}><Copy data-icon="inline-start" />{t('systemLogs.copy')}</Button>
        </div>}
      </SheetContent>
    </Sheet>
  </section>
}
