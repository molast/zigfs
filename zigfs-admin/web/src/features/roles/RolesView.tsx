import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Plus, Pencil, Trash2, RefreshCw, KeyRound, Copy, Download } from 'lucide-react'
import { formatDateTime } from '@/lib/dateTime'
import { t } from '@/locales'
import type { ApiClient, Role, RoleSession, AssumeRoleResponse } from '@/api/client'
import { useToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Textarea } from '@/components/ui/Textarea'
import { Badge } from '@/components/ui/Badge'
import { Switch } from '@/components/ui/switch'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/Dialog'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { Table, TableHeader, TableHead, TableBody, TableRow, TableCell } from '@/components/ui/table'
import { Empty, EmptyHeader, EmptyTitle } from '@/components/ui/empty'
import { MultiChoice } from '../identities/IdentityMultiChoice'

const emptyTrust = JSON.stringify({ Version: '2012-10-17', Statement: [] }, null, 2)
const validName = (value: string, max = 128) => value.length > 0 && value.length <= max && /^[A-Za-z0-9_.-]+$/.test(value)
export function RolesView({ api }: { api: ApiClient }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [items, setItems] = useState<Role[]>([])
  const [sessions, setSessions] = useState<RoleSession[]>([])
  const [policies, setPolicies] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [ready, setReady] = useState(false)
  const [editing, setEditing] = useState<Role | null>(null)
  const [editorOpen, setEditorOpen] = useState(false)
  const [name, setName] = useState('')
  const [enabled, setEnabled] = useState(true)
  const [assigned, setAssigned] = useState<string[]>([])
  const [trust, setTrust] = useState(emptyTrust)
  const [maximum, setMaximum] = useState('3600')
  const [selected, setSelected] = useState<Role | null>(null)
  const [sessionName, setSessionName] = useState('console')
  const [duration, setDuration] = useState('3600')
  const [externalId, setExternalId] = useState('')
  const [sourceIdentity, setSourceIdentity] = useState('')
  const [issued, setIssued] = useState<AssumeRoleResponse | null>(null)
  const refresh = useCallback(async () => {
    const [roles, active, available] = await Promise.all([api.listRoles(), api.listRoleSessions(), api.listPolicies()])
    setItems(roles); setSessions(active); setPolicies(available.map(policy => policy.name)); setReady(true)
  }, [api])
  async function reload() {
    setBusy(true)
    try { await refresh() } catch { toast(t('roles.failedToLoad'), 'error') }
    finally { setBusy(false) }
  }
  useEffect(() => { setBusy(true); void refresh().catch(() => toast(t('roles.failedToLoad'), 'error')).finally(() => setBusy(false)) }, [refresh, toast])
  function edit(role: Role | null) {
    setEditing(role); setName(role?.name ?? ''); setEnabled(role?.enabled ?? true)
    setAssigned(role?.policies ?? []); setTrust(role?.trust_policy ?? emptyTrust)
    setMaximum(String(role?.max_session_seconds ?? 3600)); setEditorOpen(true)
  }
  async function save(event: FormEvent) {
    event.preventDefault()
    if (!validName(name.trim())) { toast(t('roleConsole.invalidName'), 'error'); return }
    if (!Number.isInteger(Number(maximum)) || Number(maximum) < 900 || Number(maximum) > 43200) { toast(t('roleConsole.invalidDuration'), 'error'); return }
    if (!assigned.length) { toast(t('roleConsole.policyRequired'), 'error'); return }
    try { const parsed = JSON.parse(trust); if (!parsed || !Array.isArray(parsed.Statement)) throw new Error() }
    catch { toast(t('roleConsole.invalidTrust'), 'error'); return }
    setBusy(true)
    try {
      const role: Role = { ...editing, id: editing?.id ?? '', name: name.trim(), enabled, policies: assigned, trust_policy: trust, max_session_seconds: Number(maximum) }
      await (editing ? api.updateRole(role) : api.createRole(role))
      setEditorOpen(false); toast(t('roleConsole.saved'), 'success')
      await refresh()
    } catch { toast(t('roles.saveFailed'), 'error') }
    finally { setBusy(false) }
  }
  async function remove(role: Role) {
    if (!await confirm({ title: t('roles.delete'), message: t('roleConsole.deleteConfirm', { name: role.name }), danger: true })) return
    setBusy(true)
    try {
      await api.deleteRole(role.name)
      toast(t('roles.deleted'), 'success')
      try { await refresh() } catch { toast(t('roles.failedToLoad'), 'error') }
    }
    catch { toast(t('roleConsole.deleteFailed'), 'error') }
    finally { setBusy(false) }
  }
  async function assume(event: FormEvent) {
    event.preventDefault()
    if (!selected) return
    if (!validName(sessionName, 64)) { toast(t('roleConsole.invalidSessionName'), 'error'); return }
    if (!Number.isInteger(Number(duration)) || Number(duration) < 900 || Number(duration) > Math.min(43200, selected.max_session_seconds)) { toast(t('roleConsole.durationLimit', { seconds: selected.max_session_seconds }), 'error'); return }
    setBusy(true)
    try {
      const result = await api.assumeRole({ role_id: selected.id, session_name: sessionName, duration_seconds: Number(duration), external_id: externalId || undefined, source_identity: sourceIdentity || undefined })
      setSelected(null); setIssued(result); toast(t('roles.temporaryCredentialsIssued'), 'success')
      try { await refresh() } catch { toast(t('roles.failedToLoad'), 'error') }
    } catch { toast(t('roleConsole.assumeFailed'), 'error') }
    finally { setBusy(false) }
  }
  async function revoke(session: RoleSession) {
    if (!await confirm({ title: t('roles.revoke'), message: t('roleConsole.revokeConfirm'), danger: true })) return
    setBusy(true)
    try { await api.revokeRoleSession(session.access_key); await refresh(); toast(t('roles.sessionRevoked'), 'success') }
    catch { toast(t('roles.failedToRevokeSession'), 'error') }
    finally { setBusy(false) }
  }
  async function deleteSession(session: RoleSession) {
    if (!await confirm({ title: t('roles.delete'), message: t('roleConsole.deleteSessionConfirm'), danger: true })) return
    setBusy(true)
    try { await api.deleteRoleSession(session.access_key); await refresh(); toast(t('roleConsole.sessionDeleted'), 'success') }
    catch { toast(t('roleConsole.deleteSessionFailed'), 'error') }
    finally { setBusy(false) }
  }
  async function copy(value: string) {
    try { await navigator.clipboard.writeText(value); toast(t('roleConsole.copied'), 'success') }
    catch { toast(t('roleConsole.copyFailed'), 'error') }
  }
  function download() {
    if (!issued) return
    const url = URL.createObjectURL(new Blob([JSON.stringify({ accessKey: issued.access_key, secretKey: issued.secret_key, sessionToken: issued.session_token, expiresAt: issued.expires_at, api: 's3v4', path: 'auto' })], { type: 'application/json' }))
    const link = document.createElement('a'); link.href = url; link.download = 'sts-credentials.json'; document.body.appendChild(link); link.click(); link.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }
  return <section className="flex flex-col gap-6">
    <header className="flex flex-wrap items-start justify-between gap-4"><div><h2>{t('roles.roles')}</h2><p className="text-sm text-muted-foreground">{t('roleConsole.description')}</p></div><div className="flex gap-2"><Button size="sm" disabled={busy || !ready} onClick={() => edit(null)}><Plus />{t('roleConsole.create')}</Button><Button size="sm" variant="outline" disabled={busy} onClick={() => void reload()}><RefreshCw />{t('bucketEvents.refresh')}</Button></div></header>
    <div className="rounded-lg border"><Table><TableHeader><TableRow><TableHead>{t('roles.name')}</TableHead><TableHead>{t('roles.status')}</TableHead><TableHead>{t('navigation.policies')}</TableHead><TableHead>{t('roleConsole.maxDuration')}</TableHead><TableHead><div className="flex justify-end">{t('roles.actions')}</div></TableHead></TableRow></TableHeader><TableBody>
      {items.map(role => <TableRow key={role.id}><TableCell>{role.name}</TableCell><TableCell><Badge>{t(role.enabled ? 'roles.enabled' : 'roles.disabled')}</Badge></TableCell><TableCell><div className="flex flex-wrap gap-1">{role.policies?.map(policy => <Badge key={policy}>{policy}</Badge>)}</div></TableCell><TableCell>{role.max_session_seconds}</TableCell><TableCell><div className="flex justify-end gap-1"><Button size="sm" variant="outline" disabled={busy || !role.enabled} onClick={() => { setSelected(role); setSessionName('console'); setDuration(String(Math.min(role.max_session_seconds, 3600))); setExternalId(''); setSourceIdentity('') }}><KeyRound />{t('roleConsole.assume')}</Button><Button size="icon-sm" variant="ghost" aria-label={t('roles.edit')} disabled={busy} onClick={() => edit(role)}><Pencil /></Button><Button size="icon-sm" variant="ghost" aria-label={t('roles.delete')} disabled={busy} onClick={() => void remove(role)}><Trash2 /></Button></div></TableCell></TableRow>)}
      {!items.length && <TableRow><TableCell colSpan={5}><Empty><EmptyHeader><EmptyTitle>{t(busy ? 'bucketEvents.loading' : ready ? 'roleConsole.empty' : 'roles.failedToLoad')}</EmptyTitle></EmptyHeader></Empty></TableCell></TableRow>}
    </TableBody></Table></div>
    <h3>{t('roleConsole.sessions')}</h3>
    <div className="rounded-lg border"><Table><TableHeader><TableRow><TableHead>{t('roles.session')}</TableHead><TableHead>{t('roles.roles')}</TableHead><TableHead>{t('roles.accessKey')}</TableHead><TableHead>{t('roles.expires')}</TableHead><TableHead>{t('roles.status')}</TableHead><TableHead /></TableRow></TableHeader><TableBody>
      {sessions.map(session => { const expired = session.expires_at * 1000 <= Date.now(); return <TableRow key={session.access_key}><TableCell>{session.session_name}</TableCell><TableCell>{items.find(role => role.id === session.role_id)?.name ?? session.role_id}</TableCell><TableCell>{session.access_key}</TableCell><TableCell>{formatDateTime(session.expires_at * 1000)}</TableCell><TableCell>{t(session.revoked ? 'roleConsole.revoked' : expired ? 'roleConsole.expired' : 'roleConsole.active')}</TableCell><TableCell><div className="flex justify-end gap-2"><Button size="sm" variant="outline" disabled={busy || expired || session.revoked} onClick={() => void revoke(session)}>{t('roles.revoke')}</Button>{session.revoked && <Button size="sm" variant="destructive" disabled={busy} onClick={() => void deleteSession(session)}>{t('roles.delete')}</Button>}</div></TableCell></TableRow> })}
      {!sessions.length && <TableRow><TableCell colSpan={6}><Empty><EmptyHeader><EmptyTitle>{t('roleConsole.noSessions')}</EmptyTitle></EmptyHeader></Empty></TableCell></TableRow>}
    </TableBody></Table></div>
    <Dialog open={editorOpen} onOpenChange={open => { if (!busy) setEditorOpen(open) }}><DialogContent layout="form" className="role-console-dialog" onInteractOutside={event => event.preventDefault()}><DialogHeader><DialogTitle>{t(editing ? 'roleConsole.edit' : 'roleConsole.create')}</DialogTitle></DialogHeader><form noValidate onSubmit={save}><FieldGroup data-density="compact">
      <Field><FieldLabel htmlFor="role-name">{t('roles.name')}</FieldLabel><Input id="role-name" value={name} disabled={busy || !!editing} onChange={event => setName(event.target.value)} /></Field>
      <MultiChoice title={t('navigation.policies')} placeholder={t('identities.selectUserGroupPolicies')} options={policies} selected={assigned} onChange={setAssigned} disabled={busy} />
      <Field><FieldLabel htmlFor="role-maximum">{t('roleConsole.maxDuration')}</FieldLabel><Input id="role-maximum" type="number" min={900} max={43200} value={maximum} disabled={busy} onChange={event => setMaximum(event.target.value)} /></Field>
      <Field><FieldLabel htmlFor="role-trust">{t('roles.trustPolicy')}</FieldLabel><Textarea id="role-trust" rows={6} value={trust} disabled={busy} onChange={event => setTrust(event.target.value)} spellCheck={false} /><FieldDescription>{t('roleConsole.trustHelp')}</FieldDescription></Field>
      <Field orientation="horizontal"><FieldLabel htmlFor="role-enabled">{t('roles.enabled')}</FieldLabel><Switch id="role-enabled" checked={enabled} disabled={busy} onCheckedChange={setEnabled} /></Field>
    </FieldGroup><div className="ui-dialog-footer"><Button size="sm" variant="outline" type="button" disabled={busy} onClick={() => setEditorOpen(false)}>{t('common.cancel')}</Button><Button size="sm" type="submit" disabled={busy}>{t('roles.save')}</Button></div></form></DialogContent></Dialog>
    <Dialog open={!!selected} onOpenChange={open => { if (!open && !busy) setSelected(null) }}><DialogContent layout="form" className="role-console-dialog" onInteractOutside={event => event.preventDefault()}><DialogHeader><DialogTitle>{t('roleConsole.assume')}</DialogTitle><DialogDescription>{selected?.name}</DialogDescription></DialogHeader><form noValidate onSubmit={assume}><FieldGroup data-density="compact">
      <Field><FieldLabel htmlFor="role-session-name">{t('roles.sessionName')}</FieldLabel><Input id="role-session-name" value={sessionName} disabled={busy} onChange={event => setSessionName(event.target.value)} /></Field>
      <Field><FieldLabel htmlFor="role-duration">{t('roleConsole.duration')}</FieldLabel><Input id="role-duration" type="number" min={900} max={selected?.max_session_seconds} value={duration} disabled={busy} onChange={event => setDuration(event.target.value)} /></Field>
      <Field><FieldLabel htmlFor="role-external">{t('roleConsole.externalId')}</FieldLabel><Input id="role-external" value={externalId} maxLength={1024} disabled={busy} onChange={event => setExternalId(event.target.value)} /></Field>
      <Field><FieldLabel htmlFor="role-source">{t('roleConsole.sourceIdentity')}</FieldLabel><Input id="role-source" value={sourceIdentity} maxLength={128} disabled={busy} onChange={event => setSourceIdentity(event.target.value)} /></Field>
    </FieldGroup><div className="ui-dialog-footer"><Button type="button" size="sm" variant="outline" disabled={busy} onClick={() => setSelected(null)}>{t('common.cancel')}</Button><Button size="sm" type="submit" disabled={busy}>{t('roleConsole.assume')}</Button></div></form></DialogContent></Dialog>
    <Dialog open={!!issued} onOpenChange={open => { if (!open) setIssued(null) }}><DialogContent layout="form" className="role-console-dialog" onInteractOutside={event => event.preventDefault()}><DialogHeader><DialogTitle>{t('roles.temporaryCredentialsIssued')}</DialogTitle><DialogDescription>{t('roleConsole.credentialsHelp')}</DialogDescription></DialogHeader>{issued && <><FieldGroup data-density="compact">{([{ key: 'access_key', label: 'roles.accessKey' }, { key: 'secret_key', label: 'roles.secretKey' }, { key: 'session_token', label: 'roles.sessionToken' }] as const).map(field => <Field key={field.key}><FieldLabel htmlFor={`sts-issued-${field.key}`}>{t(field.label)}</FieldLabel><div className="flex items-center gap-2"><Input id={`sts-issued-${field.key}`} readOnly value={issued[field.key]} /><Button variant="ghost" size="icon-sm" aria-label={t('roleConsole.copy')} onClick={() => void copy(issued[field.key])}><Copy /></Button></div></Field>)}<FieldDescription>{t('roles.expires')}: {formatDateTime(issued.expires_at * 1000)}</FieldDescription></FieldGroup><div className="ui-dialog-footer"><Button size="sm" variant="outline" onClick={() => setIssued(null)}>{t('access_keys.close')}</Button><Button size="sm" onClick={download}><Download />{t('access_keys.download')}</Button></div></>}</DialogContent></Dialog>
  </section>
}
