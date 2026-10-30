import { useId, useState, type FormEvent } from 'react'
import type { AccessKey, AccessKeyUpdate } from '../../types/api'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Switch } from '../../components/ui/switch'
import { AccessKeyExpiryField } from './AccessKeyExpiryField'

const emptyPolicy = '{\n  "Version": "2012-10-17",\n  "Statement": []\n}'

export function EditAccessKeyDialog({ value, onSave, onSaved, onClose }: { value: AccessKey; onSave: (change: AccessKeyUpdate) => Promise<AccessKey>; onSaved: (value: AccessKey) => void; onClose: () => void }) {
  const id = useId()
  const toast = useToast()
  const [name, setName] = useState(value.name ?? '')
  const [description, setDescription] = useState(value.description ?? '')
  const [enabled, setEnabled] = useState(value.enabled)
  const [inherit, setInherit] = useState(value.inherit_policy)
  const [expiry, setExpiry] = useState(value.expires_at ? new Date(value.expires_at) : undefined)
  const [expiryChanged, setExpiryChanged] = useState(false)
  const [document, setDocument] = useState(value.policy_document || emptyPolicy)
  const [documentChanged, setDocumentChanged] = useState(false)
  const [saving, setSaving] = useState(false)
  const [invalid, setInvalid] = useState<string | null>(null)
  async function submit(event: FormEvent) {
    event.preventDefault(); event.stopPropagation()
    if (saving) return
    const fail = (field: string, message: string) => { setInvalid(field); toast(message, 'error') }
    if (new TextEncoder().encode(name).length > 128) return fail('name', 'Name 不能超过 128 字节')
    if (new TextEncoder().encode(description).length > 1024) return fail('description', 'Description 不能超过 1024 字节')
    if (documentChanged && document.trim()) {
      try {
        const parsed = JSON.parse(document)
        if (!parsed || parsed.Version !== '2012-10-17' || (!parsed.Statement || typeof parsed.Statement !== 'object')) throw Error()
      } catch { return fail('policy', 'Policy 需为有效的 2012-10-17 JSON 策略，且包含 Statement 对象或数组') }
      if (new TextEncoder().encode(document).length > 262144) return fail('policy', 'Policy 不能超过 256 KiB')
    }
    const change: AccessKeyUpdate = {}
    if (name !== (value.name ?? '')) change.name = name
    if (description !== (value.description ?? '')) change.description = description
    if (enabled !== value.enabled) change.enabled = enabled
    if (inherit !== value.inherit_policy) change.inherit_policy = inherit
    if (documentChanged) change.policy_document = document.trim()
    if (expiryChanged) {
      if (expiry) {
        const date = new Date(expiry)
        if (date.getTime() <= Date.now()) return fail('expiry', '到期时间必须晚于当前时间')
        change.expires_at = date.toISOString()
      } else change.clear_expiry = true
    }
    if (!Object.keys(change).length) { onClose(); return }
    setInvalid(null); setSaving(true)
    try { onSaved(await onSave(change)); toast('Access Key updated'); onClose() }
    catch (reason) { toast(reason instanceof Error ? reason.message : '更新失败，请重试', 'error') }
    finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog edit-key-dialog"><DialogHeader><DialogTitle>Edit Key</DialogTitle><DialogDescription className="sr-only">Edit access key metadata, status, expiry and policy.</DialogDescription></DialogHeader><form className="identity-form" onSubmit={event => void submit(event)} noValidate><div className="identity-form-body edit-key-fields"><FieldGroup>
    <Field><FieldLabel htmlFor={`${id}-access`}>Access Key</FieldLabel><Input id={`${id}-access`} value={value.access_key} disabled /></Field>
    <AccessKeyExpiryField value={expiry} onChange={date => { setExpiry(date); setExpiryChanged(true) }} disabled={saving} invalid={invalid === 'expiry'} />
    <Field data-invalid={invalid === 'name' || undefined}><FieldLabel htmlFor={`${id}-name`}>Name</FieldLabel><Input id={`${id}-name`} value={name} maxLength={128} disabled={saving} aria-invalid={invalid === 'name'} onChange={event => setName(event.target.value)} /></Field>
    <Field data-invalid={invalid === 'description' || undefined}><FieldLabel htmlFor={`${id}-description`}>Description</FieldLabel><Textarea id={`${id}-description`} value={description} maxLength={1024} disabled={saving} aria-invalid={invalid === 'description'} onChange={event => setDescription(event.target.value)} /></Field>
    <Field><FieldLabel htmlFor={`${id}-status`}>Status</FieldLabel><div><Switch id={`${id}-status`} checked={enabled} disabled={saving} onCheckedChange={setEnabled} /></div></Field>
    <Field><FieldLabel htmlFor={`${id}-inherit`}>Use parent account permissions</FieldLabel><div><Switch id={`${id}-inherit`} checked={inherit} disabled={saving} onCheckedChange={setInherit} /></div></Field>
  </FieldGroup><Field data-invalid={invalid === 'policy' || undefined} className="edit-key-policy"><FieldLabel htmlFor={`${id}-policy`}>Policy</FieldLabel><Textarea id={`${id}-policy`} value={document} disabled={saving} spellCheck={false} aria-invalid={invalid === 'policy'} onChange={event => { setDocument(event.target.value); setDocumentChanged(true) }} /><FieldDescription>{!value.policy_document && !documentChanged ? 'Unchanged keeps current permissions. ' : ''}Policy limits inherited permissions. Clear to remove it.</FieldDescription></Field></div><footer className="identity-form-footer"><Button type="button" variant="outline" disabled={saving} onClick={onClose}>Cancel</Button><Button type="submit" disabled={saving}>{saving ? 'Submitting…' : 'Submit'}</Button></footer></form></DialogContent></Dialog>
}
