import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { ArrowDownUp, Network, Orbit, Pencil, Rss, Trash2, Waypoints, Webhook } from 'lucide-react'
import { ApiError, type ApiClient } from '@/api/client'
import type { EventDestination } from '@/types/api'
import { t } from '@/locales'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Badge } from '@/components/ui/Badge'
import { Card } from '@/components/ui/Card'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/Dialog'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { Empty, EmptyHeader, EmptyTitle, EmptyDescription } from '@/components/ui/empty'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from '@/components/ui/table'
import { ToolbarControls, ToolbarSearch, ToolbarCreateButton, ToolbarRefreshButton } from '@/components/ui/ToolbarControls'
import { useToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'

const destinationTypes = [
  { type: 'kafka', label: 'eventDestinations.kafka', description: 'eventDestinations.kafkaHelp', icon: Network },
  { type: 'mqtt', label: 'eventDestinations.mqtt', description: 'eventDestinations.mqttHelp', icon: Rss },
  { type: 'webhook', label: 'eventDestinations.webhook', description: 'eventDestinations.webhookHelp', icon: Webhook },
  { type: 'nats', label: 'eventDestinations.nats', description: 'eventDestinations.natsHelp', icon: Waypoints },
  { type: 'pulsar', label: 'eventDestinations.pulsar', description: 'eventDestinations.pulsarHelp', icon: Orbit },
] as const

const newDestination = (): EventDestination => ({ name: '', type: 'webhook', endpoint: '', auth_token: '', has_auth_token: false, queue_limit: 100000, queue_directory: '', client_certificate: '', client_key: '', client_ca: '', skip_tls_verify: false, broker: '', topic: '', qos: 0, username: '', password: '', has_password: false, reconnect_interval: '', keep_alive_interval: '', tls_policy: '', tls_ca: '', tls_client_certificate: '', tls_client_key: '', trust_leaf_as_ca: false, websocket_path_allowlist: '', comment: '' })
const pathFields = ['queue_directory', 'client_certificate', 'client_key', 'client_ca'] as const
const pathLabels = { queue_directory: 'eventDestinations.queueDirectory', client_certificate: 'eventDestinations.clientCertificate', client_key: 'eventDestinations.clientKey', client_ca: 'eventDestinations.clientCa' } as const
const pathPlaceholders = { queue_directory: 'events/WEBHOOK_1', client_certificate: 'certs/client.crt', client_key: 'certs/client.key', client_ca: 'certs/ca.crt' }
const validText = (value: string, max: number) => new TextEncoder().encode(value).length <= max && !/[\x00-\x1f\x7f]/.test(value)
function validEndpoint(value: string) {
  if (!validText(value, 4096) || /[\s\\]/.test(value)) return false
  try { const url = new URL(value); return /^https?:\/\//.test(value) && !!url.hostname && !url.username && !url.password && !value.includes('#') } catch { return false }
}
function validPath(value: string) { return validText(value, 1024) && !value.startsWith('/') && !/[\\:]/.test(value) && !value.split('/').some(part => part === '.' || part === '..') }

export function EventDestinationsView({ api }: { api: ApiClient }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [items, setItems] = useState<EventDestination[]>([])
  const [loading, setLoading] = useState(true)
  const [ready, setReady] = useState(false)
  const [saving, setSaving] = useState(false)
  const [query, setQuery] = useState('')
  const [ascending, setAscending] = useState(true)
  const [open, setOpen] = useState(false)
  const [selected, setSelected] = useState(false)
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState<EventDestination>(newDestination)
  const [queueLimit, setQueueLimit] = useState('')
  const [mqttQos, setMqttQos] = useState('')
  const isMqtt = draft.type === 'mqtt'
  const [invalid, setInvalid] = useState<keyof EventDestination | ''>('')
  const generation = useRef(0)
  const refresh = useCallback(async () => {
    const request = ++generation.current
    setLoading(true)
    try {
      const result = await api.eventDestinations()
      if (generation.current === request) { setItems(result.items); setReady(true) }
    } catch { if (generation.current === request) toast(t('eventDestinations.loadFailed'), 'error') }
    finally { if (generation.current === request) setLoading(false) }
  }, [api, toast])
  useEffect(() => { void refresh(); return () => { generation.current++ } }, [refresh])
  const filtered = useMemo(() => items.filter(item => `${item.name} ${item.endpoint} ${item.broker} ${item.comment}`.toLowerCase().includes(query.trim().toLowerCase())).sort((a, b) => a.name.localeCompare(b.name) * (ascending ? 1 : -1)), [items, query, ascending])
  const update = <K extends keyof EventDestination>(key: K, value: EventDestination[K]) => { setDraft(current => ({ ...current, [key]: value })); if (invalid === key) setInvalid('') }
  function begin(item?: EventDestination) {
    setEditing(!!item); setSelected(!!item); setDraft(item ? { ...newDestination(), ...item, auth_token: '', password: '' } : newDestination()); setQueueLimit(item ? String(item.queue_limit) : ''); setMqttQos(item ? String(item.qos) : ''); setInvalid(''); setOpen(true)
  }
  function fail(field: keyof EventDestination, message: string) {
    setInvalid(field); toast(message, 'error'); document.getElementById(`destination-${field}`)?.focus()
  }
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (saving || !selected) return
    if (!/^[A-Z0-9_]{1,128}$/.test(draft.name)) return fail('name', t('eventDestinations.invalidName'))
    if (isMqtt) {
      let brokerValid = false
      try { const uri = new URL(draft.broker); brokerValid = /^(tcp|tls|ssl|mqtt|mqtts|ws|wss):\/\//.test(draft.broker) && !!uri.hostname && !uri.username && !uri.password && !draft.broker.includes('#') && !/[\s\\]/.test(draft.broker) && validText(draft.broker, 4096) } catch { /* Report the broker field below. */ }
      if (!brokerValid) return fail('broker', t('eventDestinations.invalidMqttBroker'))
      if (!draft.topic || !validText(draft.topic, 1024) || /[+#]/.test(draft.topic)) return fail('topic', t('eventDestinations.invalidMqttTopic'))
      if (mqttQos !== '' && !/^[012]$/.test(mqttQos)) return fail('qos', t('eventDestinations.invalidMqttQos'))
      if (!validText(draft.username, 1024)) return fail('username', t('eventDestinations.invalidMqttUsername'))
      if (!validText(draft.password, 4096)) return fail('password', t('eventDestinations.invalidMqttPassword'))
      for (const field of ['reconnect_interval', 'keep_alive_interval'] as const) {
        const value = draft[field]
        const match = /^(\d+)(ms|s|m|h)$/.exec(value)
        if (value && (value.length > 32 || !match || Number(match[1]) > 4294967295 || (field === 'reconnect_interval' && Number(match[1]) === 0))) return fail(field, t('eventDestinations.invalidMqttInterval'))
      }
      if (!validPath(draft.queue_directory)) return fail('queue_directory', t('eventDestinations.invalidPath'))
    } else {
      if (!validEndpoint(draft.endpoint)) return fail('endpoint', t('eventDestinations.invalidEndpoint'))
      if (!validText(draft.auth_token, 4096)) return fail('auth_token', t('eventDestinations.invalidToken'))
    }
    if (queueLimit !== '' && (!/^\d+$/.test(queueLimit) || Number(queueLimit) < 1 || Number(queueLimit) > 4294967295)) return fail('queue_limit', t('eventDestinations.invalidQueueLimit'))
    if (isMqtt) {
      if (!validText(draft.tls_policy, 64)) return fail('tls_policy', t('eventDestinations.invalidMqttTlsPolicy'))
      for (const field of ['tls_ca', 'tls_client_certificate', 'tls_client_key'] as const) if (!validPath(draft[field])) return fail(field, t('eventDestinations.invalidPath'))
      if (!!draft.tls_client_certificate !== !!draft.tls_client_key) return fail(draft.tls_client_certificate ? 'tls_client_key' : 'tls_client_certificate', t('eventDestinations.invalidCertificate'))
      if (!validText(draft.websocket_path_allowlist, 4096) || (draft.websocket_path_allowlist && draft.websocket_path_allowlist.split(',').some(path => !path.trim().startsWith('/') || /[ ?#\\]/.test(path.trim())))) return fail('websocket_path_allowlist', t('eventDestinations.invalidMqttPaths'))
    } else {
      for (const field of pathFields) if (!validPath(draft[field])) return fail(field, t('eventDestinations.invalidPath'))
      if (!!draft.client_certificate !== !!draft.client_key) return fail(draft.client_certificate ? 'client_key' : 'client_certificate', t('eventDestinations.invalidCertificate'))
    }
    if (!validText(draft.comment, 1024)) return fail('comment', t('eventDestinations.invalidComment'))
    setSaving(true)
    try {
      const value = { ...draft, qos: mqttQos === '' ? 0 : Number(mqttQos), reconnect_interval: draft.reconnect_interval || '5s', keep_alive_interval: draft.keep_alive_interval || '15s', queue_limit: queueLimit === '' ? newDestination().queue_limit : Number(queueLimit) }
      const result = editing ? await api.updateEventDestination(value) : await api.createEventDestination(value)
      setItems(current => [...current.filter(item => item.name !== result.name), result])
      setOpen(false); setDraft(newDestination()); toast(t('eventDestinations.saved'), 'success')
    } catch (error) {
      if (error instanceof ApiError && error.body.code === 'EventQueueNotEmpty') fail('queue_directory', t('eventDestinations.queueNotEmpty'))
      else if (error instanceof ApiError && error.status === 409) fail('name', t('eventDestinations.exists'))
      else toast(t('eventDestinations.saveFailed'), 'error')
    } finally { setSaving(false) }
  }
  async function remove(item: EventDestination) {
    if (!await confirm({ title: t('eventDestinations.remove'), message: t('eventDestinations.removeConfirm', { name: item.name }), confirmLabel: t('eventDestinations.remove'), danger: true })) return
    setSaving(true)
    try { await api.deleteEventDestination(item.name); setItems(current => current.filter(value => value.name !== item.name)); toast(t('eventDestinations.deleted'), 'success') }
    catch (error) { toast(t(error instanceof ApiError && error.body.code === 'EventDestinationInUse' ? 'eventDestinations.inUse' : 'eventDestinations.deleteFailed'), 'error') }
    finally { setSaving(false) }
  }
  const SelectedIcon = isMqtt ? Rss : Webhook
  return <section className="flex flex-col gap-6">
    <header className="page-header">
      <h2>{t('eventDestinations.title')}</h2>
      <ToolbarControls>
        <ToolbarSearch label={t('eventDestinations.search')} placeholder={t('eventDestinations.search')} value={query} onChange={event => setQuery(event.target.value)} />
        <ToolbarCreateButton label={t('eventDestinations.add')} disabled={!ready || loading || saving || items.length >= 100} onClick={() => begin()} />
        <ToolbarRefreshButton label={t('bucketEvents.refresh')} busy={loading} disabled={saving || open} onClick={() => void refresh()} />
      </ToolbarControls>
    </header>
    <Card className="overflow-hidden p-0">
      <Table><TableHeader><TableRow>
        <TableHead><Button variant="ghost" size="sm" onClick={() => setAscending(current => !current)}>{t('eventDestinations.title')}<ArrowDownUp data-icon="inline-end" /></Button></TableHead>
        <TableHead>{t('eventDestinations.type')}</TableHead><TableHead>{t('eventDestinations.status')}</TableHead><TableHead>{t('eventDestinations.source')}</TableHead><TableHead className="text-right">{t('bucketEvents.actions')}</TableHead>
      </TableRow></TableHeader><TableBody>
        {filtered.map(item => <TableRow key={item.name}>
          <TableCell className="max-w-64 break-all whitespace-normal">{item.name}</TableCell><TableCell>{t(item.type === 'mqtt' ? 'eventDestinations.mqtt' : 'eventDestinations.webhook')}</TableCell><TableCell><Badge>{t('eventDestinations.configured')}</Badge></TableCell><TableCell>{t('eventDestinations.console')}</TableCell>
          <TableCell><div className="flex justify-end gap-1"><Button variant="ghost" size="icon-sm" aria-label={t('eventDestinations.edit')} disabled={loading || saving} onClick={() => begin(item)}><Pencil /></Button><Button variant="ghost" size="icon-sm" aria-label={t('eventDestinations.remove')} disabled={loading || saving} onClick={() => void remove(item)}><Trash2 /></Button></div></TableCell>
        </TableRow>)}
        {!filtered.length && <TableRow><TableCell colSpan={5}><Empty className="min-h-64"><EmptyHeader><EmptyTitle>{t(loading ? 'eventDestinations.loading' : !ready ? 'eventDestinations.loadFailed' : items.length ? 'eventDestinations.noMatches' : 'eventDestinations.empty')}</EmptyTitle>{ready && !loading && !items.length && <EmptyDescription>{t('eventDestinations.emptyHelp')}</EmptyDescription>}</EmptyHeader></Empty></TableCell></TableRow>}
      </TableBody></Table>
    </Card>
    <Dialog open={open} onOpenChange={value => { if (!saving) { setOpen(value); if (!value) setDraft(newDestination()) } }}>
      <DialogContent layout="form" className="event-destination-dialog" onInteractOutside={event => event.preventDefault()}>
        <DialogHeader><DialogTitle>{t(!selected ? 'eventDestinations.add' : isMqtt ? editing ? 'eventDestinations.editMqtt' : 'eventDestinations.addMqtt' : editing ? 'eventDestinations.editWebhook' : 'eventDestinations.addWebhook')}</DialogTitle><DialogDescription className="sr-only">{t('eventDestinations.dialogHelp')}</DialogDescription></DialogHeader>
        <form onSubmit={event => void submit(event)} noValidate className="flex min-h-0 flex-col">
          <div className="min-h-0 overflow-y-auto px-1">
            {!selected ? <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              {destinationTypes.map(({ type, label, description, icon: Icon }) => <Button key={type} variant="outline" type="button" className="event-destination-type-card" disabled={type !== 'webhook' && type !== 'mqtt'} onClick={() => { if (type === 'webhook' || type === 'mqtt') { update('type', type); setSelected(true) } }}>
                <Icon aria-hidden="true" />
                <span><strong>{t(label)}</strong><span>{t(description)}</span></span>
              </Button>)}
            </div> : <FieldGroup density="compact" className="gap-5">
              <Card className="flex flex-row items-center gap-4 p-4"><SelectedIcon className="size-9 text-primary" /><div><p className="text-xs text-muted-foreground">{t('eventDestinations.selectedType')}</p><strong>{t(isMqtt ? 'eventDestinations.mqtt' : 'eventDestinations.webhook')}</strong></div></Card>
              <Field data-invalid={invalid === 'name' || undefined}><FieldLabel htmlFor="destination-name">{t('eventDestinations.name')}</FieldLabel><Input id="destination-name" value={draft.name} disabled={saving || editing} aria-invalid={invalid === 'name'} onChange={event => update('name', event.target.value)} placeholder={t('eventDestinations.namePlaceholder')} /></Field>
              {isMqtt ? <MqttFields draft={draft} saving={saving} editing={editing} invalid={invalid} update={update} qos={mqttQos} setQos={value => { setMqttQos(value); if (invalid === 'qos') setInvalid('') }} queueLimit={queueLimit} setQueueLimit={value => { setQueueLimit(value); if (invalid === 'queue_limit') setInvalid('') }} /> : <>
              <Field data-invalid={invalid === 'endpoint' || undefined}><FieldLabel htmlFor="destination-endpoint">{t('eventDestinations.endpoint')}</FieldLabel><Input id="destination-endpoint" value={draft.endpoint} disabled={saving} aria-invalid={invalid === 'endpoint'} onChange={event => update('endpoint', event.target.value)} placeholder="https://example.com/events" /></Field>
              <Field data-invalid={invalid === 'auth_token' || undefined}><FieldLabel htmlFor="destination-auth_token">{t('eventDestinations.authToken')}</FieldLabel><Input id="destination-auth_token" type="password" autoComplete="new-password" value={draft.auth_token} disabled={saving} aria-invalid={invalid === 'auth_token'} onChange={event => update('auth_token', event.target.value)} placeholder={t(draft.has_auth_token ? 'eventDestinations.keepToken' : 'eventDestinations.tokenPlaceholder')} />
                {editing && draft.has_auth_token && <Button variant="ghost" size="sm" type="button" className="self-start" disabled={saving} onClick={() => { update('has_auth_token', false); update('auth_token', '') }}>{t('eventDestinations.clearToken')}</Button>}
              </Field>
              <Field data-invalid={invalid === 'queue_limit' || undefined}><FieldLabel htmlFor="destination-queue_limit">{t('eventDestinations.queueLimit')}</FieldLabel><Input id="destination-queue_limit" inputMode="numeric" value={queueLimit} disabled={saving} aria-invalid={invalid === 'queue_limit'} onChange={event => { setQueueLimit(event.target.value); if (invalid === 'queue_limit') setInvalid('') }} placeholder={t('eventDestinations.queueLimitPlaceholder')} /></Field>
              {pathFields.map(field => <Field key={field} data-invalid={invalid === field || undefined}><FieldLabel htmlFor={`destination-${field}`}>{t(pathLabels[field])}</FieldLabel><Input id={`destination-${field}`} value={draft[field]} disabled={saving} aria-invalid={invalid === field} onChange={event => update(field, event.target.value)} placeholder={pathPlaceholders[field]} />{field === 'queue_directory' && <FieldDescription>{t('eventDestinations.pathHelp')}</FieldDescription>}</Field>)}
              <Field><FieldLabel htmlFor="destination-skip_tls_verify">{t('eventDestinations.skipTlsVerify')}</FieldLabel><OptionSelect id="destination-skip_tls_verify" value={String(draft.skip_tls_verify)} onValueChange={value => update('skip_tls_verify', value === 'true')} disabled={saving} options={[{ value: 'false', label: 'false' }, { value: 'true', label: 'true' }]} /></Field>
              </>}
              <Field data-invalid={invalid === 'comment' || undefined}><FieldLabel htmlFor="destination-comment">{t('eventDestinations.comment')}</FieldLabel><Input id="destination-comment" value={draft.comment} disabled={saving} aria-invalid={invalid === 'comment'} onChange={event => update('comment', event.target.value)} placeholder={t('eventDestinations.commentPlaceholder')} /></Field>
            </FieldGroup>}
          </div>
          <div className="ui-dialog-footer shrink-0"><Button type="button" variant="outline" disabled={saving} onClick={() => { setOpen(false); setDraft(newDestination()) }}>{t('common.cancel')}</Button><Button type="submit" disabled={!selected || saving}>{t('bucketEvents.save')}</Button></div>
        </form>
      </DialogContent>
    </Dialog>
  </section>
}

const mqttFields = [
  ['broker', 'mqttBroker'], ['topic', 'mqttTopic'], ['qos', 'mqttQos'],
  ['username', 'mqttUsername'], ['password', 'mqttPassword'],
  ['reconnect_interval', 'mqttReconnectInterval'], ['keep_alive_interval', 'mqttKeepAliveInterval'],
  ['queue_directory', 'mqttQueueDirectory'], ['queue_limit', 'mqttQueueLimit'],
  ['tls_policy', 'mqttTlsPolicy'], ['tls_ca', 'mqttTlsCa'],
  ['tls_client_certificate', 'mqttTlsClientCertificate'], ['tls_client_key', 'mqttTlsClientKey'],
  ['trust_leaf_as_ca', 'mqttTrustLeafAsCa'], ['websocket_path_allowlist', 'mqttWebSocketPathAllowlist'],
] as const

function MqttFields({ draft, saving, editing, invalid, update, qos, setQos, queueLimit, setQueueLimit }: {
  draft: EventDestination; saving: boolean; editing: boolean; invalid: keyof EventDestination | ''
  update: <K extends keyof EventDestination>(key: K, value: EventDestination[K]) => void
  qos: string; setQos: (value: string) => void; queueLimit: string; setQueueLimit: (value: string) => void
}) {
  return <>{mqttFields.map(([field, label]) => {
    const id = `destination-${field}`
    const placeholder = t(`eventDestinations.${label}Placeholder`)
    return <Field key={field} data-invalid={invalid === field || undefined}>
      <FieldLabel htmlFor={id}>{t(`eventDestinations.${label}`)}</FieldLabel>
      {field === 'trust_leaf_as_ca' ? <OptionSelect id={id} value={String(draft.trust_leaf_as_ca)} disabled={saving} onValueChange={value => update(field, value === 'true')} options={[{ value: 'false', label: 'false' }, { value: 'true', label: 'true' }]} />
        : field === 'qos' ? <OptionSelect id={id} value={qos} placeholder={placeholder} disabled={saving} aria-invalid={invalid === field} onValueChange={setQos} options={[{ value: '0', label: '0' }, { value: '1', label: '1' }, { value: '2', label: '2' }]} />
          : <Input id={id} value={field === 'queue_limit' ? queueLimit : draft[field]} type={field === 'password' ? 'password' : 'text'} autoComplete={field === 'password' ? 'new-password' : undefined} inputMode={field === 'queue_limit' ? 'numeric' : undefined} disabled={saving} aria-invalid={invalid === field} onChange={event => field === 'queue_limit' ? setQueueLimit(event.target.value) : update(field, event.target.value)} placeholder={field === 'password' && draft.has_password ? t('eventDestinations.keepPassword') : placeholder} />}
      {field === 'password' && editing && draft.has_password && <Button type="button" variant="ghost" size="sm" disabled={saving} className="self-start" onClick={() => { update('has_password', false); update('password', '') }}>{t('eventDestinations.clearPassword')}</Button>}
      {field === 'queue_directory' && <FieldDescription>{t('eventDestinations.pathHelp')}</FieldDescription>}
    </Field>
  })}</>
}
