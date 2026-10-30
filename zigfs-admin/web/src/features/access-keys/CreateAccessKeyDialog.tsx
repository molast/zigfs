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
    if (!/^[A-Za-z0-9]{16,128}$/.test(accessKey)) return fail('access', 'Access Key 需为 16–128 个字母或数字')
    if (!/^[\x21-\x7e]{32,64}$/.test(secretKey)) return fail('secret', 'Secret Key 需为 32–64 个可见 ASCII 字符')
    if (new TextEncoder().encode(name).length > 128) return fail('name', 'Name 不能超过 128 字节')
    if (new TextEncoder().encode(description).length > 1024) return fail('description', 'Description 不能超过 1024 字节')
    const expiresAt = expiry ? new Date(expiry) : undefined
    if (expiresAt && expiresAt.getTime() <= Date.now()) return fail('expiry', '到期时间必须晚于当前时间')
    setInvalid(null); setSaving(true)
    try {
      const created = await onCreate({ access_key: accessKey, secret_key: secretKey, name, description, inherit_policy: inherit,
        ...(expiresAt ? { expires_at: expiresAt.toISOString() } : {}),
        ...(!inherit ? { policy: { bucket_read: true, object_read: true, bucket_write: permission === 'read-write', object_write: permission === 'read-write', bypass_governance_retention: false } } : {}),
      })
      onCreated(created); toast('Access Key created')
    } catch (reason) { toast(reason instanceof Error ? reason.message : '创建失败，请重试', 'error') }
    finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog create-key-dialog">
    <DialogHeader><DialogTitle>Create Key</DialogTitle><DialogDescription className="sr-only">{userName ? `Create an access key for ${userName}.` : 'Create an access key for the current administrator.'}</DialogDescription></DialogHeader>
    <form className="identity-form" onSubmit={event => void submit(event)} noValidate><div className="identity-form-body"><FieldGroup>
      <Field data-invalid={invalid === 'access' || undefined}><FieldLabel htmlFor={`${id}-access`}>Access Key</FieldLabel><InputGroup><InputGroupInput id={`${id}-access`} value={accessKey} maxLength={128} disabled={saving} autoComplete="off" aria-invalid={invalid === 'access'} onChange={event => setAccessKey(event.target.value)} /><InputGroupAddon align="inline-end"><InputGroupButton type="button" disabled={saving} aria-label="Generate Access Key" onClick={() => setAccessKey(randomKey(20))}><RefreshCw /></InputGroupButton></InputGroupAddon></InputGroup></Field>
      <Field data-invalid={invalid === 'secret' || undefined}><FieldLabel htmlFor={`${id}-secret`}>Secret Key</FieldLabel><InputGroup><InputGroupInput id={`${id}-secret`} type={showSecret ? 'text' : 'password'} value={secretKey} disabled={saving} maxLength={64} autoComplete="new-password" aria-invalid={invalid === 'secret'} onChange={event => setSecretKey(event.target.value)} /><InputGroupAddon align="inline-end"><InputGroupButton type="button" disabled={saving} aria-label={showSecret ? 'Hide Secret Key' : 'Show Secret Key'} onClick={() => setShowSecret(current => !current)}>{showSecret ? <EyeOff /> : <Eye />}</InputGroupButton><InputGroupButton type="button" disabled={saving} aria-label="Generate Secret Key" onClick={() => setSecretKey(randomKey(40))}><RefreshCw /></InputGroupButton></InputGroupAddon></InputGroup></Field>
      <AccessKeyExpiryField value={expiry} onChange={setExpiry} disabled={saving} invalid={invalid === 'expiry'} />
      <Field data-invalid={invalid === 'name' || undefined}><FieldLabel htmlFor={`${id}-name`}>Name</FieldLabel><Input id={`${id}-name`} value={name} maxLength={128} disabled={saving} aria-invalid={invalid === 'name'} onChange={event => setName(event.target.value)} /></Field>
      <Field data-invalid={invalid === 'description' || undefined}><FieldLabel htmlFor={`${id}-description`}>Description</FieldLabel><Textarea id={`${id}-description`} value={description} maxLength={1024} disabled={saving} aria-invalid={invalid === 'description'} onChange={event => setDescription(event.target.value)} /></Field>
      <Field orientation="horizontal" className="rounded-md border p-4"><FieldContent><FieldLabel htmlFor={`${id}-inherit`}>Use parent account permissions</FieldLabel><FieldDescription>{userName ? 'Uses the user and enabled group policies. Turn off to add further restrictions; parent permissions always apply.' : 'Automatically inherit the main account policy when enabled.'}</FieldDescription></FieldContent><Switch id={`${id}-inherit`} checked={inherit} disabled={saving} onCheckedChange={setInherit} /></Field>
      {!inherit && <Field><FieldLabel htmlFor={`${id}-permissions`}>Permissions</FieldLabel><Select value={permission} onValueChange={setPermission} disabled={saving}><SelectTrigger id={`${id}-permissions`}><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="read-only">Read Only</SelectItem><SelectItem value="read-write">Read / Write</SelectItem></SelectGroup></SelectContent></Select></Field>}
    </FieldGroup></div><footer className="identity-form-footer"><Button type="button" variant="outline" disabled={saving} onClick={onClose}>Cancel</Button><Button type="submit" disabled={saving}>{saving ? 'Submitting…' : 'Submit'}</Button></footer></form>
  </DialogContent></Dialog>
}
