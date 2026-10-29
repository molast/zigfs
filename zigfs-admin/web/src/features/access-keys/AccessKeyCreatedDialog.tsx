import { useId } from 'react'
import { Copy, Download, Info } from 'lucide-react'
import type { CreatedAccessKey } from '../../types/api'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Alert, AlertDescription, AlertTitle } from '../../components/ui/alert'

export function AccessKeyCreatedDialog({ value, onClose }: { value: CreatedAccessKey; onClose: () => void }) {
  const toast = useToast()
  function download() {
    try {
      const data = JSON.stringify({ access_key: value.access_key, secret_key: value.secret_key, session_token: value.session_token, owner: value.owner, expires_at: value.expires_at }, null, 2)
      const url = URL.createObjectURL(new Blob([data], { type: 'application/json' }))
      const anchor = document.createElement('a'); anchor.href = url; anchor.download = `zigfs-${value.access_key}.json`
      document.body.appendChild(anchor); anchor.click(); anchor.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      toast('Credentials downloaded')
    } catch { toast('下载失败，请复制凭证保存', 'error') }
  }
  return <Dialog open onOpenChange={open => { if (!open) onClose() }}><DialogContent className="identity-dialog created-key-dialog" showCloseButton={false}><DialogHeader><DialogTitle>New access key has been created</DialogTitle><DialogDescription className="sr-only">Copy or download the new credentials before closing.</DialogDescription></DialogHeader><div className="identity-form-body"><FieldGroup><Alert><Info /><AlertTitle>Warning</AlertTitle><AlertDescription>The secret key is shown only once. Copy or export it before closing.</AlertDescription></Alert><CredentialValue label="Access Key" value={value.access_key} /><CredentialValue label="Secret Key" value={value.secret_key} />{value.session_token && <CredentialValue label="Session Token" value={value.session_token} />}</FieldGroup></div><footer className="identity-form-footer"><Button type="button" variant="outline" onClick={onClose}>Close</Button><Button type="button" onClick={download}><Download data-icon="inline-start" />Download</Button></footer></DialogContent></Dialog>
}

function CredentialValue({ label, value }: { label: string; value: string }) {
  const id = useId()
  const toast = useToast()
  async function copy() {
    try { await navigator.clipboard.writeText(value); toast(`${label} copied`) }
    catch { toast('复制失败，请手动复制', 'error') }
  }
  return <Field><FieldLabel htmlFor={id}>{label}</FieldLabel><div className="flex items-center gap-2"><Input id={id} readOnly value={value} /><Button type="button" variant="ghost" size="icon" aria-label={`Copy ${label}`} onClick={() => void copy()}><Copy /></Button></div></Field>
}
