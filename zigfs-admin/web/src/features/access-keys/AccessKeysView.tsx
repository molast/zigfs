import { type FormEvent, useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, CreatedAccessKey, CredentialPolicy } from '../../types/api'

const fullAccess: CredentialPolicy = {
  bucket_read: true,
  bucket_write: true,
  object_read: true,
  object_write: true,
}

const readOnly: CredentialPolicy = {
  bucket_read: true,
  bucket_write: false,
  object_read: true,
  object_write: false,
}

export function AccessKeysView({ api }: { api: ApiClient }) {
  const [keys, setKeys] = useState<AccessKey[]>([])
  const [owner, setOwner] = useState('')
  const [policy, setPolicy] = useState<'full' | 'read-only'>('full')
  const [created, setCreated] = useState<CreatedAccessKey | null>(null)
  const [error, setError] = useState('')

  const refresh = useCallback(() => {
    api.listAccessKeys().then(setKeys).catch((reason: Error) => setError(reason.message))
  }, [api])

  useEffect(refresh, [refresh])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      const result = await api.createAccessKey(owner.trim(), policy === 'full' ? fullAccess : readOnly)
      setCreated(result)
      setOwner('')
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function toggle(key: AccessKey) {
    try {
      await api.setAccessKeyEnabled(key.id, !key.enabled)
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function remove(key: AccessKey) {
    if (!window.confirm(`删除 Access Key “${key.access_key}”？`)) return
    try {
      await api.deleteAccessKey(key.id)
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Credentials</p><h2>Access Keys</h2><p className="page-description">为文件客户端创建和管理 S3 访问凭证。</p></div>
        <span className="count-badge">{keys.length} 个凭证</span>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <section className="panel create-panel">
        <div className="section-heading"><div><h3>创建 Access Key</h3><p>Secret Key 只会在创建成功时显示一次。</p></div></div>
        <form className="form-grid" onSubmit={create}>
          <label>Owner / tenant<input aria-label="Credential owner" placeholder="owner / tenant" value={owner} onChange={(event) => setOwner(event.target.value)} required /></label>
          <label>Policy<select aria-label="Credential policy" value={policy} onChange={(event) => setPolicy(event.target.value as 'full' | 'read-only')}><option value="full">Full access</option><option value="read-only">Read only</option></select></label>
          <button className="primary-button form-submit" type="submit">创建凭证</button>
        </form>
      </section>
      {created && (
        <div className="secret-panel">
          <div><span>Access Key</span><code>{created.access_key}</code></div>
          <div><span>Secret Key</span><code>{created.secret_key}</code></div>
          <button onClick={() => setCreated(null)}>关闭</button>
        </div>
      )}
      <section className="panel table-panel">
        <div className="section-heading"><div><h3>已配置凭证</h3><p>禁用凭证会立即阻止后续 S3 请求。</p></div><button className="secondary-button" type="button" onClick={() => refresh()}>刷新</button></div>
        <div className="table-wrap">
        <table>
          <thead><tr><th>Access Key</th><th>Owner</th><th>Policy</th><th>Status</th><th>Created</th><th /></tr></thead>
          <tbody>
            {keys.map((key) => (
              <tr key={key.id}>
                <td><code>{key.access_key}</code></td>
                <td>{key.owner}</td>
                <td>{key.policy.object_write ? 'Full access' : 'Read only'}</td>
                <td><button className="status-button" onClick={() => toggle(key)}>{key.enabled ? 'Enabled' : 'Disabled'}</button></td>
                <td>{new Date(key.created_at).toLocaleString()}</td>
                <td><button className="danger-button" onClick={() => remove(key)}>删除</button></td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
        {keys.length === 0 && <div className="empty-state empty-panel"><strong>还没有 Access Key</strong><span>创建凭证后即可用于对象上传和下载。</span></div>}
      </section>
    </section>
  )
}
