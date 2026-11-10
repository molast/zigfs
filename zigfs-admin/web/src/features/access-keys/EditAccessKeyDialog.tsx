import { AccessKeyFormDialog } from './AccessKeyFormDialog'
import { t } from '@/locales'
import { useId, useState, type FormEvent } from 'react'
import type { AccessKey, AccessKeyUpdate } from '../../types/api'
import { useToast } from '../../components/ToastProvider'
import { Input } from '../../components/ui/Input'
import { Field, FieldLabel } from '../../components/ui/field'
import { Switch } from '../../components/ui/switch'

const emptyPolicy = '{\n  "Version": "2012-10-17",\n  "Statement": []\n}'

export function EditAccessKeyDialog({ value, userScoped = false, onSave, onSaved, onClose }: { value: AccessKey; userScoped?: boolean; onSave: (change: AccessKeyUpdate) => Promise<AccessKey>; onSaved: (value: AccessKey) => void; onClose: () => void }) {
  const id = useId()
  const toast = useToast()
  const [name, setName] = useState(value.name ?? '')
  const [description, setDescription] = useState(value.description ?? '')
  const [enabled, setEnabled] = useState(value.enabled)
  const [inherit, setInherit] = useState(value.inherit_policy)
  const [expiry, setExpiry] = useState(value.expires_at ? new Date(value.expires_at) : undefined)
  const [expiryChanged, setExpiryChanged] = useState(false)
  const [document, setDocument] = useState(() => {
    if (!value.policy_document?.trim()) return emptyPolicy
    try { return JSON.stringify(JSON.parse(value.policy_document), null, 2) }
    catch { return value.policy_document }
  })
  const [documentChanged, setDocumentChanged] = useState(false)
  const [saving, setSaving] = useState(false)
  const [invalid, setInvalid] = useState<string | null>(null)
  async function submit(event: FormEvent) {
    event.preventDefault(); event.stopPropagation()
    if (saving) return
    const fail = (field: string, message: string) => { setInvalid(field); toast(message, 'error') }
    if (new TextEncoder().encode(name).length > 128) return fail('name', t('access_keys.nameMustNotExceed128Bytes'))
    if (new TextEncoder().encode(description).length > 1024) return fail('description', t('access_keys.descriptionMustNotExceed1024Bytes'))
    if ((!userScoped || !inherit) && documentChanged && document.trim()) {
      try {
        const parsed = JSON.parse(document)
        if (!parsed || parsed.Version !== '2012-10-17' || (!parsed.Statement || typeof parsed.Statement !== 'object')) throw Error()
      } catch { return fail('policy', t('access_keys.policyMustBeValidJsonWithVersion201210')) }
      if (new TextEncoder().encode(document).length > 262144) return fail('policy', t('access_keys.policyMustNotExceed256Kib'))
    }
    const change: AccessKeyUpdate = {}
    if (name !== (value.name ?? '')) change.name = name
    if (description !== (value.description ?? '')) change.description = description
    if (enabled !== value.enabled) change.enabled = enabled
    if (inherit !== value.inherit_policy) change.inherit_policy = inherit
    if ((!userScoped || !inherit) && documentChanged) change.policy_document = document.trim()
    if (expiryChanged) {
      if (expiry) {
        const date = new Date(expiry)
        if (date.getTime() <= Date.now()) return fail('expiry', t('access_keys.expiryMustBeInTheFuture'))
        change.expires_at = date.toISOString()
      } else change.clear_expiry = true
    }
    if (!Object.keys(change).length) { onClose(); return }
    setInvalid(null); setSaving(true)
    try { onSaved(await onSave(change)); toast(t('access_keys.accessKeyUpdated')); onClose() }
    catch (reason) { toast(reason instanceof Error ? reason.message : t('access_keys.updateFailedPleaseTryAgain'), 'error') }
    finally { setSaving(false) }
  }
  return <AccessKeyFormDialog id={id} title={t('access_keys.editKey')} descriptionText={t('access_keys.editAccessKeyMetadataStatusExpiryAndPolicy')}
    expiry={expiry} onExpiryChange={date => { setExpiry(date); setExpiryChanged(true) }}
    name={name} onNameChange={setName} description={description} onDescriptionChange={setDescription}
    alwaysShowPolicy={!userScoped} showInheritanceControl={userScoped} inherit={inherit} onInheritChange={setInherit} inheritDescription={t('access_keys.automaticallyInheritTheMainAccountPolicyWhenEnabled')}
    document={document} onDocumentChange={text => { setDocument(text); setDocumentChanged(true) }}
    saving={saving} invalid={invalid} onSubmit={submit} onClose={onClose}
    statusAfterInheritance={userScoped}
    statusField={<Field><FieldLabel htmlFor={`${id}-status`}>{t('access_keys.status')}</FieldLabel><div><Switch id={`${id}-status`} checked={enabled} disabled={saving} onCheckedChange={setEnabled} /></div></Field>}>
    <Field><FieldLabel htmlFor={`${id}-access`}>{t('access_keys.accessKey')}</FieldLabel><Input id={`${id}-access`} value={value.access_key} disabled /></Field>
  </AccessKeyFormDialog>
}
