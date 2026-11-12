import { LanguageSwitcher } from '../../components/LanguageSwitcher'
import { t } from '@/locales'
import { useErrorToast } from '../../components/ToastProvider'
import { type FormEvent, useEffect, useState } from 'react'
import { Eye, EyeOff, Moon, Sun } from 'lucide-react'
import { useLoading } from '../../components/LoadingProvider'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'
import { LoginNetwork } from './LoginNetwork'

interface LoginViewProps {
  darkTheme: boolean
  onToggleTheme: () => void
  onLogin: (username: string, password: string) => Promise<void>
  onStsLogin: (username: string, secretKey: string, sessionToken: string) => Promise<void>
}

export function LoginView({ onLogin, onStsLogin, darkTheme, onToggleTheme }: LoginViewProps) {
  const { withLoading } = useLoading()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [stsUsername, setStsUsername] = useState('')
  const [stsSecret, setStsSecret] = useState('')
  const [stsToken, setStsToken] = useState('')
  const [showSecret, setShowSecret] = useState(false)
  const [mode, setMode] = useState<'password' | 'sts'>('password')
  const [submitting, setSubmitting] = useState(false)
  const notifyError = useErrorToast()
  useEffect(() => {
    if (new URLSearchParams(window.location.search).has('oidc_error')) {
      notifyError(t('auth.oidcSignInFailedCheckTheIdentityProviderConfiguration'))
      window.history.replaceState(null, '', window.location.pathname)
    }
  }, [notifyError])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (mode === 'sts') {
      if (!stsUsername.trim() || !stsSecret || !stsToken) return
      setSubmitting(true)
      try { await withLoading(t('auth.signingIn'), () => onStsLogin(stsUsername.trim(), stsSecret, stsToken)) }
      catch { notifyError(t('auth.invalidStsCredentials')) }
      finally { setSubmitting(false) }
      return
    }
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
        <LoginNetwork />
        <div className="login-logo"><img className="brand-logo" src="/zigfs-logo.svg" alt="" aria-hidden="true" /><strong>ZigFS</strong></div>
        <div className="login-copy">
          <h1>{t('auth.objectStorageOnYourTerms')}</h1>
          <p>{t('auth.selfHostedStorageDescription')}</p>
        </div>
        <span className="login-version">ZigFS Admin v0.1.0</span>
      </section>
      <div className="login-form-wrap">
        <Card className="login-panel">
          <div className="login-preferences"><Button variant="ghost" size="icon-sm" type="button" onClick={onToggleTheme} aria-label={t(darkTheme ? 'navigation.switchToLightTheme' : 'navigation.switchToDarkTheme')}>{darkTheme ? <Sun /> : <Moon />}</Button><LanguageSwitcher /></div>
          <div className="login-tabs" role="tablist" aria-label={t('auth.loginMethod')}>
            <button type="button" role="tab" aria-selected={mode === 'password'} className={mode === 'password' ? 'active' : ''} onClick={() => setMode('password')}>{t('auth.passwordLogin')}</button>
            <button type="button" role="tab" aria-selected={mode === 'sts'} className={mode === 'sts' ? 'active' : ''} onClick={() => setMode('sts')}>{t('auth.stsLogin')}</button>
          </div>
          <div className="login-card-header"><h2 className="sr-only">{t('auth.signIn')}</h2></div>
          <div className="login-card-content">
          <form onSubmit={submit}>
          <FieldGroup>
          <Field><FieldLabel htmlFor="admin-username">{mode === 'sts' ? t('auth.stsUsername') : t('auth.username')}</FieldLabel><Input
            id="admin-username"
            name="username"
            type="text"
            autoComplete="username"
            placeholder={mode === 'sts' ? t('auth.enterStsUsername') : t('auth.enterYourUsername')}
            value={mode === 'sts' ? stsUsername : username}
            onChange={(event) => mode === 'sts' ? setStsUsername(event.target.value) : setUsername(event.target.value)}
            required
            autoFocus
          /></Field>
          <Field><FieldLabel htmlFor="admin-password">{mode === 'sts' ? t('auth.stsSecret') : t('auth.password')}</FieldLabel><div className="login-secret-input"><Input
            id="admin-password"
            name="password"
            autoComplete="current-password"
            placeholder={mode === 'sts' ? t('auth.enterStsSecret') : t('auth.enterYourPassword')}
            value={mode === 'sts' ? stsSecret : password}
            onChange={(event) => mode === 'sts' ? setStsSecret(event.target.value) : setPassword(event.target.value)}
            required
            type={showSecret ? 'text' : 'password'}
          /><Button type="button" variant="ghost" size="icon-sm" className="login-eye" aria-pressed={showSecret} aria-controls="admin-password" aria-label={showSecret ? t('auth.hideSecret') : t('auth.showSecret')} onClick={() => setShowSecret(value => !value)}>{showSecret ? <EyeOff /> : <Eye />}</Button></div></Field>
          {mode === 'sts' && <Field><FieldLabel htmlFor="sts-token">{t('auth.stsSessionToken')}</FieldLabel><Input id="sts-token" type="text" placeholder={t('auth.enterStsSessionToken')} value={stsToken} onChange={event => setStsToken(event.target.value)} required /></Field>}
          <Button className="w-full" type="submit" disabled={submitting} aria-busy={submitting}>{t('auth.signIn')}</Button>
          </FieldGroup>
          </form>
          </div>
          <div className="login-footer"><span>{t('auth.loginTrouble')}</span><a href="mailto:support@zigfs.local">{t('auth.getHelp')}</a></div>
        </Card>
      </div>
    </main>
  )
}
