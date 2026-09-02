import { type FormEvent, useState } from 'react'

interface LoginViewProps {
  onLogin: (token: string) => void
}

export function LoginView({ onLogin }: LoginViewProps) {
  const [token, setToken] = useState('')

  function submit(event: FormEvent) {
    event.preventDefault()
    const value = token.trim()
    if (value) onLogin(value)
  }

  return (
    <main className="login-shell">
      <form className="login-panel" onSubmit={submit}>
        <div className="brand-mark">ZF</div>
        <div>
          <p className="eyebrow">ZigFS</p>
          <h1>管理中心</h1>
        </div>
        <label htmlFor="admin-token">管理凭证</label>
        <input
          id="admin-token"
          name="admin-token"
          type="password"
          autoComplete="current-password"
          value={token}
          onChange={(event) => setToken(event.target.value)}
          required
          autoFocus
        />
        <button className="primary-button" type="submit">
          登录
        </button>
      </form>
    </main>
  )
}
