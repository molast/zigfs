import { formatDateTime } from '@/lib/dateTime'
import { useCallback, useEffect, useState } from 'react'
import { ChevronLeft, ChevronRight, Plus, RefreshCw } from 'lucide-react'
import type { ApiClient, KmsKey, KmsKeyAction, KmsKeyList } from '@/api/client'
import { t } from '@/locales'
import { useConfirm } from '@/components/ConfirmProvider'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { Button } from '@/components/ui/Button'
import { Badge } from '@/components/ui/Badge'
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/Card'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/Dialog'
import { DropdownMenu, DropdownMenuContent, DropdownMenuGroup, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/Input'
import { Checkbox } from '@/components/ui/checkbox'

const pageSize = 20
function dateLabel(value: string | null) {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? value : formatDateTime(date)
}
export function KmsKeysPanel({ api, onDefaultChanged }: { api: ApiClient; onDefaultChanged: () => Promise<void> }) {
  const [data, setData] = useState<KmsKeyList | null>(null)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(0)
  const [createOpen, setCreateOpen] = useState(false)
  const [details, setDetails] = useState<KmsKey | null>(null)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [setAsDefault, setSetAsDefault] = useState(false)
  const toast = useToast()
  const notifyError = useErrorToast()
  const confirm = useConfirm()
  const load = useCallback(async () => {
    setLoading(true)
    try {
      const next = await api.kmsKeys()
      setData(next)
      setPage(current => Math.min(current, Math.max(0, Math.ceil(next.items.length / pageSize) - 1)))
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) }
    finally { setLoading(false) }
  }, [api, notifyError])
  useEffect(() => { void load() }, [load])
  const create = async () => {
    if (busy) return
    setBusy(true)
    try {
      await api.createKmsKey({ name, description, setAsDefault })
      setCreateOpen(false)
      toast(t('settings.kmsKeyCreated'))
      if (setAsDefault) await onDefaultChanged()
      await load()
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) }
    finally { setBusy(false) }
  }
  const lastKey = (data?.items.length ?? 0) <= 1
  const act = async (key: KmsKey, action: KmsKeyAction) => {
    if ((action === 'delete' || action === 'schedule-deletion') && lastKey) {
      notifyError(t('settings.kmsLastKeyProtected'))
      return
    }
    const label = action === 'delete' ? t('settings.kmsKeyDeleteNow') : action === 'rotate' ? t('settings.kmsKeyRotate') : action === 'cancel-deletion' ? t('settings.kmsKeyCancelDeletion') : t('settings.kmsKeyScheduleDeletion')
    if (action !== 'cancel-deletion' && !await confirm({
      title: action === 'delete' ? t('settings.kmsKeyDeleteTitle') : label,
      confirmLabel: action === 'delete' ? t('settings.kmsKeyDeleteTitle') : label,
      details: action === 'delete' ? `${t('settings.kmsKeyId')}: ${key.id}` : undefined,
      message: t(action === 'delete' ? 'settings.kmsKeyDeleteWarning' : action === 'rotate' ? 'settings.kmsKeyRotateConfirmation' : 'settings.kmsKeyScheduleConfirmation', { key: key.id }),
      danger: action === 'delete' || action === 'schedule-deletion',
    })) return
    setBusy(true)
    try {
      await api.kmsKeyAction(key.id, action)
      toast(t('settings.kmsKeyUpdated'))
      await load()
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) }
    finally { setBusy(false) }
  }
  return <>
    <Card>
      <CardHeader>
        <div className="kms-keys-heading">
          <div><CardTitle>{t('settings.kmsKeysManagement')}</CardTitle><CardDescription>{t('settings.kmsCreateKeyDescription')}</CardDescription></div>
          <div className="kms-key-buttons">
            <Button type="button" variant="outline" size="sm" disabled={busy || loading} onClick={() => void load()}><RefreshCw data-icon="inline-start" />{t('settings.kmsRefresh')}</Button>
            <Button type="button" size="sm" disabled={busy || !data?.canCreate} onClick={() => { setName(''); setDescription(''); setSetAsDefault(false); setCreateOpen(true) }}><Plus data-icon="inline-start" />{t('settings.kmsCreateKey')}</Button>
          </div>
        </div>
      </CardHeader>
      <CardContent className="kms-key-content">
        <Alert><AlertTitle>{t('settings.kmsTwoStageDeletion')}</AlertTitle><AlertDescription>{lastKey ? t('settings.kmsLastKeyProtected') : t('settings.kmsTwoStageDeletionHelp')}</AlertDescription></Alert>
        <Table>
          <TableHeader><TableRow>{[
            t('settings.kmsKeyName'), t('settings.kmsKeyId'), t('settings.kmsStatus'), t('settings.kmsKeyAlgorithm'), t('settings.kmsKeyUsage'), t('settings.kmsKeyCreatedAt'), t('settings.kmsKeyActions'),
          ].map(label => <TableHead key={label}>{label}</TableHead>)}</TableRow></TableHeader>
          <TableBody>
            {!data?.items.length && <TableRow><TableCell colSpan={7}>{loading ? t('settings.kmsKeysLoading') : data ? t('settings.kmsKeysEmpty') : t('settings.kmsKeysLoadFailed')}</TableCell></TableRow>}
            {data?.items.slice(page * pageSize, (page + 1) * pageSize).map(key => <TableRow key={key.id}>
              <TableCell>{key.name || key.description || '—'}</TableCell>
              <TableCell>{key.id}</TableCell>
              <TableCell><Badge variant={key.status === 'PendingDeletion' ? 'destructive' : 'default'}>{key.status}</Badge></TableCell>
              <TableCell>{key.algorithm}</TableCell><TableCell>{key.usage}</TableCell><TableCell>{dateLabel(key.createdAt)}</TableCell>
              <TableCell><DropdownMenu><DropdownMenuTrigger asChild><Button type="button" variant="outline" size="sm" disabled={busy}>{t('settings.kmsKeyActions')}</Button></DropdownMenuTrigger>
                <DropdownMenuContent align="end"><DropdownMenuGroup>
                  <DropdownMenuItem onSelect={() => setDetails(key)}>{t('settings.kmsKeyDetails')}</DropdownMenuItem>
                  {key.manageable && (key.status === 'PendingDeletion' ? <>
                    <DropdownMenuItem onSelect={() => void act(key, 'cancel-deletion')}>{t('settings.kmsKeyCancelDeletion')}</DropdownMenuItem>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem variant="destructive" disabled={lastKey || loading} onSelect={() => void act(key, 'delete')}>{t('settings.kmsKeyDeleteNow')}</DropdownMenuItem>
                  </> : <>
                    <DropdownMenuItem onSelect={() => void act(key, 'rotate')}>{t('settings.kmsKeyRotate')}</DropdownMenuItem>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem variant="destructive" disabled={lastKey || loading} onSelect={() => void act(key, 'schedule-deletion')}>{t('settings.kmsKeyScheduleDeletion')}</DropdownMenuItem>
                    <DropdownMenuItem variant="destructive" disabled={lastKey || loading} onSelect={() => void act(key, 'delete')}>{t('settings.kmsKeyDeleteNow')}</DropdownMenuItem>
                  </>)}
                </DropdownMenuGroup></DropdownMenuContent>
              </DropdownMenu></TableCell>
            </TableRow>)}
          </TableBody>
        </Table>
      </CardContent>
      <CardFooter className="kms-keys-pagination">
        <CardDescription>{t('settings.kmsKeysPageSize', { count: pageSize })}</CardDescription>
        <div className="kms-key-buttons"><Button type="button" variant="outline" size="sm" disabled={page === 0 || busy || loading} onClick={() => setPage(page - 1)}><ChevronLeft data-icon="inline-start" />{t('settings.kmsPrevious')}</Button><Button type="button" variant="outline" size="sm" disabled={(page + 1) * pageSize >= (data?.items.length ?? 0) || busy || loading} onClick={() => setPage(page + 1)}>{t('settings.kmsNext')}<ChevronRight data-icon="inline-end" /></Button></div>
      </CardFooter>
    </Card>
    <Card><CardHeader><CardTitle>{t('settings.kmsRekeyTitle')}</CardTitle><CardDescription>{t('settings.kmsRekeyDescription')}</CardDescription></CardHeader>
      <CardContent><Alert><AlertTitle>{t('settings.kmsRekeyUnavailable')}</AlertTitle><AlertDescription>{t('settings.kmsRekeyUnavailableHelp')}</AlertDescription></Alert></CardContent>
    </Card>
    <Dialog open={createOpen} onOpenChange={open => { if (!busy) setCreateOpen(open) }}>
      <DialogContent layout="form" showCloseButton={!busy}>
        <DialogHeader><DialogTitle>{t('settings.kmsCreateNewKey')}</DialogTitle><DialogDescription>{t('settings.kmsCreateKeyDescription')}</DialogDescription></DialogHeader>
        <form className="kms-key-dialog-form" onSubmit={event => { event.preventDefault(); void create() }}>
          <FieldGroup>
            <Field><FieldLabel htmlFor="kms-key-name">{t('settings.kmsKeyName')}</FieldLabel><Input id="kms-key-name" value={name} maxLength={256} disabled={busy} placeholder={t('settings.kmsKeyNamePlaceholder')} onChange={event => setName(event.target.value)} /></Field>
            <Field><FieldLabel htmlFor="kms-key-description">{t('settings.kmsKeyDescription')}</FieldLabel><Input id="kms-key-description" value={description} maxLength={4096} disabled={busy} placeholder={t('settings.kmsKeyDescriptionPlaceholder')} onChange={event => setDescription(event.target.value)} /></Field>
            <Field orientation="horizontal" className="rounded-md border border-border p-4"><Checkbox id="kms-key-default" checked={setAsDefault} disabled={busy} onCheckedChange={checked => setSetAsDefault(checked === true)} /><div><FieldLabel htmlFor="kms-key-default">{t('settings.kmsKeySetDefault')}</FieldLabel><FieldDescription>{t('settings.kmsKeySetDefaultHelp')}</FieldDescription></div></Field>
          </FieldGroup>
          <div className="kms-key-buttons kms-key-dialog-actions"><Button type="button" variant="outline" disabled={busy} onClick={() => setCreateOpen(false)}>{t('common.cancel')}</Button><Button type="submit" disabled={busy}>{t('settings.kmsCreateKey')}</Button></div>
        </form>
      </DialogContent>
    </Dialog>
    <Sheet open={Boolean(details)} onOpenChange={open => { if (!open) setDetails(null) }}>
      <SheetContent side="right" className="kms-key-details-sheet">
        <SheetHeader className="kms-key-details-header"><SheetTitle>{t('settings.kmsKeyDetailsTitle')}</SheetTitle><SheetDescription>{details?.id}</SheetDescription></SheetHeader>
        {details && <div className="kms-key-details-body">
          <dl className="kms-key-details-grid">{[
            [t('settings.kmsKeyName'), details.name || details.description || '—'],
            [t('settings.kmsStatus'), <Badge variant={details.status === 'PendingDeletion' ? 'destructive' : 'default'}>{details.status}</Badge>],
            [t('settings.kmsKeyId'), details.id], [t('settings.kmsKeyUsage'), details.usage],
            [t('settings.kmsKeyCreatedAt'), dateLabel(details.createdAt)], [t('settings.kmsKeyDeletionDate'), dateLabel(details.deletionDate)],
            [t('settings.kmsKeyAlgorithm'), details.algorithm], [t('settings.kmsKeyVersion'), String(details.version)],
            [t('settings.kmsKeyRotatedAt'), dateLabel(details.rotatedAt)],
          ].map(([label, value]) => <div key={String(label)}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
          <dl className="kms-key-details-sections">
            <div><dt>{t('settings.kmsKeyDescription')}</dt><dd>{details.description || '—'}</dd></div>
            <div><dt>{t('settings.kmsKeyTags')}</dt><dd>{t('settings.kmsKeyNoTagInformation')}</dd></div>
          </dl>
        </div>}
      </SheetContent>
    </Sheet>
  </>
}
