import { useState } from 'react'
import type { ApiClient } from '@/api/client'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { Button } from '@/components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/Card'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/Dialog'
import { Input } from '@/components/ui/Input'
import { Field, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Switch } from '@/components/ui/switch'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { getFormatLocale, t } from '@/locales'
import type { Monitoring, MonitorDiagnosticDetails, MonitorDiagnosticInput, MonitorRule, MonitorRuleId, MonitorSeverity } from '@/types/api'
import { MonitorSection } from './MonitorSection'
import { formatMonitorBytes } from './monitoring'

const ruleKeys: Record<MonitorRuleId, Parameters<typeof t>[0]> = {
  cpu_high: 'monitor.cpuRule', rss_high: 'monitor.rssRule', heap_growth: 'monitor.heapRule', fd_growth: 'monitor.fdGrowthRule', fd_high: 'monitor.fdRule', storage_low: 'monitor.storageRule', thread_high: 'monitor.threadRule', api_errors: 'monitor.errorsRule', api_latency: 'monitor.latencyRule', allocation_failure: 'monitor.failureRule',
}
const trendKeys = { insufficient: 'monitor.trendInsufficient', stable: 'monitor.trendStable', growing: 'monitor.trendGrowing' } as const
const severityKeys = { info: 'monitor.severityInfo', warning: 'monitor.severityWarning', err: 'monitor.severityError', critical: 'monitor.severityCritical' } as const
const lockKeys = { metadata: 'monitor.lockMetadata', identity: 'monitor.lockIdentity' } as const
const stateKeys = { disabled: 'monitor.alertDisabled', no_data: 'monitor.alertNoData', normal: 'monitor.alertNormal', pending: 'monitor.alertPending', firing: 'monitor.alertFiring' } as const
const counterKeys = { user_cpu_seconds: 'monitor.userCpuSeconds', kernel_cpu_seconds: 'monitor.kernelCpuSeconds', allocated_bytes: 'monitor.allocatedBytes', freed_bytes: 'monitor.freedBytes', reallocations: 'monitor.reallocations' } as const
const num = (value: number | null | undefined) => value == null ? '—' : value.toLocaleString(getFormatLocale(), { maximumFractionDigits: 2 })
const bytes = (value: number | null | undefined) => formatMonitorBytes(value, getFormatLocale())

export function PerformanceDiagnostics({ api, snapshot, readOnly, refresh }: { api: ApiClient; snapshot: Monitoring; readOnly: boolean; refresh: () => void }) {
  const [draft, setDraft] = useState<MonitorRule[] | null>(null)
  const [details, setDetails] = useState<MonitorDiagnosticDetails | null>(null)
  const [busy, setBusy] = useState(false)
  const errorToast = useErrorToast()
  const toast = useToast()
  const update = async (input?: MonitorDiagnosticInput) => {
    setBusy(true)
    try {
      setDetails(input ? await api.updateMonitoringDiagnostics(input) : await api.monitoringDiagnostics())
      if (input) { toast(t('monitor.diagnosticsSaved')); refresh() }
      if (input?.rules) setDraft(null)
    } catch { errorToast(t('monitor.diagnosticsError')) } finally { setBusy(false) }
  }
  const save = () => {
    if (!draft || draft.some(rule => !Number.isFinite(rule.threshold) || rule.threshold < 0 || rule.threshold > 1e15 || !Number.isInteger(rule.duration_seconds) || rule.duration_seconds < 0 || rule.duration_seconds > 3600 || (['cpu_high', 'fd_high', 'storage_low', 'api_errors'].includes(rule.id) && rule.threshold > 100))) {
      errorToast(t('monitor.invalidRules')); return
    }
    void update({ rules: draft })
  }
  const change = (index: number, patch: Partial<MonitorRule>) => setDraft(current => current?.map((rule, i) => i === index ? { ...rule, ...patch } : rule) ?? null)
  return <>
    <MonitorSection title={t('monitor.growthTitle')} panels={1}>
    <Card>
      <CardHeader><CardTitle>{t('monitor.growthTitle')}</CardTitle><CardDescription>{t('monitor.growthHelp')}</CardDescription></CardHeader>
      <CardContent><Table><TableHeader><TableRow>{['resource', 'trendState', 'evidence', 'delta', 'perHour'].map(key => <TableHead key={key}>{t(`monitor.${key}` as Parameters<typeof t>[0])}</TableHead>)}</TableRow></TableHeader><TableBody>
        {(['rss', 'heap', 'descriptors', 'allocations'] as const).map(key => { const trend = snapshot.analysis[key]; const format = (n: number | null) => key === 'rss' || key === 'heap' ? n == null ? '—' : `${n < 0 ? '−' : ''}${bytes(Math.abs(n))}` : num(n); return <TableRow key={key}><TableCell>{t(`monitor.${key}`)}</TableCell><TableCell>{t(trendKeys[trend.status])}</TableCell><TableCell>{t('monitor.evidenceValue', { samples: trend.samples, seconds: trend.seconds })}</TableCell><TableCell>{format(trend.delta)}</TableCell><TableCell>{format(trend.per_hour)}</TableCell></TableRow> })}
      </TableBody></Table></CardContent>
    </Card>
    </MonitorSection>
    <MonitorSection title={t('monitor.alertsTitle')} panels={1} attention={snapshot.alerts.filter(alert => alert.state === 'firing').length}>
    <Card>
      <CardHeader><CardTitle>{t('monitor.alertsTitle')}</CardTitle><CardDescription>{t('monitor.alertsHelp')}</CardDescription>{!readOnly && <Button variant="outline" size="sm" onClick={() => setDraft(snapshot.alert_rules.map(rule => ({ ...rule })))}>{t('monitor.editRules')}</Button>}</CardHeader>
      <CardContent><Table><TableHeader><TableRow><TableHead>{t('monitor.rule')}</TableHead><TableHead>{t('monitor.severity')}</TableHead><TableHead>{t('monitor.trendState')}</TableHead><TableHead>{t('monitor.currentValue')}</TableHead><TableHead>{t('monitor.threshold')}</TableHead><TableHead>{t('monitor.acknowledgement')}</TableHead></TableRow></TableHeader><TableBody>
        {snapshot.alerts.map(alert => { const rule = snapshot.alert_rules.find(rule => rule.id === alert.id)!; return <TableRow key={alert.id}><TableCell>{t(ruleKeys[alert.id])}</TableCell><TableCell>{t(severityKeys[rule.severity])}</TableCell><TableCell>{t(stateKeys[alert.state])}</TableCell><TableCell>{num(alert.value)}</TableCell><TableCell>{num(rule.threshold)}</TableCell><TableCell>{alert.acknowledged ? t('monitor.acknowledged') : alert.state === 'firing' && !readOnly ? <Button size="sm" variant="outline" disabled={busy} onClick={() => void update({ acknowledge: alert.id })}>{t('monitor.acknowledge')}</Button> : '—'}</TableCell></TableRow> })}
      </TableBody></Table>
      <details className="mt-4"><summary>{t('monitor.alertHistory')}</summary><Table><TableHeader><TableRow><TableHead>{t('monitor.eventTime')}</TableHead><TableHead>{t('monitor.rule')}</TableHead><TableHead>{t('monitor.severity')}</TableHead><TableHead>{t('monitor.trendState')}</TableHead></TableRow></TableHeader><TableBody>{[...snapshot.alert_events].reverse().map((event, i) => <TableRow key={i}><TableCell>{new Date(event.timestamp * 1000).toLocaleString(getFormatLocale())}</TableCell><TableCell>{t(ruleKeys[event.id])}</TableCell><TableCell>{t(severityKeys[event.severity])}</TableCell><TableCell>{t(stateKeys[event.state])}</TableCell></TableRow>)}{!snapshot.alert_events.length && <TableRow><TableCell colSpan={4}>{t('monitor.noEvents')}</TableCell></TableRow>}</TableBody></Table></details>
      </CardContent>
    </Card>
    </MonitorSection>
    <MonitorSection title={t('monitor.locksTitle')} panels={1}>
    <Card><CardHeader><CardTitle>{t('monitor.locksTitle')}</CardTitle><CardDescription>{t('monitor.locksHelp')}</CardDescription></CardHeader><CardContent><Table><TableHeader><TableRow>{(['lockName', 'acquisitions', 'contentions', 'waiters', 'waitTotal', 'waitMax'] as const).map(key => <TableHead key={key}>{t(`monitor.${key}`)}</TableHead>)}</TableRow></TableHeader><TableBody>{(['metadata', 'identity'] as const).map(key => { const lock = snapshot.locks[key]; return <TableRow key={key}><TableCell>{t(lockKeys[key])}</TableCell><TableCell>{num(lock.acquisitions)}</TableCell><TableCell>{num(lock.contentions)}</TableCell><TableCell>{num(lock.waiters)}</TableCell><TableCell>{num(lock.wait_ns / 1e6)}</TableCell><TableCell>{num(lock.max_wait_ns / 1e6)}</TableCell></TableRow> })}</TableBody></Table></CardContent></Card>
    </MonitorSection>
    <MonitorSection title={t('monitor.allocatorTitle')} panels={1}>
    <Card><CardHeader><CardTitle>{t('monitor.allocatorTitle')}</CardTitle><CardDescription>{t('monitor.hotspotsHelp')}</CardDescription></CardHeader><CardContent className="flex flex-col gap-4">
      <dl className="grid grid-cols-2 gap-4 lg:grid-cols-5">{(['user_cpu_seconds', 'kernel_cpu_seconds', 'allocated_bytes', 'freed_bytes', 'reallocations'] as const).map(key => <div key={key}><dt>{t(counterKeys[key])}</dt><dd>{key.endsWith('_bytes') ? bytes(snapshot.latest?.[key]) : num(snapshot.latest?.[key])}</dd></div>)}</dl>
      {!readOnly && <><div className="flex flex-wrap items-center gap-3"><Button variant="outline" size="sm" disabled={busy} onClick={() => void update()}>{t('monitor.loadHotspots')}</Button>{details && <Field orientation="horizontal"><Switch id="monitor-hotspots" checked={details.hotspots_enabled} disabled={busy} onCheckedChange={value => void update({ hotspots_enabled: value })} /><FieldLabel htmlFor="monitor-hotspots">{t('monitor.enableHotspots')}</FieldLabel></Field>}</div>
      {details && <><p className="break-all">{t('monitor.hotspotBuild', { build: details.build_commit, count: details.untracked_allocations })}</p><Table><TableHeader><TableRow><TableHead>{t('monitor.address')}</TableHead><TableHead>{t('monitor.allocations')}</TableHead><TableHead>{t('monitor.allocatedBytes')}</TableHead></TableRow></TableHeader><TableBody>{(details.hotspots ?? []).filter(site => site.address !== 0).sort((a, b) => b.bytes - a.bytes).map(site => <TableRow key={site.address}><TableCell><code>{`0x${site.address.toString(16)}`}</code></TableCell><TableCell>{num(site.allocations)}</TableCell><TableCell>{bytes(site.bytes)}</TableCell></TableRow>)}{!(details.hotspots ?? []).some(site => site.address !== 0) && <TableRow><TableCell colSpan={3}>{t('monitor.noHotspots')}</TableCell></TableRow>}</TableBody></Table></>}
      </>}
    </CardContent></Card>
    </MonitorSection>
    <Dialog open={draft !== null} onOpenChange={open => { if (!open && !busy) setDraft(null) }}><DialogContent layout="form"><DialogHeader><DialogTitle>{t('monitor.editRules')}</DialogTitle><DialogDescription>{t('monitor.rulesHelp')}</DialogDescription></DialogHeader><div className="max-h-[60vh] overflow-y-auto"><FieldGroup>{draft?.map((rule, index) => <FieldGroup key={rule.id}><Field orientation="horizontal"><Switch id={`rule-${rule.id}`} checked={rule.enabled} disabled={busy} onCheckedChange={enabled => change(index, { enabled })} /><FieldLabel htmlFor={`rule-${rule.id}`}>{t(ruleKeys[rule.id])}</FieldLabel></Field><Field><FieldLabel htmlFor={`threshold-${rule.id}`}>{t('monitor.threshold')}</FieldLabel><Input id={`threshold-${rule.id}`} type="number" min={0} disabled={busy} value={Number.isNaN(rule.threshold) ? '' : rule.threshold} onChange={event => change(index, { threshold: event.target.value === '' ? NaN : Number(event.target.value) })} /></Field><Field><FieldLabel htmlFor={`duration-${rule.id}`}>{t('monitor.duration')}</FieldLabel><Input id={`duration-${rule.id}`} type="number" min={0} max={3600} step={1} disabled={busy} value={Number.isNaN(rule.duration_seconds) ? '' : rule.duration_seconds} onChange={event => change(index, { duration_seconds: event.target.value === '' ? NaN : Number(event.target.value) })} /></Field><Field><FieldLabel htmlFor={`severity-${rule.id}`}>{t('monitor.severity')}</FieldLabel><Select value={rule.severity} disabled={busy} onValueChange={value => change(index, { severity: value as MonitorSeverity })}><SelectTrigger id={`severity-${rule.id}`}><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{(['info', 'warning', 'err', 'critical'] as const).map(value => <SelectItem key={value} value={value}>{t(severityKeys[value])}</SelectItem>)}</SelectGroup></SelectContent></Select></Field></FieldGroup>)}</FieldGroup></div><Button disabled={busy} onClick={save}>{t('monitor.saveRules')}</Button></DialogContent></Dialog>
  </>
}
