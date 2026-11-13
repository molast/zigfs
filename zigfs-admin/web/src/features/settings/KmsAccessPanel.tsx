import { useState, type FormEvent } from 'react'
import type { ApiClient, KmsKey } from '@/api/client'
import type { AdminSession } from '@/types/api'
import { t } from '@/locales'
import { useErrorToast } from '@/components/ToastProvider'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/Card'
import { Field, FieldLabel, FieldGroup } from '@/components/ui/field'
import { KmsKeysPanel } from './KmsKeysPanel'

const defaultChanged = async () => {}
export function KmsAccessPanel({ api, capabilities }: { api: ApiClient; capabilities: AdminSession['capabilities'] }) {
  const [id, setId] = useState('')
  const [key, setKey] = useState<KmsKey | null>(null)
  const [busy, setBusy] = useState(false)
  const notifyError = useErrorToast()
  async function lookup(event: FormEvent) {
    event.preventDefault()
    if (!id.trim()) { notifyError(t('settings.kmsKeyIdRequired')); return }
    setBusy(true); setKey(null)
    try { setKey(await api.describeKmsKey(id.trim())) }
    catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) }
    finally { setBusy(false) }
  }
  return <section className="flex flex-col gap-4">
    <Card><CardHeader><CardTitle>{t('settings.kmsAccessTitle')}</CardTitle><CardDescription>{t('settings.kmsAccessDescription')}</CardDescription></CardHeader>
      <CardContent><p className="text-sm text-muted-foreground">{t('settings.kmsUsageOnly')}</p></CardContent>
    </Card>
    {capabilities?.kms_list ? <KmsKeysPanel api={api} onDefaultChanged={defaultChanged} allowDefaultChange={false} /> : capabilities?.kms_describe ? <Card>
      <CardHeader><CardTitle>{t('settings.kmsKeyDetailsTitle')}</CardTitle><CardDescription>{t('settings.kmsLookupDescription')}</CardDescription></CardHeader>
      <CardContent><form onSubmit={lookup} noValidate><FieldGroup><Field><FieldLabel htmlFor="kms-lookup-id">{t('settings.kmsKeyId')}</FieldLabel><div className="flex gap-2"><Input id="kms-lookup-id" value={id} disabled={busy} onChange={event => setId(event.target.value)} /><Button type="submit" disabled={busy}>{t('settings.kmsLookup')}</Button></div></Field></FieldGroup></form>
        {key && <dl className="kms-key-details-grid">{[[t('settings.kmsKeyId'), key.id], [t('settings.kmsKeyName'), key.name || '—'], [t('settings.kmsStatus'), key.status], [t('settings.kmsKeyAlgorithm'), key.algorithm], [t('settings.kmsKeyVersion'), key.version]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>}
      </CardContent>
    </Card> : null}
  </section>
}
