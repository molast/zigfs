import { AccessKeyFormDialog } from './AccessKeyFormDialog'
import { t } from '@/locales'
import { useId, useState, type FormEvent } from 'react'
import { RefreshCw } from 'lucide-react'
import type { AccessKeyCreate, CreatedAccessKey } from '../../types/api'
import { useToast } from '../../components/ToastProvider'
import { Field, FieldLabel } from '../../components/ui/field'
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from '../../components/ui/input-group'

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
  const [expiry, setExpiry] = useState<Date>()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [inherit, setInherit] = useState(true)
  const [document, setDocument] = useState(() => JSON.stringify(userName ? {
    ID: '',
    Version: '2012-10-17',
    Statement: [],
  } : {
    Version: '2012-10-17',
    Statement: [
      { Effect: 'Allow', Action: ['admin:*'] },
      { Effect: 'Allow', Action: ['kms:*'] },
      { Effect: 'Allow', Action: ['s3:*'], Resource: ['arn:aws:s3:::*'] },
      { Effect: 'Allow', Action: ['sts:AssumeRole'] },
    ],
  }, null, 2))
  const [saving, setSaving] = useState(false)
  const [invalid, setInvalid] = useState<string | null>(null)
  async function submit(event: FormEvent) {
    event.preventDefault(); event.stopPropagation()
    if (saving) return
    const fail = (field: string, message: string) => { setInvalid(field); toast(message, 'error') }
    if (!/^[A-Za-z0-9]{16,128}$/.test(accessKey)) return fail('access', t('access_keys.accessKeyMustContain16128LettersOrNumbers'))
    if (!/^[\x21-\x7e]{32,64}$/.test(secretKey)) return fail('secret', t('access_keys.secretKeyMustContain3264PrintableAsciiCharacters'))
    if (!name.trim()) return fail('name', t('access_keys.nameRequired'))
    if (new TextEncoder().encode(name).length > 128) return fail('name', t('access_keys.nameMustNotExceed128Bytes'))
    if (new TextEncoder().encode(description).length > 1024) return fail('description', t('access_keys.descriptionMustNotExceed1024Bytes'))
    const expiresAt = expiry ? new Date(expiry) : undefined
    if (expiresAt && expiresAt.getTime() <= Date.now()) return fail('expiry', t('access_keys.expiryMustBeInTheFuture'))
    if (!inherit) {
      try {
        const parsed = JSON.parse(document)
        if (!parsed || parsed.Version !== '2012-10-17' || !parsed.Statement || typeof parsed.Statement !== 'object') throw Error()
      } catch { return fail('policy', t('access_keys.policyMustBeValidJsonWithVersion201210')) }
      if (new TextEncoder().encode(document).length > 262144) return fail('policy', t('access_keys.policyMustNotExceed256Kib'))
    }
    setInvalid(null); setSaving(true)
    try {
      const created = await onCreate({ access_key: accessKey, secret_key: secretKey, name, description, inherit_policy: inherit,
        ...(expiresAt ? { expires_at: expiresAt.toISOString() } : {}),
        ...(!inherit ? { policy_document: document.trim() } : {}),
      })
      onCreated(created); toast(t('access_keys.accessKeyCreated'))
    } catch (reason) { toast(reason instanceof Error ? reason.message : t('access_keys.creationFailedPleaseTryAgain'), 'error') }
    finally { setSaving(false) }
  }
  return <AccessKeyFormDialog id={id} title={t('access_keys.createKey')}
    descriptionText={userName ? t('access_keys.createAnAccessKeyForValue', { '0': userName }) : t('access_keys.createAnAccessKeyForTheCurrentAdministrator')}
    nameRequired expiry={expiry} onExpiryChange={setExpiry} name={name} onNameChange={setName}
    description={description} onDescriptionChange={setDescription} inherit={inherit} onInheritChange={setInherit}
    inheritDescription={userName ? t('access_keys.usesTheUserAndEnabledGroupPoliciesTurnOff') : t('access_keys.automaticallyInheritTheMainAccountPolicyWhenEnabled')}
    document={document} onDocumentChange={setDocument} saving={saving} invalid={invalid} onSubmit={submit} onClose={onClose}>
      <Field data-invalid={invalid === 'access' || undefined}><FieldLabel htmlFor={`${id}-access`}>{t('access_keys.accessKey')}</FieldLabel><InputGroup><InputGroupInput id={`${id}-access`} value={accessKey} maxLength={128} disabled={saving} autoComplete="off" aria-invalid={invalid === 'access'} onChange={event => setAccessKey(event.target.value)} /><InputGroupAddon align="inline-end"><InputGroupButton type="button" disabled={saving} aria-label={t('access_keys.generateAccessKey')} onClick={() => setAccessKey(randomKey(20))}><RefreshCw /></InputGroupButton></InputGroupAddon></InputGroup></Field>
      <Field data-invalid={invalid === 'secret' || undefined}><FieldLabel htmlFor={`${id}-secret`}>{t('access_keys.secretKey')}</FieldLabel><InputGroup><InputGroupInput id={`${id}-secret`} type="password" value={secretKey} disabled={saving} maxLength={64} autoComplete="new-password" aria-invalid={invalid === 'secret'} onChange={event => setSecretKey(event.target.value)} /></InputGroup></Field>
  </AccessKeyFormDialog>
}
