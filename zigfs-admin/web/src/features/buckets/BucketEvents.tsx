import { useCallback, useEffect, useRef, useState } from 'react'
import { Plus, RefreshCw, Trash2, Pencil } from 'lucide-react'
import { t } from '@/locales'
import type { ApiClient } from '@/api/client'
import type { BucketEventSubscription, EventDestination } from '@/types/api'
import { Button } from '@/components/ui/Button'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Input } from '@/components/ui/Input'
import { Checkbox } from '@/components/ui/checkbox'
import { Badge } from '@/components/ui/Badge'
import { Table, TableHeader, TableHead, TableRow, TableBody, TableCell } from '@/components/ui/table'
import { Empty, EmptyHeader, EmptyTitle, EmptyDescription } from '@/components/ui/empty'
import { Field, FieldGroup, FieldLabel, FieldSet, FieldLegend } from '@/components/ui/field'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/Dialog'
import { useToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'

const eventTypes = ['PUT', 'GET', 'DELETE', 'ILM', 'SCANNER'] as const
const eventLabels = {
  PUT: 'bucketEvents.put', GET: 'bucketEvents.get', DELETE: 'bucketEvents.delete',
  ILM: 'bucketEvents.ilm', SCANNER: 'bucketEvents.scanner',
} as const

export function BucketEvents({ api, bucketName }: { api: ApiClient; bucketName: string }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [items, setItems] = useState<BucketEventSubscription[]>([])
  const [loading, setLoading] = useState(true)
  const [ready, setReady] = useState(false)
  const [saving, setSaving] = useState(false)
  const [open, setOpen] = useState(false)
  const [destinations, setDestinations] = useState<EventDestination[]>([])
  const [destination, setDestination] = useState('')
  const [editing, setEditing] = useState<string | null>(null)
  const [prefix, setPrefix] = useState('')
  const [suffix, setSuffix] = useState('')
  const [events, setEvents] = useState<string[]>([])
  const [invalid, setInvalid] = useState(false)
  const request = useRef(0)
  const refresh = useCallback(async () => {
    const id = ++request.current
    setLoading(true)
    try {
      const [result, targets] = await Promise.all([api.getBucketEventSubscriptions(bucketName), api.eventDestinations()])
      if (id !== request.current) return
      setItems(result.items)
      setDestinations(targets.items)
      setReady(true)
    } catch {
      if (id === request.current) toast(t('bucketEvents.loadFailed'), 'error')
    } finally { if (id === request.current) setLoading(false) }
  }, [api, bucketName, toast])
  useEffect(() => { void refresh(); return () => { request.current++ } }, [refresh])
  async function save(next: BucketEventSubscription[]) {
    setSaving(true)
    try {
      const result = await api.putBucketEventSubscriptions(bucketName, next)
      setItems(result.items)
      toast(t('bucketEvents.saved'), 'success')
      return true
    } catch { toast(t('bucketEvents.saveFailed'), 'error'); return false }
    finally { setSaving(false) }
  }
  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!destination) { toast(t('bucketEvents.destinationRequired'), 'error'); return }
    if (!events.length) { setInvalid(true); toast(t('bucketEvents.selectRequired'), 'error'); return }
    for (const value of [prefix, suffix]) {
      if (new TextEncoder().encode(value).length > 1024 || value.includes('\0')) { toast(t('bucketEvents.filterInvalid'), 'error'); return }
    }
    if (await save([...items.filter(item => item.id !== editing), { destination, id: editing ?? Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join(''), prefix, suffix, events }])) setOpen(false)
  }
  return <div className="flex flex-col gap-6">
    <header className="flex flex-wrap items-start justify-between gap-4">
      <div><h3>{t('bucketEvents.title')}</h3><p className="text-sm text-muted-foreground">{t('bucketEvents.bucket', { name: bucketName })}</p></div>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={!ready || loading || saving || items.length >= 100} onClick={() => { setEditing(null); setDestination(''); setPrefix(''); setSuffix(''); setEvents([]); setInvalid(false); setOpen(true) }}><Plus data-icon="inline-start" />{t('bucketEvents.add')}</Button>
        <Button variant="outline" size="sm" disabled={loading || saving} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{t('bucketEvents.refresh')}</Button>
      </div>
    </header>
    <div className="rounded-lg border">
      <Table>
        <TableHeader><TableRow><TableHead>{t('bucketEvents.events')}</TableHead><TableHead>{t('bucketEvents.destination')}</TableHead><TableHead>{t('bucketEvents.prefix')}</TableHead><TableHead>{t('bucketEvents.suffix')}</TableHead><TableHead><div className="flex justify-end">{t('bucketEvents.actions')}</div></TableHead></TableRow></TableHeader>
        <TableBody>
          {items.map(item => <TableRow key={item.id}>
            <TableCell><div className="flex flex-wrap gap-1">{item.events.map(value => <Badge key={value}>{value}</Badge>)}</div></TableCell>
            <TableCell>{item.destination || t('bucketEvents.unbound')}</TableCell>
            <TableCell className="max-w-64 break-all whitespace-normal">{item.prefix || '—'}</TableCell><TableCell className="max-w-64 break-all whitespace-normal">{item.suffix || '—'}</TableCell>
            <TableCell><div className="flex items-center justify-end gap-1"><Button variant="ghost" size="icon-sm" aria-label={t('bucketEvents.edit')} disabled={loading || saving} onClick={() => { setEditing(item.id); setDestination(item.destination || ''); setPrefix(item.prefix); setSuffix(item.suffix); setEvents(item.events); setInvalid(false); setOpen(true) }}><Pencil /></Button><Button variant="ghost" size="icon-sm" aria-label={t('bucketEvents.remove')} disabled={loading || saving} onClick={() => void (async () => {
              if (await confirm({ title: t('bucketEvents.remove'), message: t('bucketEvents.removeConfirm'), confirmLabel: t('bucketEvents.remove'), danger: true })) await save(items.filter(value => value.id !== item.id))
            })()}><Trash2 /></Button></div></TableCell>
          </TableRow>)}
          {!items.length && <TableRow><TableCell colSpan={5}><Empty className="min-h-56"><EmptyHeader><EmptyTitle>{t(loading ? 'bucketEvents.loading' : ready ? 'bucketEvents.empty' : 'bucketEvents.loadFailed')}</EmptyTitle>{!loading && ready && <EmptyDescription>{t('bucketEvents.emptyHelp')}</EmptyDescription>}</EmptyHeader></Empty></TableCell></TableRow>}
        </TableBody>
      </Table>
    </div>
    <Dialog open={open} onOpenChange={value => { if (!saving) setOpen(value) }}>
      <DialogContent className="bucket-event-dialog" layout="form" onInteractOutside={event => event.preventDefault()}>
        <DialogHeader><DialogTitle>{t(editing ? 'bucketEvents.edit' : 'bucketEvents.subscribe')}</DialogTitle><DialogDescription>{t('bucketEvents.bucket', { name: bucketName })}</DialogDescription></DialogHeader>
        <form onSubmit={event => void submit(event)} className="flex min-h-0 flex-col">
          <div className="overflow-y-auto pb-6"><FieldGroup>
            <Field><FieldLabel htmlFor="subscription-destination">{t('bucketEvents.destination')}</FieldLabel><OptionSelect id="subscription-destination" value={destination} onValueChange={setDestination} disabled={saving} placeholder={t('bucketEvents.destinationRequired')} options={destinations.map(item => ({ value: item.name, label: `${item.name} (${item.type})` }))} />{!destinations.length && <p className="text-sm text-muted-foreground">{t('bucketEvents.noDestinations')}</p>}</Field>
            <Field><FieldLabel htmlFor="subscription-prefix">{t('bucketEvents.prefix')}</FieldLabel><Input id="subscription-prefix" value={prefix} onChange={event => setPrefix(event.target.value)} placeholder={t('bucketEvents.prefixPlaceholder')} disabled={saving} /></Field>
            <Field><FieldLabel htmlFor="subscription-suffix">{t('bucketEvents.suffix')}</FieldLabel><Input id="subscription-suffix" value={suffix} onChange={event => setSuffix(event.target.value)} placeholder={t('bucketEvents.suffixPlaceholder')} disabled={saving} /></Field>
            <FieldSet><FieldLegend>{t('bucketEvents.selectEvents')}</FieldLegend><FieldGroup data-slot="checkbox-group">
              {eventTypes.map(type => <Field key={type} orientation="horizontal" data-invalid={invalid || undefined}>
                <Checkbox id={`subscription-${type}`} checked={events.includes(type)} disabled={saving} aria-invalid={invalid || undefined} onCheckedChange={checked => { setInvalid(false); setEvents(current => checked === true ? [...current, type] : current.filter(value => value !== type)) }} />
                <FieldLabel htmlFor={`subscription-${type}`}>{t(eventLabels[type])}</FieldLabel>
              </Field>)}
            </FieldGroup></FieldSet>
          </FieldGroup></div>
          <div className="ui-dialog-footer"><Button type="button" variant="outline" disabled={saving} onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button type="submit" disabled={saving}>{t('bucketEvents.save')}</Button></div>
        </form>
      </DialogContent>
    </Dialog>
  </div>
}
