import { useCallback, useEffect, useState } from 'react'
import { Plus, Pencil, Trash2, RefreshCw } from 'lucide-react'
import type { ApiClient } from '@/api/client'
import { t } from '@/locales'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Table, TableHeader, TableHead, TableRow, TableBody, TableCell } from '@/components/ui/table'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/Dialog'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { Empty, EmptyHeader, EmptyTitle } from '@/components/ui/empty'
import { useToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'
import { accessRules, parsePolicy, updateRule, type Access, type AccessRule } from './anonymousRules'

export function AnonymousAccess({ api, bucketName }: { api: ApiClient; bucketName: string }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [rules, setRules] = useState<AccessRule[]>([])
  const [ready, setReady] = useState(false)
  const [busy, setBusy] = useState(false)
  const [open, setOpen] = useState(false)
  const [editing, setEditing] = useState<string | null>(null)
  const [prefix, setPrefix] = useState('')
  const [access, setAccess] = useState<Access>('readonly')
  const refresh = useCallback(async () => {
    setBusy(true)
    try { const result = await api.getBucketPolicy(bucketName); setRules(accessRules(parsePolicy(result.document), bucketName)); setReady(true) }
    catch { toast(t('anonymousAccess.loadFailed'), 'error') }
    finally { setBusy(false) }
  }, [api, bucketName, toast])
  useEffect(() => { void refresh() }, [refresh])
  async function save(id: string, rule?: AccessRule) {
    setBusy(true)
    try {
      const [result, configuration] = await Promise.all([api.getBucketPolicy(bucketName), api.getBucketConfiguration(bucketName)])
      const policy = parsePolicy(result.document)
      // Preserve legacy public read grants when introducing a custom policy.
      if (!result.document && ['Readonly', 'Public'].includes(configuration.access_policy)) {
        policy.Statement.push({ Effect: 'Allow', Principal: '*', Action: ['s3:GetObject', 's3:GetObjectVersion'], Resource: `arn:aws:s3:::${bucketName}/*` })
        if (configuration.access_policy === 'Public') policy.Statement.push({ Effect: 'Allow', Principal: '*', Action: ['s3:ListBucket'], Resource: `arn:aws:s3:::${bucketName}` })
      }
      const current = accessRules(policy, bucketName)
      if ((editing || !rule) && !current.some(item => item.id === id)) throw new Error('Rule changed')
      if (editing && rule && current.some(item => item.id !== id && item.prefix === rule.prefix)) { toast(t('anonymousAccess.duplicate'), 'error'); return }
      const updated = await api.putBucketPolicy(bucketName, JSON.stringify(updateRule(policy, bucketName, id, rule ? { ...rule, id } : undefined)))
      setRules(accessRules(parsePolicy(updated.document), bucketName))
      if (rule && configuration.block_public_access) await api.updateBucketConfiguration(bucketName, { block_public_access: false })
      setOpen(false)
      toast(t('anonymousAccess.saved'), 'success')
    } catch { toast(t('anonymousAccess.saveFailed'), 'error') }
    finally { setBusy(false) }
  }
  return <div className="flex flex-col gap-6">
    <header className="flex flex-wrap items-start justify-between gap-4">
      <div><h3>{t('buckets.anonymousAccess')}</h3><p className="text-sm text-muted-foreground">{t('bucketEvents.bucket', { name: bucketName })}</p></div>
      <div className="flex gap-2"><Button size="sm" disabled={!ready || busy} onClick={() => { setEditing(null); setPrefix(''); setAccess('readonly'); setOpen(true) }}><Plus />{t('anonymousAccess.add')}</Button><Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw />{t('bucketEvents.refresh')}</Button></div>
    </header>
    <div className="rounded-lg border"><Table>
      <TableHeader><TableRow><TableHead>{t('anonymousAccess.prefix')}</TableHead><TableHead>{t('anonymousAccess.access')}</TableHead><TableHead><div className="flex justify-end">{t('bucketEvents.actions')}</div></TableHead></TableRow></TableHeader>
      <TableBody>{rules.map(rule => <TableRow key={rule.id}><TableCell>{rule.prefix || '*'}</TableCell><TableCell>{rule.access}</TableCell><TableCell><div className="flex justify-end gap-1">
        <Button variant="ghost" size="icon-sm" aria-label={t('bucketEvents.edit')} disabled={busy} onClick={() => { setEditing(rule.id); setPrefix(rule.prefix); setAccess(rule.access); setOpen(true) }}><Pencil /></Button>
        <Button variant="ghost" size="icon-sm" aria-label={t('bucketEvents.remove')} disabled={busy} onClick={() => void (async () => { if (await confirm({ title: t('bucketEvents.remove'), message: t('anonymousAccess.removeConfirm'), danger: true })) await save(rule.id) })()}><Trash2 /></Button>
      </div></TableCell></TableRow>)}
      {!rules.length && <TableRow><TableCell colSpan={3}><Empty className="min-h-56"><EmptyHeader><EmptyTitle>{t(busy ? 'bucketEvents.loading' : 'anonymousAccess.empty')}</EmptyTitle></EmptyHeader></Empty></TableCell></TableRow>}
      </TableBody>
    </Table></div>
    <Dialog open={open} onOpenChange={value => { if (!busy) setOpen(value) }}><DialogContent layout="form" onInteractOutside={event => event.preventDefault()}>
      <DialogHeader><DialogTitle>{t(editing ? 'anonymousAccess.edit' : 'anonymousAccess.add')}</DialogTitle></DialogHeader>
      <form onSubmit={event => { event.preventDefault(); if (new TextEncoder().encode(prefix).length > 1024 || /[\u0000*?]/.test(prefix)) { toast(t('anonymousAccess.invalidPrefix'), 'error'); return }; void save(editing ?? crypto.randomUUID().replaceAll('-', ''), { id: editing ?? '', prefix, access }) }}>
        <FieldGroup data-density="compact"><Field><FieldLabel htmlFor="anonymous-prefix">{t('anonymousAccess.prefix')}</FieldLabel><Input id="anonymous-prefix" value={prefix} onChange={event => setPrefix(event.target.value)} disabled={busy} placeholder={t('anonymousAccess.prefixPlaceholder')} /><FieldDescription>{t('anonymousAccess.prefixHelp')}</FieldDescription></Field>
          <Field><FieldLabel htmlFor="anonymous-access">{t('anonymousAccess.access')}</FieldLabel><OptionSelect id="anonymous-access" value={access} onValueChange={value => setAccess(value as Access)} disabled={busy} options={['readonly', 'writeonly', 'readwrite'].map(value => ({ value, label: value }))} /></Field></FieldGroup>
        <div className="ui-dialog-footer"><Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button type="submit" size="sm" disabled={busy}>{t('buckets.savePolicy')}</Button></div>
      </form>
    </DialogContent></Dialog>
  </div>
}
