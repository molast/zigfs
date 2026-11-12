import { formatDateTime } from '@/lib/dateTime'
import { filterAuditLogContent } from './auditLogs'
import { FilterFields } from '@/components/ui/FilterFields'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ApiClient, LogConfig } from '@/api/client'
import type { AuditCategory, AuditOptions, AuditPage, AuditQuery, AuditStatus, StructuredAuditEvent } from '@/types/api'
import { t } from '@/locales'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/Card'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Combobox, ComboboxInput, ComboboxContent, ComboboxList, ComboboxItem, ComboboxEmpty } from '@/components/ui/combobox'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Field, FieldDescription, FieldLabel } from '@/components/ui/field'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/Badge'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet'

const typeKeys = {'api_request': 'audit.typeApiRequest', 'admin_action': 'audit.typeAdminAction', 'security_event': 'audit.typeSecurityEvent', 'system_event': 'audit.typeSystemEvent'} as const
const statusKeys = {'success': 'audit.statusSuccess', 'failure': 'audit.statusFailure', 'denied': 'audit.statusDenied', 'error': 'audit.statusError', 'unknown': 'audit.statusUnknown'} as const
const categoryKeys = {'object_storage': 'audit.categoryObjectStorage', 'identity': 'audit.categoryIdentity', 'access_control': 'audit.categoryAccessControl', 'bucket_management': 'audit.categoryBucketManagement', 'system_management': 'audit.categorySystemManagement', 'kms': 'audit.categoryKms', 'security': 'audit.categorySecurity'} as const

const categories: AuditCategory[] = ['object_storage', 'identity', 'access_control', 'bucket_management', 'system_management', 'kms', 'security']
const statuses: AuditStatus[] = ['success', 'failure', 'denied', 'error', 'unknown']
const defaults = { range: '24h', category: 'all', action: 'all', outcome: 'all', actor: '', bucket: '', request_id: '', source_ip: '', service: 'all', event_type: 'all' }
type Draft = typeof defaults
function queryFor(draft: Draft): AuditQuery {
  return {
    from: draft.range === 'all' ? '0' : String(Math.floor(Date.now() / 1000) - ({ '1h': 3600, '24h': 86400, '7d': 604800, '30d': 2592000 }[draft.range] ?? 86400)),
    category: draft.category === 'all' ? '' : draft.category,
    action: draft.action === 'all' ? '' : draft.action,
    outcome: draft.outcome === 'all' ? '' : draft.outcome,
    actor: draft.actor.trim(), bucket: draft.bucket.trim(), request_id: draft.request_id.trim(), source_ip: draft.source_ip.trim(),
    service: draft.service === 'all' ? '' : draft.service, event_type: draft.event_type === 'all' ? '' : draft.event_type,
  }
}
const categoryLabel = (category: AuditCategory) => t(categoryKeys[category])
const statusLabel = (status: AuditStatus) => t(statusKeys[status])
const targetLabel = (event: StructuredAuditEvent) => event.resource.bucket ? [event.resource.bucket, event.resource.object_key].filter(Boolean).join('/') : event.resource.name || event.request.path

function eventDate(event: StructuredAuditEvent): Date | null {
  // Older ZigFS records formatted signed milliseconds with a leading plus.
  const normalized = event.event_time?.replace(/\.0*\+(\d{1,3})Z$/, (_, digits: string) => `.${digits.padStart(3, '0')}Z`)
  const parsed = Date.parse(normalized ?? '')
  const milliseconds = Number.isFinite(parsed) ? parsed : typeof event.timestamp_unix_seconds === 'number' ? event.timestamp_unix_seconds * 1000 : NaN
  const date = new Date(milliseconds)
  return Number.isFinite(date.getTime()) ? date : null
}

export function LogsView({ api }: { api: ApiClient }) {
  const [logConfig, setLogConfig] = useState<LogConfig | null>(null)
  const [downloading, setDownloading] = useState(false)
  const toast = useToast()
  const configuredDefaults = { ...defaults, range: logConfig?.range ?? defaults.range }
  const [page, setPage] = useState<AuditPage>({ items: [] })
  const [options, setOptions] = useState<AuditOptions | null>(null)
  const [draft, setDraft] = useState(defaults)
  const [applied, setApplied] = useState(defaults)
  const [query, setQuery] = useState<AuditQuery>(() => queryFor(defaults))
  const [cursors, setCursors] = useState([''])
  const [pageSize, setPageSize] = useState(50)
  const [busy, setBusy] = useState(false)
  const [ready, setReady] = useState(false)
  const [selected, setSelected] = useState<StructuredAuditEvent | null>(null)
  const generation = useRef(0)
  const notifyError = useErrorToast()
  const cursor = cursors[cursors.length - 1]
  const loadConfiguration = useCallback(async () => {
    try {
      const config = await api.auditLogSettings()
      setLogConfig(config)
      const next = { ...defaults, range: config.range }
      setDraft(next); setApplied(next); setQuery(queryFor(next)); setCursors([''])
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.logLoadFailed')) }
  }, [api, notifyError])
  useEffect(() => { void loadConfiguration() }, [loadConfiguration])
  const download = async () => {
    setDownloading(true)
    try {
      const filter = queryFor(applied)
      const result = await api.queryAuditLogs(true, { from: Number(filter.from), to: Math.floor(Date.now() / 1000) })
      const content = filterAuditLogContent(result.content, filter)
      const url = URL.createObjectURL(new Blob([content], { type: 'text/plain;charset=utf-8' }))
      const link = document.createElement('a'); link.href = url; link.download = 'zigfs-audit.log'; link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      if (result.truncated) toast(t('settings.logTruncated'))
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.logQueryFailed')) }
    finally { setDownloading(false) }
  }
  const loadOptions = useCallback(async () => {
    try { setOptions(await api.auditOptions()) }
    catch (error) { notifyError(error instanceof Error ? error.message : t('audit.optionsFailed')) }
  }, [api, notifyError])
  useEffect(() => { void loadOptions() }, [loadOptions])
  useEffect(() => {
    if (!logConfig) return
    const current = ++generation.current
    setBusy(true); setReady(false)
    api.listAuditEvents({ ...query, cursor, limit: pageSize }).then(result => {
      if (generation.current === current) { setPage(result); setReady(true) }
    }).catch(error => { if (generation.current === current) notifyError(error instanceof Error ? error.message : t('audit.loadFailed')) })
      .finally(() => { if (generation.current === current) setBusy(false) })
    return () => { generation.current++ }
  }, [api, query, cursor, pageSize, logConfig, notifyError])
  const actions = useMemo(() => [...new Set((options?.operations ?? []).filter(item => (draft.category === 'all' || draft.category === 'security' || item.category === draft.category) && (draft.service === 'all' || item.service === draft.service)).map(item => item.name))].sort(), [options, draft.category, draft.service])
  const all = { value: 'all', label: t('audit.all') }
  const update = (field: keyof Draft, value: string) => setDraft(current => ({ ...current, [field]: value, ...(['category', 'service'].includes(field) ? { action: 'all' } : {}) }))
  const apply = (value: Draft) => { setApplied(value); setQuery(queryFor(value)); setCursors(['']); setSelected(null) }
  const select = (field: keyof Draft, label: string, values: { value: string; label: string }[], disabled = false) => <Field><FieldLabel htmlFor={`audit-${field}`}>{label}</FieldLabel><OptionSelect id={`audit-${field}`} value={draft[field]} onValueChange={value => update(field, value)} options={values} disabled={disabled} /></Field>
  const input = (field: keyof Draft, label: string) => <Field><FieldLabel htmlFor={`audit-${field}`}>{label}</FieldLabel><Input id={`audit-${field}`} value={draft[field]} onChange={event => update(field, event.target.value)} placeholder={t('audit.exactMatch')} /></Field>
  return <section className="settings-detail-stack" aria-busy={busy}>
    <Card>
      <CardHeader><CardTitle>{t('navigation.logs')}</CardTitle><CardDescription>{t('audit.description')}</CardDescription></CardHeader>
      <CardContent className="flex flex-col gap-4">
        <form onSubmit={event => { event.preventDefault(); apply(draft) }} className="flex flex-col gap-4">
          <FilterFields>
            {select('category', t('audit.category'), [all, ...categories.map(value => ({ value, label: categoryLabel(value) }))])}
            <Field><FieldLabel htmlFor="audit-action">{t('audit.action')}</FieldLabel><Combobox items={['all', ...actions]} value={draft.action} onValueChange={value => update('action', value ?? 'all')} itemToStringLabel={value => value === 'all' ? t('audit.all') : value} disabled={!options}><ComboboxInput id="audit-action" placeholder={t('audit.searchOperation')} disabled={!options} /><ComboboxContent><ComboboxEmpty>{t('audit.noOperations')}</ComboboxEmpty><ComboboxList>{(value: string) => <ComboboxItem key={value} value={value}>{value === 'all' ? t('audit.all') : value}</ComboboxItem>}</ComboboxList></ComboboxContent></Combobox></Field>
            {select('outcome', t('audit.outcome'), [all, ...statuses.map(value => ({ value, label: statusLabel(value) }))])}
            {select('range', t('audit.range'), [all, { value: '1h', label: t('audit.lastHour') }, { value: '24h', label: t('audit.lastDay') }, { value: '7d', label: t('audit.lastWeek') }, { value: '30d', label: t('settings.logLastMonth') }])}
            {select('service', t('audit.service'), [all, ...['s3', 'admin', 'kms', 'sts'].map(value => ({ value, label: value.toUpperCase() }))])}
            {input('actor', t('audit.actor'))}
            {input('bucket', t('audit.bucket'))}
            {input('request_id', t('audit.requestId'))}
            {input('source_ip', t('audit.sourceIp'))}
            {select('event_type', t('audit.eventType'), [all, ...(['api_request', 'admin_action', 'security_event', 'system_event'] as const).map(value => ({ value, label: t(typeKeys[value]) }))])}
          </FilterFields>
          <div className="flex flex-wrap justify-end gap-2"><Button type="submit" disabled={busy}>{t('audit.apply')}</Button><Button type="button" variant="outline" disabled={busy} onClick={() => { setDraft(configuredDefaults); apply(configuredDefaults) }}>{t('audit.reset')}</Button><Button type="button" variant="outline" disabled={busy} onClick={() => { apply(applied); if (!options) void loadOptions(); if (!logConfig) void loadConfiguration() }}>{t('audit.refresh')}</Button><Button type="button" variant="outline" disabled={downloading || logConfig?.downloads !== 'enabled'} onClick={() => void download()}>{t('settings.logDownload')}</Button></div>
        </form>
        <Table>
          <TableHeader><TableRow>{(['time', 'category', 'action', 'actor', 'target', 'outcome', 'duration', 'details'] as const).map(key => <TableHead key={key}>{t(`audit.${key}`)}</TableHead>)}</TableRow></TableHeader>
          <TableBody>
            {ready && page.items.map((event, index) => <TableRow key={`${event.event_id}-${index}`}>
              <TableCell className="whitespace-nowrap">{formatDateTime(eventDate(event))}</TableCell>
              <TableCell className="whitespace-nowrap">{categoryLabel(event.event_category)}</TableCell>
              <TableCell>{event.event_action}</TableCell><TableCell>{event.identity.principal_name || t('audit.anonymous')}</TableCell>
              <TableCell className="max-w-64 break-all whitespace-normal">{targetLabel(event)}</TableCell>
              <TableCell><Badge variant={['failure', 'denied', 'error'].includes(event.response.status) ? 'destructive' : 'default'}>{statusLabel(event.response.status)}{event.response.http_status ? ` (${event.response.http_status})` : ''}</Badge></TableCell>
              <TableCell className="whitespace-nowrap">{event.metadata.legacy ? '—' : t('audit.milliseconds', { value: event.response.duration_ms })}</TableCell>
              <TableCell><Button variant="ghost" size="sm" onClick={() => setSelected(event)}>{t('audit.details')}</Button></TableCell>
            </TableRow>)}
            {ready && page.items.length === 0 && <TableRow><TableCell colSpan={8}>{t('audit.empty')}</TableCell></TableRow>}
          </TableBody>
        </Table>
      </CardContent>
      <CardFooter className="flex flex-wrap justify-between gap-4">
        <div className="flex items-center gap-2">
          <FieldLabel htmlFor="audit-page-size">{t('audit.rowsPerPage')}</FieldLabel>
          <OptionSelect id="audit-page-size" value={String(pageSize)} disabled={busy} onValueChange={value => { setPageSize(Number(value)); setCursors(['']); setSelected(null) }} options={[10, 25, 50, 100].map(value => ({ value: String(value), label: String(value) }))} />
        </div>
        <nav aria-label={t('ui.pagination')} className="flex flex-wrap items-center gap-2">
          <CardDescription aria-live="polite">{t('audit.pageNumber', { page: cursors.length })}{ready ? ` · ${t('audit.pageItems', { count: page.items.length })}` : ''}</CardDescription>
          <Button variant="outline" size="sm" disabled={busy || cursors.length === 1} onClick={() => setCursors([''])}>{t('common.first')}</Button>
          <Button variant="outline" size="sm" disabled={busy || cursors.length === 1} onClick={() => setCursors(current => current.slice(0, -1))}>{t('audit.previous')}</Button>
          <Button variant="outline" size="sm" disabled={busy || !ready || !page.next_cursor} onClick={() => setCursors(current => [...current, page.next_cursor!])}>{t('audit.next')}</Button>
        </nav>
      </CardFooter>
    </Card>
    <AuditDetails event={selected} onClose={() => setSelected(null)} />
  </section>
}

function AuditDetails({ event, onClose }: { event: StructuredAuditEvent | null; onClose: () => void }) {
  const section = (title: string, rows: [string, string | number | boolean | null | undefined][]) => <Card><CardHeader><CardTitle>{title}</CardTitle></CardHeader><CardContent><dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-3">{rows.map(([label, value]) => <div key={label} className="contents"><dt>{label}</dt><dd className="min-w-0 break-all whitespace-pre-wrap">{value == null || value === '' ? '—' : typeof value === 'boolean' ? value ? t('audit.yes') : t('audit.no') : String(value)}</dd></div>)}</dl></CardContent></Card>
  return <Sheet open={!!event} onOpenChange={open => { if (!open) onClose() }}><SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
    <SheetHeader><SheetTitle>{t('audit.details')}</SheetTitle><SheetDescription>{event?.event_action}</SheetDescription></SheetHeader>
    {event && <div className="flex flex-col gap-4 px-4 pb-4">
      {event.metadata.legacy && <FieldDescription>{t('audit.legacyNotice')}</FieldDescription>}
      {section(t('audit.event'), [[t('audit.eventId'), event.event_id], [t('audit.schemaVersion'), event.schema_version], [t('audit.time'), formatDateTime(eventDate(event))], [t('audit.category'), categoryLabel(event.event_category)], [t('audit.eventType'), event.event_type]])}
      {section(t('audit.request'), [[t('audit.requestId'), event.request.request_id], [t('audit.method'), event.request.method], [t('audit.protocol'), event.request.protocol], [t('audit.path'), event.request.path], [t('audit.sourceIp'), event.request.source_ip], [t('audit.userAgent'), event.request.user_agent], [t('audit.query'), JSON.stringify(Object.fromEntries(Object.entries(event.request.query).filter(([, value]) => value != null)), null, 2)]])}
      {section(t('audit.identity'), [[t('audit.authType'), event.identity.auth_type], [t('audit.principalId'), event.identity.principal_id], [t('audit.actor'), event.identity.principal_name], [t('audit.accessKeyId'), event.identity.access_key_id], [t('audit.sessionId'), event.identity.session_id]])}
      {section(t('audit.resource'), [[t('audit.resourceType'), event.resource.type], [t('audit.bucket'), event.resource.bucket], [t('audit.objectKey'), event.resource.object_key], [t('audit.versionId'), event.resource.version_id], [t('audit.resourceName'), event.resource.name]])}
      {section(t('audit.operation'), [[t('audit.action'), event.operation.name], [t('audit.service'), event.operation.service], [t('audit.readOnly'), event.operation.is_read_only]])}
      {section(t('audit.response'), [[t('audit.outcome'), statusLabel(event.response.status)], [t('audit.httpStatus'), event.response.http_status || null], [t('audit.errorCode'), event.response.error_code], [t('audit.errorMessage'), event.response.error_message], [t('audit.duration'), event.metadata.legacy ? null : t('audit.milliseconds', { value: event.response.duration_ms })]])}
      {section(t('audit.metadata'), [[t('audit.region'), event.metadata.region], [t('audit.serverId'), event.metadata.server_id]])}
    </div>}
  </SheetContent></Sheet>
}
