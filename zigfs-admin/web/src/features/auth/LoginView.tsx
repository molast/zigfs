import { createApiClient } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { type FormEvent, useEffect, useState } from 'react'
import { useLoading } from '../../components/LoadingProvider'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'

interface LoginViewProps {
  onLogin: (username: string, password: string) => Promise<void>
}

export function LoginView({ onLogin }: LoginViewProps) {
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
      notifyError('OIDC 登录失败，请检查身份提供商配置或重试。')
      window.history.replaceState(null, '', window.location.pathname)
    }
    return () => { active = false }
  }, [notifyError])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!username.trim() || !password) return

    setSubmitting(true)
    try {
      await withLoading('正在登录...', () => onLogin(username.trim(), password))
    } catch {
      notifyError('账号或密码错误，或 ZigFS 当前不可用')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="login-shell">
      <section className="login-branding">
        <div className="login-logo"><img className="brand-logo" src="/zigfs-logo.svg" alt="" aria-hidden="true" /><strong>ZigFS</strong></div>
        <div className="login-copy">
          <h1>对象存储管理中心</h1>
          <p>查看服务状态，管理 Bucket、对象和访问凭证。所有管理数据均由 ZigFS API 提供。</p>
        </div>
        <span className="login-version">ZigFS Admin v0.1.0</span>
      </section>
      <div className="login-form-wrap">
        <Card className="login-panel">
          <div className="login-card-header"><h2>登录</h2><p>使用 ZigFS 中配置的账号继续</p></div>
          <div className="login-card-content">
          <form onSubmit={submit}>
          <FieldGroup>
          <Field><FieldLabel htmlFor="admin-username">账号</FieldLabel><Input
            id="admin-username"
            name="username"
            type="text"
            autoComplete="username"
            placeholder="请输入管理员账号"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            required
            autoFocus
          /></Field>
          <Field><FieldLabel htmlFor="admin-password">密码</FieldLabel><Input
            id="admin-password"
            name="password"
            type="password"
            autoComplete="current-password"
            placeholder="请输入管理员密码"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
          /></Field>
          <Button className="w-full" type="submit" disabled={submitting} aria-busy={submitting}>登录</Button>
          </FieldGroup>
          </form>
          {providers.length > 0 && <div className="mt-4 flex flex-col gap-2">{providers.map(provider => <Button key={provider.provider_id} variant="outline" disabled={submitting} onClick={() => { window.location.assign(`/api/v1/auth/oidc/${encodeURIComponent(provider.provider_id)}/start`) }}>使用 {provider.display_name || provider.provider_id} 登录</Button>)}</div>}
          </div>
        </Card>
      </div>
    </main>
  )
}
