import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Copy, Download, KeyRound, Plus, RefreshCw, Search, Trash2, X } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
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
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [keys, setKeys] = useState<AccessKey[]>([])
  const [policy, setPolicy] = useState<'full' | 'read-only'>('full')
  const [kind, setKind] = useState<'permanent' | 'temporary'>('permanent')
  const [ttlSeconds, setTtlSeconds] = useState(3600)
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [created, setCreated] = useState<CreatedAccessKey | null>(null)
  const [error, setError] = useState('')
  const [createError, setCreateError] = useState('')

  const refresh = useCallback(async () => {
    const stopLoading = startLoading('正在加载 Access Keys...')
    try {
      setRefreshing(true)
      setError('')
      setKeys(await api.listAccessKeys())
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRefreshing(false)
      stopLoading()
    }
  }, [api, startLoading])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!showCreate && !created) return
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key !== 'Escape') return
      if (created) setCreated(null)
      else setShowCreate(false)
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [created, showCreate])

  const filteredKeys = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return keys
    return keys.filter((key) => key.owner.toLowerCase().includes(needle) || key.access_key.toLowerCase().includes(needle))
  }, [keys, query])

  async function create(event: FormEvent) {
    event.preventDefault()
    const stopLoading = startLoading('正在创建 Access Key...')
    try {
      setError('')
      setCreateError('')
      const result = await api.createAccessKey(
        policy === 'full' ? fullAccess : readOnly,
        kind === 'temporary' ? ttlSeconds : undefined,
      )
      setCreated(result)
      setShowCreate(false)
      await refresh()
      showToast(`已创建 Access Key ${result.access_key}`)
    } catch (reason) {
      setCreateError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function toggle(key: AccessKey) {
    const stopLoading = startLoading(`${key.enabled ? '正在停用' : '正在启用'} Access Key...`)
    try {
      setError('')
      await api.setAccessKeyEnabled(key.id, !key.enabled)
      await refresh()
      showToast(`已${key.enabled ? '停用' : '启用'} Access Key ${key.access_key}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function remove(key: AccessKey) {
    if (!await confirm({
      title: '删除 Access Key',
      message: `删除 Access Key “${key.access_key}”？此操作不可撤销。`,
      confirmLabel: '删除',
      danger: true,
    })) return
    const stopLoading = startLoading('正在删除 Access Key...')
    try {
      setError('')
      await api.deleteAccessKey(key.id)
      await refresh()
      showToast(`已删除 Access Key ${key.access_key}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function copyValue(label: string, value: string) {
    try {
      await navigator.clipboard.writeText(value)
      showToast(`${label} 已复制`)
    } catch {
      showToast(`无法复制 ${label}，请手动复制`)
    }
  }

  function downloadCredentials(key: CreatedAccessKey) {
    const rows = [
      ['field', 'value'],
      ['provider', 'ZigFS'],
      ['access_key', key.access_key],
      ['secret_key', key.secret_key],
      ...(key.session_token ? [['session_token', key.session_token]] : []),
      ['owner', key.owner],
      ['kind', key.kind],
      ...(key.expires_at ? [['expires_at', key.expires_at]] : []),
      ['policy', JSON.stringify(key.policy)],
      ['created_at', key.created_at],
    ]
    const csv = `\uFEFF${rows.map((row) => row.map(csvCell).join(',')).join('\r\n')}\r\n`
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    const safeAccessKey = key.access_key.replace(/[^A-Za-z0-9._-]/g, '-')
    anchor.href = url
    anchor.download = `zigfs-${safeAccessKey}-credentials.csv`
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
    window.setTimeout(() => URL.revokeObjectURL(url), 0)
    showToast('AK/SK 凭证文件已下载')
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
          <button className="primary-button create-action-button" type="button" onClick={() => { setCreateError(''); setShowCreate((current) => !current) }} aria-expanded={showCreate}>
            <Plus className="button-icon" aria-hidden="true" />{showCreate ? '取消创建' : '创建 Access Key'}
          </button>
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={refreshing} aria-busy={refreshing}>
            <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />刷新
          </button>
        </div>
      </div>

      {showCreate && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setShowCreate(false)}>
          <section className="lifecycle-modal credential-modal" role="dialog" aria-modal="true" aria-labelledby="credential-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><KeyRound aria-hidden="true" /><h3 id="credential-dialog-title">创建 Access Key</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={() => setShowCreate(false)}><X aria-hidden="true" /></button>
            </header>

            <form className="credential-modal-form" onSubmit={create}>
              <p className="credential-modal-description">凭证将自动绑定到当前管理员账号，开发阶段会直接显示 AK、SK 和临时 Session Token。</p>
              <div className="credential-modal-fields">
                <label>Policy<select aria-label="Credential policy" value={policy} onChange={(event) => setPolicy(event.target.value as 'full' | 'read-only')}><option value="full">Full access</option><option value="read-only">Read only</option></select></label>
                <label>类型<select aria-label="Credential kind" value={kind} onChange={(event) => setKind(event.target.value as 'permanent' | 'temporary')}><option value="permanent">永久凭证</option><option value="temporary">临时凭证</option></select></label>
                {kind === 'temporary' && <label>有效期（秒）<input aria-label="Credential TTL" type="number" min={60} max={43200} value={ttlSeconds} onChange={(event) => setTtlSeconds(Number(event.target.value))} required /></label>}
              </div>
              {createError && <p className="form-error credential-form-error" role="alert">{createError}</p>}
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setShowCreate(false)}>取消</button>
                <button className="primary-button" type="submit">确认创建</button>
              </footer>
            </form>
          </section>
        </div>
      )}

      {created && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setCreated(null)}>
          <section className="lifecycle-modal credential-result-modal" role="dialog" aria-modal="true" aria-labelledby="credential-result-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><KeyRound aria-hidden="true" /><h3 id="credential-result-title">New Access Key Created</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={() => setCreated(null)}><X aria-hidden="true" /></button>
            </header>
            <div className="credential-result-body">
              <p>Access Key 已创建，以下凭证只在本次创建后展示。</p>
              <CredentialValue label="Access Key" value={created.access_key} onCopy={() => void copyValue('Access Key', created.access_key)} />
              <CredentialValue label="Secret Key" value={created.secret_key} onCopy={() => void copyValue('Secret Key', created.secret_key)} />
              {created.session_token && <CredentialValue label="Session Token" value={created.session_token} onCopy={() => void copyValue('Session Token', created.session_token!)} />}
              <p className="credential-warning"><AlertTriangle aria-hidden="true" />请立即保存这些凭证，关闭后将不会再次显示 Secret Key。</p>
            </div>
            <footer className="lifecycle-modal-actions">
              <button className="secondary-button" type="button" onClick={() => downloadCredentials(created)}><Download className="button-icon" aria-hidden="true" />下载凭证文件</button>
              <button className="primary-button" type="button" onClick={() => setCreated(null)}>完成</button>
            </footer>
          </section>
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

function csvCell(value: string) {
  return `"${value.replace(/"/g, '""')}"`
}

function CredentialValue({ label, value, onCopy }: { label: string; value: string; onCopy: () => void }) {
  return (
    <div className="credential-value">
      <span>{label}</span>
      <div className="credential-value-row">
        <code>{value}</code>
        <button className="icon-button" type="button" aria-label={`复制 ${label}`} title={`复制 ${label}`} onClick={onCopy}><Copy aria-hidden="true" /></button>
      </div>
    </div>
  )
}
