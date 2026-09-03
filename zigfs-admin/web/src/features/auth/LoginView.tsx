import { type FormEvent, useState } from 'react'

interface LoginViewProps {
  onLogin: (username: string, password: string) => Promise<void>
}

export function LoginView({ onLogin }: LoginViewProps) {
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
      await onLogin(username.trim(), password)
    } catch {
      setError('账号或密码错误，或 ZigFS 当前不可用')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="login-shell">
      <form className="login-panel" onSubmit={submit}>
        <div className="brand-mark">ZF</div>
        <div>
          <p className="eyebrow">ZigFS</p>
          <h1>管理中心</h1>
        </div>
        <label htmlFor="admin-username">管理员账号</label>
        <input
          id="admin-username"
          name="username"
          type="text"
          autoComplete="username"
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
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          required
        />
        {error && <p className="form-error" role="alert">{error}</p>}
        <button className="primary-button" type="submit" disabled={submitting}>
          {submitting ? '登录中...' : '登录'}
        </button>
      </form>
    </main>
  )
}
