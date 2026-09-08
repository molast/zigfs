import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { Plus, RefreshCw, Search, Trash2, X } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
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
  const showToast = useToast()
  const [keys, setKeys] = useState<AccessKey[]>([])
  const [owner, setOwner] = useState('')
  const [policy, setPolicy] = useState<'full' | 'read-only'>('full')
  const [kind, setKind] = useState<'permanent' | 'temporary'>('permanent')
  const [ttlSeconds, setTtlSeconds] = useState(3600)
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [created, setCreated] = useState<CreatedAccessKey | null>(null)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    try {
      setRefreshing(true)
      setError('')
      setKeys(await api.listAccessKeys())
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRefreshing(false)
    }
  }, [api])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filteredKeys = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return keys
    return keys.filter((key) => key.owner.toLowerCase().includes(needle) || key.access_key.toLowerCase().includes(needle))
  }, [keys, query])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      setError('')
      const result = await api.createAccessKey(
        owner.trim(),
        policy === 'full' ? fullAccess : readOnly,
        kind === 'temporary' ? ttlSeconds : undefined,
      )
      setCreated(result)
      setOwner('')
      setShowCreate(false)
      await refresh()
      showToast(`已创建 Access Key ${result.access_key}`)
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function toggle(key: AccessKey) {
    try {
      setError('')
      await api.setAccessKeyEnabled(key.id, !key.enabled)
      await refresh()
      showToast(`已${key.enabled ? '停用' : '启用'} Access Key ${key.access_key}`)
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function remove(key: AccessKey) {
    if (!window.confirm(`删除 Access Key “${key.access_key}”？`)) return
    try {
      setError('')
      await api.deleteAccessKey(key.id)
      await refresh()
      showToast(`已删除 Access Key ${key.access_key}`)
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Access Control</p><h2>Access Keys</h2><p className="page-description">为 S3 客户端创建和管理访问凭证。</p></div>
        <span className="count-badge">{keys.length} 个凭证</span>
      </header>
      {error && <p className="error-banner">{error}</p>}

      <div className="page-toolbar">
        <div className="toolbar-leading">
          <label className="search-box">
            <Search aria-hidden="true" />
            <input aria-label="搜索 Access Key" placeholder="搜索 AK 或 Owner" value={query} onChange={(event) => setQuery(event.target.value)} />
          </label>
        </div>
        <div className="toolbar-actions">
          <button className="primary-button" type="button" onClick={() => setShowCreate((current) => !current)}>
            <Plus className="button-icon" aria-hidden="true" />{showCreate ? '取消创建' : '创建 Access Key'}
          </button>
          <button className="secondary-button" type="button" onClick={() => void refresh()} disabled={refreshing}>
            <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />{refreshing ? '刷新中...' : '刷新'}
          </button>
        </div>
      </div>

      {showCreate && (
        <section className="panel create-panel credential-create-panel">
          <div className="section-heading"><div><h3>创建 Access Key</h3><p>开发阶段会直接显示 AK、SK 和临时 Session Token。</p></div></div>
          <form className="form-grid" onSubmit={create}>
            <label>Owner / tenant<input aria-label="Credential owner" placeholder="owner / tenant" value={owner} onChange={(event) => setOwner(event.target.value)} required /></label>
            <label>Policy<select aria-label="Credential policy" value={policy} onChange={(event) => setPolicy(event.target.value as 'full' | 'read-only')}><option value="full">Full access</option><option value="read-only">Read only</option></select></label>
            <label>类型<select aria-label="Credential kind" value={kind} onChange={(event) => setKind(event.target.value as 'permanent' | 'temporary')}><option value="permanent">永久凭证</option><option value="temporary">临时凭证</option></select></label>
            {kind === 'temporary' && <label>有效期（秒）<input aria-label="Credential TTL" type="number" min={60} max={43200} value={ttlSeconds} onChange={(event) => setTtlSeconds(Number(event.target.value))} required /></label>}
            <button className="primary-button form-submit" type="submit">确认创建</button>
          </form>
        </section>
      )}

      {created && (
        <div className="secret-panel">
          <div><span>Access Key</span><code>{created.access_key}</code></div>
          <div><span>Secret Key</span><code>{created.secret_key}</code></div>
          {created.session_token && <div><span>Session Token</span><code>{created.session_token}</code></div>}
          <button onClick={() => setCreated(null)}><X className="button-icon" aria-hidden="true" />关闭</button>
        </div>
      )}

      <section className="panel table-panel">
        <div className="table-wrap">
          <table>
            <thead><tr><th>AK / SK</th><th>Owner</th><th>Type / Expiry</th><th>Policy</th><th>Status</th><th>Created</th><th>Actions</th></tr></thead>
            <tbody>
              {filteredKeys.map((key) => (
                <tr key={key.id}>
                  <td><div className="credential-values"><code>AK: {key.access_key}</code>{key.secret_key && <code>SK: {key.secret_key}</code>}{key.session_token && <code>Token: {key.session_token}</code>}</div></td>
                  <td>{key.owner}</td>
                  <td>{key.kind === 'temporary' ? <><span>临时</span><small>{key.expires_at ? new Date(key.expires_at).toLocaleString() : '-'}</small></> : '永久'}</td>
                  <td>{key.policy.object_write ? 'Full access' : 'Read only'}</td>
                  <td><button className={`status-button credential-status ${key.enabled ? 'enabled' : 'disabled'}`} onClick={() => void toggle(key)}><span className="status-dot" />{key.enabled ? 'Enabled' : 'Disabled'}</button></td>
                  <td>{new Date(key.created_at).toLocaleString()}</td>
                  <td className="table-actions"><button className="danger-button" onClick={() => void remove(key)}><Trash2 className="button-icon" aria-hidden="true" />删除</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {filteredKeys.length === 0 && <div className="empty-state empty-panel"><strong>{keys.length === 0 ? '还没有 Access Key' : '没有匹配的凭证'}</strong><span>{keys.length === 0 ? '创建凭证后即可用于对象上传和下载。' : '请调整搜索条件后重试。'}</span></div>}
      </section>
    </section>
  )
}
