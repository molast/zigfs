import { LanguageSwitcher } from '../../components/LanguageSwitcher'
import { t } from '@/locales'
import { createApiClient } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { type FormEvent, useEffect, useState } from 'react'
import { useLoading } from '../../components/LoadingProvider'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'

interface LoginViewProps {
  darkTheme: boolean
  onLogin: (username: string, password: string) => Promise<void>
}

export function LoginView({ onLogin, darkTheme }: LoginViewProps) {
  const { withLoading } = useLoading()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const notifyError = useErrorToast()
  const [providers, setProviders] = useState<{ provider_id: string; display_name: string }[]>([])
  useEffect(() => {
    let active = true
    void createApiClient().oidcLoginProviders().then(result => { if (active) setProviders(result.items) }).catch(() => {})
    if (new URLSearchParams(window.location.search).has('oidc_error')) {
      notifyError(t('auth.oidcSignInFailedCheckTheIdentityProviderConfiguration'))
      window.history.replaceState(null, '', window.location.pathname)
    }
    return () => { active = false }
  }, [notifyError])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!username.trim() || !password) return

    setSubmitting(true)
    try {
      await withLoading(t('auth.signingIn'), () => onLogin(username.trim(), password))
    } catch {
      notifyError(t('auth.invalidUsernameOrPasswordOrZigfsIsUnavailable'))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="login-shell" style={{ colorScheme: darkTheme ? 'dark' : 'light' }}>
      <section className="login-branding">
        <div className="login-logo"><img className="brand-logo" src="/zigfs-logo.svg" alt="" aria-hidden="true" /><strong>ZigFS</strong></div>
        <div className="login-copy">
          <h1>{t('auth.objectStorageConsole')}</h1>
          <p>{t('auth.monitorServiceStatusAndManageBucketsObjectsAndAccess')}</p>
        </div>
        <span className="login-version">ZigFS Admin v0.1.0</span>
      </section>
      <div className="login-form-wrap">
        <Card className="login-panel">
          <div className="login-card-header"><div className="login-preferences"><LanguageSwitcher /></div><h2>{t('auth.signIn')}</h2><p>{t('auth.continueWithYourZigfsAccount')}</p></div>
          <div className="login-card-content">
          <form onSubmit={submit}>
          <FieldGroup>
          <Field><FieldLabel htmlFor="admin-username">{t('auth.username')}</FieldLabel><Input
            id="admin-username"
            name="username"
            type="text"
            autoComplete="username"
            placeholder={t('auth.enterYourUsername')}
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            required
            autoFocus
          /></Field>
          <Field><FieldLabel htmlFor="admin-password">{t('auth.password')}</FieldLabel><Input
            id="admin-password"
            name="password"
            type="password"
            autoComplete="current-password"
            placeholder={t('auth.enterYourPassword')}
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
          /></Field>
          <Button className="w-full" type="submit" disabled={submitting} aria-busy={submitting}>{t('auth.signIn')}</Button>
          </FieldGroup>
          </form>
          {providers.length > 0 && <div className="mt-4 flex flex-col gap-2">{providers.map(provider => <Button key={provider.provider_id} variant="outline" disabled={submitting} onClick={() => { window.location.assign(`/api/v1/auth/oidc/${encodeURIComponent(provider.provider_id)}/start`) }}>{t('auth.providerSignIn', { provider: provider.display_name || provider.provider_id })}</Button>)}</div>}
          </div>
        </Card>
      </div>
    </main>
  )
}
