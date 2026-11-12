import { t } from '@/locales'
import { useId, useState } from 'react'
import { Copy, Download, Info } from 'lucide-react'
import type { CreatedAccessKey } from '../../types/api'
import type { ApiClient } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Alert, AlertDescription, AlertTitle } from '../../components/ui/alert'

export function AccessKeyCreatedDialog({ api, value, onClose }: { api: ApiClient; value: CreatedAccessKey; onClose: () => void }) {
  const toast = useToast()
  const [downloading, setDownloading] = useState(false)
  async function download() {
    if (downloading) return
    setDownloading(true)
    try {
      const settings = await api.settings()
      const data = JSON.stringify({
        url: settings.s3_public_endpoint || '',
        accessKey: value.access_key,
        secretKey: value.secret_key,
        api: 's3v4',
        path: settings.s3_virtual_hosted_style === true ? 'vhost' : settings.s3_virtual_hosted_style === false ? 'path' : 'auto',
      })
      const url = URL.createObjectURL(new Blob([data], { type: 'application/json' }))
      const anchor = document.createElement('a'); anchor.href = url; anchor.download = 'credentials.json'
      document.body.appendChild(anchor); anchor.click(); anchor.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      toast(t('access_keys.credentialsDownloaded'))
    } catch { toast(t('access_keys.downloadFailedCopyTheCredentialsToSaveThem'), 'error') }
    finally { setDownloading(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open) onClose() }}><DialogContent className="identity-dialog created-key-dialog" showCloseButton={false}><DialogHeader><DialogTitle>{t('access_keys.newAccessKeyHasBeenCreated')}</DialogTitle><DialogDescription className="sr-only">{t('access_keys.copyOrDownloadTheNewCredentialsBeforeClosing')}</DialogDescription></DialogHeader><div className="identity-form-body"><FieldGroup><Alert><Info /><AlertTitle>{t('access_keys.warning')}</AlertTitle><AlertDescription>{t('access_keys.theSecretKeyIsShownOnlyOnceCopyOr')}</AlertDescription></Alert><CredentialValue label={t('access_keys.accessKey')} value={value.access_key} /><CredentialValue label={t('access_keys.secretKey')} value={value.secret_key} />{value.session_token && <CredentialValue label={t('access_keys.sessionToken')} value={value.session_token} />}</FieldGroup></div><footer className="identity-form-footer"><Button type="button" variant="outline" onClick={onClose}>{t('access_keys.close')}</Button><Button type="button" disabled={downloading} onClick={() => void download()}><Download data-icon="inline-start" />{t('access_keys.download')}</Button></footer></DialogContent></Dialog>
}

function CredentialValue({ label, value }: { label: string; value: string }) {
  const id = useId()
  const toast = useToast()
  async function copy() {
    try { await navigator.clipboard.writeText(value); toast(t('access_keys.valueCopied', { '0': label })) }
    catch { toast(t('access_keys.unableToCopyPleaseCopyManually'), 'error') }
  }
  return <Field><FieldLabel htmlFor={id}>{label}</FieldLabel><div className="flex items-center gap-2"><Input id={id} readOnly value={value} /><Button type="button" variant="ghost" size="icon" aria-label={`Copy ${label}`} onClick={() => void copy()}><Copy /></Button></div></Field>
}
