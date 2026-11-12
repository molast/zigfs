import { useEffect, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient, type DisplaySettings } from '../../api/client'
import { formatDateTime, setDisplayPreferences, supportsTimezone, type DateFormat } from '../../lib/dateTime'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { OptionSelect } from '../../components/ui/OptionSelect'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'

export function DisplaySettingsPanel({ api, observedAt }: { api: ApiClient; observedAt: Date | null }) {
  const [saved, setSaved] = useState<DisplaySettings | null>(null)
  const [timezone, setTimezone] = useState('browser')
  const [dateFormat, setDateFormat] = useState<DateFormat>('locale')
  const [invalid, setInvalid] = useState<'timezone' | 'format' | null>(null)
  const [busy, setBusy] = useState(false)
  const [previewTime] = useState(() => new Date())
  const toast = useToast()
  function apply(value: DisplaySettings) {
    setSaved(value); setTimezone(value.timezone); setDateFormat(value.date_format)
    setDisplayPreferences(value)
  }
  useEffect(() => {
    let active = true
    setBusy(true); setInvalid(null)
    api.displaySettings().then(value => { if (active) apply(value) }).catch(() => {
      if (active) { setSaved(null); toast(t('settings.displayLoadFailed'), 'error') }
    }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [api, observedAt, toast])
  const formats: { value: DateFormat; label: string }[] = [
    { value: 'locale', label: t('settings.followsTheSelectedLanguage') },
    { value: 'ymd', label: 'YYYY-MM-DD HH:mm:ss' },
    { value: 'dmy', label: 'DD/MM/YYYY HH:mm:ss' },
    { value: 'mdy', label: 'MM/DD/YYYY HH:mm:ss' },
  ]
  return <Card className="system-settings-form">
    <CardHeader><CardTitle>{t('settings.displayPreferences')}</CardTitle><CardDescription>{t('settings.displaySaveHelp')}</CardDescription></CardHeader>
    <CardContent><form onSubmit={async event => {
      event.preventDefault()
      if (busy || !saved) return
      setInvalid(null); setBusy(true)
      try {
        apply(await api.saveDisplaySettings({ timezone, date_format: dateFormat }))
        toast(t('settings.displaySaved'))
      } catch (error) {
        const code = error instanceof ApiError ? error.body.code : ''
        const field = code === 'InvalidDisplayTimezone' ? 'timezone' : code === 'InvalidDisplayDateFormat' ? 'format' : null
        setInvalid(field)
        toast(t(field === 'timezone' ? 'settings.invalidDisplayTimezone' : field === 'format' ? 'settings.invalidDisplayDateFormat' : 'settings.displaySaveFailed'), 'error')
      } finally { setBusy(false) }
    }}><FieldGroup>
      <Field data-invalid={invalid === 'timezone'}>
        <FieldLabel htmlFor="display-timezone">{t('settings.displayTimezone')}</FieldLabel>
        <OptionSelect id="display-timezone" value={timezone} onValueChange={value => { setTimezone(value); setInvalid(null) }} disabled={busy || !saved} aria-invalid={invalid === 'timezone'} aria-describedby="display-timezone-help" options={(saved?.supported_timezones ?? ['browser']).filter(zone => zone === 'browser' || supportsTimezone(zone)).map(zone => ({ value: zone, label: zone === 'browser' ? t('settings.browserTimezone') : zone }))} />
        <FieldDescription id="display-timezone-help">{t('settings.displayTimezoneHelp')}</FieldDescription>
      </Field>
      <Field data-invalid={invalid === 'format'}>
        <FieldLabel htmlFor="display-date-format">{t('settings.dateAndTimeFormat')}</FieldLabel>
        <OptionSelect id="display-date-format" value={dateFormat} onValueChange={value => { setDateFormat(value as DateFormat); setInvalid(null) }} disabled={busy || !saved} aria-invalid={invalid === 'format'} options={formats} />
      </Field>
      <Field><FieldLabel htmlFor="display-preview">{t('settings.displayPreview')}</FieldLabel><Input id="display-preview" readOnly value={formatDateTime(previewTime, { timezone, date_format: dateFormat })} /></Field>
      <Button type="submit" disabled={busy || !saved || (timezone === saved.timezone && dateFormat === saved.date_format)}>{t('settings.saveNetwork')}</Button>
    </FieldGroup></form></CardContent>
  </Card>
}
