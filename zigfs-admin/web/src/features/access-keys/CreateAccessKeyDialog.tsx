import { t } from '@/locales'
import { useId, useState, type FormEvent } from 'react'
import { Eye, EyeOff, RefreshCw } from 'lucide-react'
import type { AccessKeyCreate, CreatedAccessKey } from '../../types/api'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Field, FieldContent, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from '../../components/ui/input-group'
import { AccessKeyExpiryField } from './AccessKeyExpiryField'
import { Switch } from '../../components/ui/switch'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '../../components/ui/select'

function randomKey(length: number) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  let value = ''
  while (value.length < length) {
    const bytes = crypto.getRandomValues(new Uint8Array(length))
    for (const byte of bytes) if (byte < 248 && value.length < length) value += alphabet[byte % alphabet.length]
  }
  return value
}

export function CreateAccessKeyDialog({ userName, onCreate, onCreated, onClose }: {
  userName?: string
  onCreate: (value: AccessKeyCreate) => Promise<CreatedAccessKey>
  onCreated: (value: CreatedAccessKey) => void
  onClose: () => void
}) {
  const id = useId()
  const toast = useToast()
  const [accessKey, setAccessKey] = useState(() => randomKey(20))
  const [secretKey, setSecretKey] = useState(() => randomKey(40))
  const [showSecret, setShowSecret] = useState(false)
  const [expiry, setExpiry] = useState<Date>()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [inherit, setInherit] = useState(true)
  const [permission, setPermission] = useState('read-only')
  const [saving, setSaving] = useState(false)
  const [invalid, setInvalid] = useState<string | null>(null)
  async function submit(event: FormEvent) {
    event.preventDefault(); event.stopPropagation()
    if (saving) return
    const fail = (field: string, message: string) => { setInvalid(field); toast(message, 'error') }
    if (!/^[A-Za-z0-9]{16,128}$/.test(accessKey)) return fail('access', t('access_keys.accessKeyMustContain16128LettersOrNumbers'))
    if (!/^[\x21-\x7e]{32,64}$/.test(secretKey)) return fail('secret', t('access_keys.secretKeyMustContain3264PrintableAsciiCharacters'))
    if (new TextEncoder().encode(name).length > 128) return fail('name', t('access_keys.nameMustNotExceed128Bytes'))
    if (new TextEncoder().encode(description).length > 1024) return fail('description', t('access_keys.descriptionMustNotExceed1024Bytes'))
    const expiresAt = expiry ? new Date(expiry) : undefined
    if (expiresAt && expiresAt.getTime() <= Date.now()) return fail('expiry', t('access_keys.expiryMustBeInTheFuture'))
    setInvalid(null); setSaving(true)
    try {
      const created = await onCreate({ access_key: accessKey, secret_key: secretKey, name, description, inherit_policy: inherit,
        ...(expiresAt ? { expires_at: expiresAt.toISOString() } : {}),
        ...(!inherit ? { policy: { bucket_read: true, object_read: true, bucket_write: permission === 'read-write', object_write: permission === 'read-write', bypass_governance_retention: false } } : {}),
      })
      onCreated(created); toast(t('access_keys.accessKeyCreated'))
    } catch (reason) { toast(reason instanceof Error ? reason.message : t('access_keys.creationFailedPleaseTryAgain'), 'error') }
    finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog create-key-dialog">
    <DialogHeader><DialogTitle>{t('access_keys.createKey')}</DialogTitle><DialogDescription className="sr-only">{userName ? t('access_keys.createAnAccessKeyForValue', { '0': userName }) : t('access_keys.createAnAccessKeyForTheCurrentAdministrator')}</DialogDescription></DialogHeader>
    <form className="identity-form" onSubmit={event => void submit(event)} noValidate><div className="identity-form-body"><FieldGroup>
      <Field data-invalid={invalid === 'access' || undefined}><FieldLabel htmlFor={`${id}-access`}>{t('access_keys.accessKey')}</FieldLabel><InputGroup><InputGroupInput id={`${id}-access`} value={accessKey} maxLength={128} disabled={saving} autoComplete="off" aria-invalid={invalid === 'access'} onChange={event => setAccessKey(event.target.value)} /><InputGroupAddon align="inline-end"><InputGroupButton type="button" disabled={saving} aria-label={t('access_keys.generateAccessKey')} onClick={() => setAccessKey(randomKey(20))}><RefreshCw /></InputGroupButton></InputGroupAddon></InputGroup></Field>
      <Field data-invalid={invalid === 'secret' || undefined}><FieldLabel htmlFor={`${id}-secret`}>{t('access_keys.secretKey')}</FieldLabel><InputGroup><InputGroupInput id={`${id}-secret`} type={showSecret ? 'text' : 'password'} value={secretKey} disabled={saving} maxLength={64} autoComplete="new-password" aria-invalid={invalid === 'secret'} onChange={event => setSecretKey(event.target.value)} /><InputGroupAddon align="inline-end"><InputGroupButton type="button" disabled={saving} aria-label={showSecret ? t('access_keys.hideSecretKey') : t('access_keys.showSecretKey')} onClick={() => setShowSecret(current => !current)}>{showSecret ? <EyeOff /> : <Eye />}</InputGroupButton><InputGroupButton type="button" disabled={saving} aria-label={t('access_keys.generateSecretKey')} onClick={() => setSecretKey(randomKey(40))}><RefreshCw /></InputGroupButton></InputGroupAddon></InputGroup></Field>
      <AccessKeyExpiryField value={expiry} onChange={setExpiry} disabled={saving} invalid={invalid === 'expiry'} />
      <Field data-invalid={invalid === 'name' || undefined}><FieldLabel htmlFor={`${id}-name`}>{t('access_keys.name')}</FieldLabel><Input id={`${id}-name`} value={name} maxLength={128} disabled={saving} aria-invalid={invalid === 'name'} onChange={event => setName(event.target.value)} /></Field>
      <Field data-invalid={invalid === 'description' || undefined}><FieldLabel htmlFor={`${id}-description`}>{t('access_keys.description')}</FieldLabel><Textarea id={`${id}-description`} value={description} maxLength={1024} disabled={saving} aria-invalid={invalid === 'description'} onChange={event => setDescription(event.target.value)} /></Field>
      <Field orientation="horizontal" className="rounded-md border p-4"><FieldContent><FieldLabel htmlFor={`${id}-inherit`}>{t('access_keys.useParentAccountPermissions')}</FieldLabel><FieldDescription>{userName ? t('access_keys.usesTheUserAndEnabledGroupPoliciesTurnOff') : t('access_keys.automaticallyInheritTheMainAccountPolicyWhenEnabled')}</FieldDescription></FieldContent><Switch id={`${id}-inherit`} checked={inherit} disabled={saving} onCheckedChange={setInherit} /></Field>
      {!inherit && <Field><FieldLabel htmlFor={`${id}-permissions`}>{t('access_keys.permissions')}</FieldLabel><Select value={permission} onValueChange={setPermission} disabled={saving}><SelectTrigger id={`${id}-permissions`}><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="read-only">{t('access_keys.readOnly')}</SelectItem><SelectItem value="read-write">{t('access_keys.readWrite')}</SelectItem></SelectGroup></SelectContent></Select></Field>}
    </FieldGroup></div><footer className="identity-form-footer"><Button type="button" variant="outline" disabled={saving} onClick={onClose}>{t('access_keys.cancel')}</Button><Button type="submit" disabled={saving}>{saving ? t('access_keys.submitting') : t('access_keys.submit')}</Button></footer></form>
  </DialogContent></Dialog>
}
