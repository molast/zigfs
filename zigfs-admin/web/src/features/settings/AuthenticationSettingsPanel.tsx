import { useEffect, useRef, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient, type AuthenticationSettings } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Alert, AlertDescription } from '../../components/ui/alert'

type InvalidField = 'session' | 'skew' | null

export function AuthenticationSettingsPanel({ api, observedAt }: { api: ApiClient; observedAt: Date | null }) {
  const [saved, setSaved] = useState<AuthenticationSettings | null>(null)
  const [session, setSession] = useState('')
  const [skew, setSkew] = useState('')
  const [busy, setBusy] = useState(false)
  const [invalid, setInvalid] = useState<InvalidField>(null)
  const sessionInput = useRef<HTMLInputElement>(null)
  const skewInput = useRef<HTMLInputElement>(null)
  const toast = useToast()

  function apply(value: AuthenticationSettings) {
    setSaved(value)
    setSession(String(value.pending.admin_session_ttl_seconds))
    setSkew(String(value.pending.request_time_skew_seconds))
  }

  useEffect(() => {
    let active = true
    setBusy(true)
    setInvalid(null)
    api.authenticationSettings().then(value => {
      if (active) apply(value)
    }).catch(() => {
      if (active) {
        setSaved(null)
        toast(t('settings.authenticationLoadFailed'), 'error')
      }
    }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [api, observedAt, toast])

  function fail(field: InvalidField) {
    setInvalid(field)
    toast(t(field === 'session' ? 'settings.invalidSessionLifetime' : field === 'skew' ? 'settings.invalidSignatureClockSkew' : 'settings.authenticationSaveFailed'), 'error')
    if (field === 'session') sessionInput.current?.focus()
    if (field === 'skew') skewInput.current?.focus()
  }

  return <Card className="system-settings-form">
    <CardHeader><CardTitle>{t('settings.authenticationSettings')}</CardTitle><CardDescription>{t('settings.authenticationSaveHelp')}</CardDescription></CardHeader>
    <CardContent>
      <form noValidate onSubmit={async event => {
        event.preventDefault()
        if (busy || !saved) return
        setInvalid(null)
        const ttl = Number(session)
        const tolerance = Number(skew)
        if (!/^\d+$/.test(session) || !Number.isSafeInteger(ttl) || ttl < 60 || ttl > 86400) { fail('session'); return }
        if (!/^\d+$/.test(skew) || !Number.isSafeInteger(tolerance) || tolerance < 60 || tolerance > 3600) { fail('skew'); return }
        setBusy(true)
        try {
          const value = await api.saveAuthenticationSettings({ admin_session_ttl_seconds: ttl, request_time_skew_seconds: tolerance })
          apply(value)
          toast(t(value.restart_required ? 'settings.authenticationSavedRestart' : 'settings.authenticationSaved'))
        } catch (error) {
          const code = error instanceof ApiError ? error.body.code : ''
          fail(code === 'InvalidSessionLifetime' ? 'session' : code === 'InvalidSignatureClockSkew' ? 'skew' : null)
        } finally { setBusy(false) }
      }}><FieldGroup>
        <Field data-invalid={invalid === 'session'}>
          <FieldLabel htmlFor="authentication-session">{t('settings.adminSessionLifetime')}</FieldLabel>
          <Input ref={sessionInput} id="authentication-session" type="number" min={60} max={86400} step={1} disabled={busy || !saved} value={session} onChange={event => { setSession(event.target.value); setInvalid(null) }} aria-invalid={invalid === 'session'} aria-describedby="authentication-session-help" />
          <FieldDescription id="authentication-session-help">{t('settings.sessionLifetimeHelp', { seconds: saved?.current.admin_session_ttl_seconds ?? '—' })}</FieldDescription>
        </Field>
        <Field data-invalid={invalid === 'skew'}>
          <FieldLabel htmlFor="authentication-skew">{t('settings.signatureClockSkew')}</FieldLabel>
          <Input ref={skewInput} id="authentication-skew" type="number" min={60} max={3600} step={1} disabled={busy || !saved} value={skew} onChange={event => { setSkew(event.target.value); setInvalid(null) }} aria-invalid={invalid === 'skew'} aria-describedby="authentication-skew-help" />
          <FieldDescription id="authentication-skew-help">{t('settings.signatureClockSkewHelp', { seconds: saved?.current.request_time_skew_seconds ?? '—' })}</FieldDescription>
        </Field>
        {saved?.restart_required && <Alert><AlertDescription>{t('settings.authenticationPending')}</AlertDescription></Alert>}
        <Button type="submit" disabled={busy || !saved || (session === String(saved.pending.admin_session_ttl_seconds) && skew === String(saved.pending.request_time_skew_seconds))}>{t('settings.saveNetwork')}</Button>
      </FieldGroup></form>
    </CardContent>
  </Card>
}
