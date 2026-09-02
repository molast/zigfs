import { type FormEvent, useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, CreatedAccessKey } from '../../types/api'

export function AccessKeysView({ api }: { api: ApiClient }) {
  const [keys, setKeys] = useState<AccessKey[]>([])
  const [name, setName] = useState('')
  const [created, setCreated] = useState<CreatedAccessKey | null>(null)
  const [error, setError] = useState('')

  const refresh = useCallback(() => {
    api.listAccessKeys().then(setKeys).catch((reason: Error) => setError(reason.message))
  }, [api])

  useEffect(refresh, [refresh])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      const result = await api.createAccessKey(name.trim())
      setCreated(result)
      setName('')
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function toggle(key: AccessKey) {
    await api.setAccessKeyEnabled(key.id, !key.enabled)
    refresh()
  }

  async function remove(key: AccessKey) {
    if (!window.confirm(`删除 Access Key “${key.access_key}”？`)) return
    await api.deleteAccessKey(key.id)
    refresh()
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Credentials</p><h2>Access Keys</h2></div>
        <form className="inline-form" onSubmit={create}>
          <input aria-label="Credential name" placeholder="application-name" value={name} onChange={(event) => setName(event.target.value)} required />
          <button className="primary-button" type="submit">创建</button>
        </form>
      </header>
      {error && <p className="error-banner">{error}</p>}
      {created && (
        <div className="secret-panel">
          <div><span>Access Key</span><code>{created.access_key}</code></div>
          <div><span>Secret Key</span><code>{created.secret_key}</code></div>
          <button onClick={() => setCreated(null)}>关闭</button>
        </div>
      )}
      <div className="table-wrap">
        <table>
          <thead><tr><th>Access Key</th><th>Status</th><th>Created</th><th /></tr></thead>
          <tbody>
            {keys.map((key) => (
              <tr key={key.id}>
                <td><code>{key.access_key}</code></td>
                <td><button className="status-button" onClick={() => toggle(key)}>{key.enabled ? 'Enabled' : 'Disabled'}</button></td>
                <td>{new Date(key.created_at).toLocaleString()}</td>
                <td><button className="danger-button" onClick={() => remove(key)}>删除</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
