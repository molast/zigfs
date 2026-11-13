import { useState } from 'react'
import { ArrowDown, ArrowUp, ArrowUpDown, ChevronDown, ChevronRight, Pencil, Plus, RefreshCw, Trash2 } from 'lucide-react'
import { t } from '@/locales'
import { useErrorToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Checkbox } from '@/components/ui/checkbox'
import { Switch } from '@/components/ui/switch'
import { Table, TableHeader, TableHead, TableRow, TableBody, TableCell } from '@/components/ui/table'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/Dialog'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/Tabs'
import { Collapsible, CollapsibleTrigger, CollapsibleContent } from '@/components/ui/collapsible'
import { Alert, AlertTitle, AlertDescription } from '@/components/ui/alert'
import { Empty, EmptyHeader, EmptyTitle, EmptyDescription } from '@/components/ui/empty'
import { createLifecycleRule, validateLifecycleRules, lifecycleTagError, type LifecycleRule } from './lifecycle'

interface Props {
  rules: LifecycleRule[]
  bucketName: string
  versioned: boolean
  loading: boolean
  onRefresh: () => Promise<void>
  onSave: (rules: LifecycleRule[]) => Promise<void>
}
const columns = ['type', 'version', 'marker', 'storage', 'prefix', 'period', 'status'] as const
type Column = typeof columns[number]
export function LifecycleRulesEditor({ rules, bucketName, versioned, loading, onRefresh, onSave }: Props) {
  const confirm = useConfirm()
  const notifyError = useErrorToast()
  const [draft, setDraft] = useState<LifecycleRule | null>(null)
  const [editing, setEditing] = useState<number | null>(null)
  const [more, setMore] = useState(false)
  const [advanced, setAdvanced] = useState(false)
  const [busy, setBusy] = useState(false)
  const [invalid, setInvalid] = useState('')
  const [sort, setSort] = useState<{ column: Column; descending: boolean } | null>(null)
  const disabled = loading || busy
  function begin(index: number | null) {
    setEditing(index)
    let id = rules.length + 1
    while (rules.some(rule => rule.id === `expiry-rule-${id}`)) id++
    const rule = index === null ? createLifecycleRule(`expiry-rule-${id}`) : rules[index]
    setDraft({ ...rule, tags: rule.tags?.length ? rule.tags.map(tag => ({ ...tag })) : [{ key: '', value: '' }] })
    setMore(false); setAdvanced(false); setInvalid('')
  }
  async function persist(next: LifecycleRule[], close = false) {
    setBusy(true)
    try { await onSave(next); if (close) setDraft(null) } catch { /* Parent reports API failures. */ }
    finally { setBusy(false) }
  }
  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!draft) return
    const normalized = { ...draft, tags: draft.tags?.length === 1 && draft.tags[0].key === '' && draft.tags[0].value === '' ? [] : draft.tags }
    const tagError = lifecycleTagError(normalized)
    if (tagError) { setMore(true); setInvalid(`tag-${tagError.index}-${tagError.field}`); notifyError(tagError.message); return }
    const next = editing === null ? [...rules, normalized] : rules.map((rule, index) => index === editing ? normalized : rule)
    try { validateLifecycleRules(next) } catch (reason) {
      setInvalid(draft.action === 'current-date' ? 'date' : !Number.isInteger(draft.days) || draft.days < 1 ? 'days' : 'newer')
      notifyError((reason as Error).message); return
    }
    await persist(next, true)
  }
  async function remove(index: number) {
    if (await confirm({ title: t('buckets.deleteLifecycleRule'), message: t('buckets.deleteLifecycleRuleValueThisCannotBeUndone', { '0': rules[index].id }), confirmLabel: t('buckets.delete'), danger: true })) await persist(rules.filter((_, i) => i !== index))
  }
  const rows = rules.map((rule, index) => ({ rule, index }))
  if (sort) rows.sort((a, b) => {
    const value = (rule: LifecycleRule) => sort.column === 'period' ? rule.action === 'current-date' ? Date.parse(rule.expirationDate) : rule.action === 'delete-marker' ? 0 : rule.days : sort.column === 'status' ? Number(rule.enabled) : sort.column === 'prefix' ? rule.prefix : sort.column === 'version' ? versionLabel(rule) : sort.column === 'marker' ? Number(rule.action === 'delete-marker') : ''
    const av = value(a.rule), bv = value(b.rule)
    const result = typeof av === 'number' && typeof bv === 'number' ? av - bv : String(av).localeCompare(String(bv))
    return sort.descending ? -result : result
  })
  return <section className="flex flex-col gap-6">
    <header className="flex flex-wrap items-start justify-between gap-4">
      <div><h3>{t('lifecycle.title')}</h3><p className="text-sm text-muted-foreground">{t('bucketEvents.bucket', { name: bucketName })}</p></div>
      <div className="flex gap-2"><Button size="sm" disabled={disabled || rules.length >= 1000} onClick={() => begin(null)}><Plus data-icon="inline-start" />{t('buckets.addLifecycleRule')}</Button><Button size="sm" variant="outline" disabled={disabled} onClick={() => void onRefresh()}><RefreshCw data-icon="inline-start" />{t('bucketEvents.refresh')}</Button></div>
    </header>
    <div className="rounded-lg border"><Table>
      <TableHeader><TableRow>{columns.map(column => <TableHead key={column} aria-sort={sort?.column === column ? sort.descending ? 'descending' : 'ascending' : 'none'}><Button size="sm" variant="ghost" onClick={() => setSort({ column, descending: sort?.column === column && !sort.descending })}>{t(`lifecycle.${column}`)}{sort?.column === column ? sort.descending ? <ArrowDown data-icon="inline-end" /> : <ArrowUp data-icon="inline-end" /> : <ArrowUpDown data-icon="inline-end" />}</Button></TableHead>)}<TableHead className="text-right">{t('buckets.actions')}</TableHead></TableRow></TableHeader>
      <TableBody>{rows.map(({ rule, index }) => <TableRow key={rule.id}>
        <TableCell>{t('lifecycle.expiration')}</TableCell><TableCell>{versionLabel(rule)}</TableCell><TableCell>{rule.action === 'delete-marker' ? t('buckets.enabled') : '—'}</TableCell><TableCell>—</TableCell><TableCell className="max-w-48 break-all whitespace-normal">{rule.prefix || '—'}</TableCell><TableCell>{expiryLabel(rule)}</TableCell>
        <TableCell><div className="flex items-center gap-2"><Switch size="sm" checked={rule.enabled} disabled={disabled} aria-label={`${rule.id} ${t('buckets.status')}`} onCheckedChange={enabled => void persist(rules.map((item, i) => i === index ? { ...item, enabled } : item))} /><span>{t(rule.enabled ? 'buckets.enabled' : 'buckets.disabled')}</span></div></TableCell>
        <TableCell className="text-right"><Button variant="ghost" size="icon-sm" disabled={disabled} aria-label={t('buckets.editValue', { '0': rule.id })} onClick={() => begin(index)}><Pencil /></Button><Button variant="ghost" size="icon-sm" disabled={disabled} aria-label={t('buckets.deleteValue', { '0': rule.id })} onClick={() => void remove(index)}><Trash2 /></Button></TableCell>
      </TableRow>)}{!rules.length && <TableRow><TableCell colSpan={8}><Empty className="min-h-64"><EmptyHeader><EmptyTitle>{t('buckets.noLifecycleRulesConfigured')}</EmptyTitle><EmptyDescription>{t('lifecycle.emptyHelp')}</EmptyDescription></EmptyHeader></Empty></TableCell></TableRow>}</TableBody>
    </Table></div>
    <Dialog open={draft !== null} onOpenChange={open => { if (!open && !disabled) setDraft(null) }}>
      <DialogContent layout="form" className="bucket-lifecycle-dialog" aria-describedby={undefined} onInteractOutside={event => event.preventDefault()}>
        <DialogHeader><DialogTitle className="flex min-w-0 max-w-full items-center gap-2"><span className="shrink-0">{t(editing === null ? 'buckets.addLifecycleRule' : 'buckets.editLifecycleRule')}</span><span className="truncate">（{t('bucketEvents.bucket', { name: bucketName })}）</span></DialogTitle></DialogHeader>
        {draft && <form onSubmit={event => void submit(event)} className="flex min-h-0 flex-col">
          <div className="overflow-y-auto pb-4"><FieldGroup density="compact" className="gap-4">
            <Tabs value="expiration"><TabsList aria-label={t('buckets.ruleType')}><TabsTrigger value="expiration" disabled={disabled}>{t('lifecycle.expiration')}</TabsTrigger></TabsList></Tabs>
            <Field><FieldLabel htmlFor="lifecycle-version">{t('buckets.objectVersion')}</FieldLabel><OptionSelect id="lifecycle-version" value={draft.action === 'noncurrent-days' ? 'noncurrent' : 'current'} disabled={disabled} onValueChange={value => { setInvalid(''); setDraft({ ...draft, action: value === 'noncurrent' ? 'noncurrent-days' : 'current-days' }) }} options={[{ value: 'current', label: t('buckets.currentVersion') }, { value: 'noncurrent', label: t('buckets.nonCurrentVersion') }]} /></Field>
            <Field data-invalid={invalid === 'days' || invalid === 'date' || undefined}><FieldLabel htmlFor="lifecycle-period">{t('lifecycle.period')}</FieldLabel><FieldDescription>{t('lifecycle.periodHelp')}</FieldDescription>{draft.action === 'current-date' ? <Input id="lifecycle-period" type="date" value={draft.expirationDate} disabled={disabled} aria-invalid={invalid === 'date'} onChange={event => { setInvalid(''); setDraft({ ...draft, expirationDate: event.target.value }) }} /> : <div className="flex items-center gap-3"><Input className="max-w-32" id="lifecycle-period" type="number" min={1} step={1} value={Number.isNaN(draft.days) ? '' : draft.days} disabled={disabled || draft.action === 'delete-marker'} aria-invalid={invalid === 'days'} onChange={event => { setInvalid(''); setDraft({ ...draft, days: event.target.value === '' ? NaN : Number(event.target.value) }) }} /><span className="text-muted-foreground">{t('lifecycle.daysAfter')}</span></div>}</Field>
            <Collapsible open={more} onOpenChange={setMore}><CollapsibleTrigger asChild><Button variant="ghost" size="sm" className="lifecycle-section-trigger">{more ? <ChevronDown data-icon="inline-start" /> : <ChevronRight data-icon="inline-start" />}{t('lifecycle.more')}</Button></CollapsibleTrigger><CollapsibleContent className="pt-3"><FieldGroup density="compact" className="gap-4">
              <Field><FieldLabel htmlFor="lifecycle-prefix">{t('lifecycle.prefix')}</FieldLabel><Input id="lifecycle-prefix" value={draft.prefix} placeholder={t('bucketEvents.prefixPlaceholder')} disabled={disabled} onChange={event => setDraft({ ...draft, prefix: event.target.value })} /></Field>
              <Field><div className="flex items-center justify-between gap-2"><FieldLabel>{t('buckets.tags')}</FieldLabel><Button type="button" size="sm" variant="outline" disabled={disabled || (draft.tags?.length ?? 0) >= 10 || draft.action === 'delete-marker'} onClick={() => { setInvalid(''); setDraft({ ...draft, tags: [...(draft.tags ?? []), { key: '', value: '' }] }) }}><Plus data-icon="inline-start" />{t('buckets.addTag')}</Button></div>
                {(draft.tags ?? []).map((tag, index) => <div className="flex items-start gap-3" key={index}>
                  <Field data-invalid={invalid === `tag-${index}-key` || undefined}><Input aria-label={t('lifecycle.tagName')} placeholder={t('lifecycle.tagName')} value={tag.key} disabled={disabled} aria-invalid={invalid === `tag-${index}-key`} onChange={event => { setInvalid(''); setDraft({ ...draft, tags: draft.tags!.map((item, i) => i === index ? { ...item, key: event.target.value } : item) }) }} /></Field>
                  <Field data-invalid={invalid === `tag-${index}-value` || undefined}><Input aria-label={t('lifecycle.tagValue')} placeholder={t('lifecycle.tagValue')} value={tag.value} disabled={disabled} aria-invalid={invalid === `tag-${index}-value`} onChange={event => { setInvalid(''); setDraft({ ...draft, tags: draft.tags!.map((item, i) => i === index ? { ...item, value: event.target.value } : item) }) }} /></Field>
                  <Button type="button" size="icon-sm" variant="ghost" className="danger-icon-button" disabled={disabled || (draft.tags?.length ?? 0) <= 1} aria-label={t('buckets.deleteTag')} onClick={() => { setInvalid(''); setDraft({ ...draft, tags: draft.tags!.filter((_, i) => i !== index) }) }}><Trash2 /></Button>
                </div>)}<FieldDescription>{t(draft.action === 'delete-marker' ? 'lifecycle.markerTagsConflict' : 'lifecycle.tagsHelp')}</FieldDescription></Field>
            </FieldGroup></CollapsibleContent></Collapsible>
            <Collapsible open={advanced} onOpenChange={setAdvanced}><CollapsibleTrigger asChild><Button variant="ghost" size="sm" className="lifecycle-section-trigger">{advanced ? <ChevronDown data-icon="inline-start" /> : <ChevronRight data-icon="inline-start" />}{t('lifecycle.advanced')}</Button></CollapsibleTrigger><CollapsibleContent className="pt-3"><FieldGroup density="compact" className="gap-4">
              {draft.action === 'noncurrent-days' ? <Field data-invalid={invalid === 'newer' || undefined}><FieldLabel htmlFor="lifecycle-newer">{t('buckets.keepNewestNonCurrentVersionsOptional')}</FieldLabel><Input id="lifecycle-newer" type="number" min={1} step={1} disabled={disabled} value={draft.newerNoncurrentVersions ?? ''} aria-invalid={invalid === 'newer'} onChange={event => { setInvalid(''); setDraft({ ...draft, newerNoncurrentVersions: event.target.value ? Number(event.target.value) : undefined }) }} /></Field> : <Field orientation="horizontal"><Checkbox id="lifecycle-marker" checked={draft.action === 'delete-marker'} disabled={disabled || Boolean(draft.tags?.some(tag => tag.key !== '' || tag.value !== ''))} onCheckedChange={checked => setDraft({ ...draft, action: checked ? 'delete-marker' : 'current-days' })} /><div><FieldLabel htmlFor="lifecycle-marker">{t('lifecycle.markerHandling')}</FieldLabel><FieldDescription>{t('lifecycle.markerHelp')}</FieldDescription></div></Field>}
              {versioned && draft.action !== 'noncurrent-days' && draft.action !== 'delete-marker' && <Alert><AlertTitle>{t('common.warning')}</AlertTitle><AlertDescription>{t('lifecycle.versionWarning')}</AlertDescription></Alert>}
            </FieldGroup></CollapsibleContent></Collapsible>
          </FieldGroup></div>
          <div className="ui-dialog-footer"><Button type="button" variant="outline" disabled={disabled} onClick={() => setDraft(null)}>{t('common.cancel')}</Button><Button type="submit" disabled={disabled}>{t('buckets.save')}</Button></div>
        </form>}
      </DialogContent>
    </Dialog>
  </section>
}
function versionLabel(rule: LifecycleRule) { return t(rule.action === 'noncurrent-days' ? 'buckets.nonCurrentVersion' : 'buckets.currentVersion') }
function expiryLabel(rule: LifecycleRule) {
  if (rule.action === 'delete-marker') return t('buckets.whenExpired')
  if (rule.action === 'current-date') return t('buckets.onValue', { '0': rule.expirationDate })
  return t('buckets.afterValueDays', { '0': rule.days })
}
