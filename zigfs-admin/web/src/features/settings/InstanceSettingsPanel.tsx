import { formatDateTime } from '@/lib/dateTime'
import { useEffect, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient, type InstanceSettings } from '../../api/client'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '../../components/ui/field'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../../components/ui/Card'
import { useToast } from '../../components/ToastProvider'

export function InstanceSettingsPanel({ api, observedAt }: { api: ApiClient; observedAt: Date | null }) {
  const [saved, setSaved] = useState<InstanceSettings | null>(null)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [busy, setBusy] = useState(false)
  const [invalid, setInvalid] = useState<'name' | 'description' | null>(null)
  const toast = useToast()
  function apply(value: InstanceSettings) { setSaved(value); setName(value.service_name); setDescription(value.description) }
  useEffect(() => {
    let active = true
    setBusy(true); setInvalid(null)
    api.instanceSettings().then(value => { if (active) apply(value) }).catch(() => { if (active) { setSaved(null); toast(t('settings.instanceLoadFailed'), 'error') } }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [api, observedAt, toast])
  const changed = name !== saved?.service_name || description !== saved?.description
  function clearError() { setInvalid(null) }
  return <Card className="system-settings-form"><CardHeader><CardTitle>{t('settings.instanceInformation')}</CardTitle><CardDescription>{t('settings.instanceSaveHelp')}</CardDescription></CardHeader><CardContent>
    <form onSubmit={async event => {
      event.preventDefault()
      if (busy || !saved) return
      clearError()
      const cleanName = name.trim()
      if (!cleanName || new TextEncoder().encode(cleanName).length > 128 || /[\x00-\x1f\x7f]/.test(cleanName)) { setInvalid('name'); toast(t('settings.invalidServiceName'), 'error'); return }
      if (new TextEncoder().encode(description).length > 4096 || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(description)) { setInvalid('description'); toast(t('settings.invalidInstanceDescription'), 'error'); return }
      setBusy(true)
      try {
        apply(await api.saveInstanceSettings({ service_name: cleanName, description }))
        toast(t('settings.instanceSaved'))
      } catch (reason) {
        const code = reason instanceof ApiError ? reason.body.code : ''
        if (code === 'InvalidServiceName') { setInvalid('name'); toast(t('settings.invalidServiceName'), 'error') }
        else if (code === 'InvalidInstanceDescription') { setInvalid('description'); toast(t('settings.invalidInstanceDescription'), 'error') }
        else toast(t('settings.instanceSaveFailed'), 'error')
      } finally { setBusy(false) }
    }}><FieldGroup>
      <Field data-invalid={invalid === 'name'}><FieldLabel htmlFor="instance-name">{t('settings.serviceName')}</FieldLabel><Input id="instance-name" value={name} disabled={busy || !saved} onChange={e => { setName(e.target.value); clearError() }} aria-invalid={invalid === 'name'} /></Field>
      <Field data-invalid={invalid === 'description'}><FieldLabel htmlFor="instance-description">{t('settings.instanceDescription')}</FieldLabel><Textarea id="instance-description" rows={3} value={description} disabled={busy || !saved} onChange={e => { setDescription(e.target.value); clearError() }} aria-invalid={invalid === 'description'} /></Field>
      <Field><FieldLabel htmlFor="instance-id">{t('settings.instanceId')}</FieldLabel><Input id="instance-id" readOnly value={saved?.instance_id ?? '—'} /><FieldDescription>{t('settings.instanceIdHelp')}</FieldDescription></Field>
      <Field><FieldLabel htmlFor="instance-started">{t('settings.startedAt')}</FieldLabel><Input id="instance-started" readOnly value={saved ? formatDateTime(saved.started_at_unix_seconds * 1000) : '—'} /><FieldDescription>{t('settings.instanceStartedHelp')}</FieldDescription></Field>
      <Field><FieldLabel htmlFor="instance-uptime">{t('settings.uptime')}</FieldLabel><Input id="instance-uptime" readOnly value={saved ? t('settings.instanceUptime', { days: Math.floor(saved.uptime_seconds / 86400), hours: Math.floor(saved.uptime_seconds % 86400 / 3600), minutes: Math.floor(saved.uptime_seconds % 3600 / 60), seconds: saved.uptime_seconds % 60 }) : '—'} /><FieldDescription>{t('settings.asOfTheLastRefresh')}</FieldDescription></Field>
      <Button type="submit" disabled={busy || !saved || !changed}>{t('settings.saveNetwork')}</Button>
    </FieldGroup></form>
  </CardContent></Card>
}
