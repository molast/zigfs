import { type FormEvent, useState } from 'react'
import { useLoading } from '../../components/LoadingProvider'

interface LoginViewProps {
  onLogin: (username: string, password: string) => Promise<void>
}

export function LoginView({ onLogin }: LoginViewProps) {
  const { withLoading } = useLoading()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!username.trim() || !password) return

    setSubmitting(true)
    setError('')
    try {
      await withLoading('正在登录...', () => onLogin(username.trim(), password))
    } catch {
      setError('账号或密码错误，或 ZigFS 当前不可用')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="login-shell">
      <section className="login-branding">
        <div className="login-logo"><span className="brand-mark">ZF</span><strong>ZigFS</strong></div>
        <div className="login-copy">
          <h1>对象存储管理中心</h1>
          <p>查看服务状态，管理 Bucket、对象和访问凭证。所有管理数据均由 ZigFS API 提供。</p>
        </div>
        <span className="login-version">ZigFS Admin v0.1.0</span>
      </section>
      <div className="login-form-wrap">
        <form className="login-panel" onSubmit={submit}>
          <h2>登录</h2>
          <p>使用 ZigFS 中配置的管理员账号继续</p>
          <label htmlFor="admin-username">管理员账号</label>
          <input
            id="admin-username"
            name="username"
            type="text"
            autoComplete="username"
            placeholder="请输入管理员账号"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            required
            autoFocus
          />
          <label htmlFor="admin-password">管理员密码</label>
          <input
            id="admin-password"
            name="password"
            type="password"
            autoComplete="current-password"
            placeholder="请输入管理员密码"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
          />
          {error && <p className="form-error" role="alert">{error}</p>}
          <button className="primary-button" type="submit" disabled={submitting} aria-busy={submitting}>
            登录
          </button>
        </form>
      </div>
    </main>
  )
}
