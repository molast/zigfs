import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, Folder, FolderPlus, Plus, RefreshCw, Search, Trash2, X } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useToast } from '../../components/ToastProvider'
import type { Bucket } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
  onOpenBucket: (name: string) => void
}

export function BucketsView({ api, onOpenBucket }: BucketsViewProps) {
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [name, setName] = useState('')
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState('')
  const [createError, setCreateError] = useState('')

  const refresh = useCallback(async () => {
    const stopLoading = startLoading('正在加载 Buckets...')
    try {
      setRefreshing(true)
      setError('')
      setBuckets(await api.listBuckets())
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
    if (!showCreate) return
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') setShowCreate(false)
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [showCreate])

  const filteredBuckets = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return buckets
    return buckets.filter((bucket) => bucket.name.toLowerCase().includes(needle) || bucket.owner.toLowerCase().includes(needle))
  }, [buckets, query])

  async function create(event: FormEvent) {
    event.preventDefault()
    const stopLoading = startLoading('正在创建 Bucket...')
    try {
      setError('')
      setCreateError('')
      await api.createBucket(name.trim())
      setName('')
      setShowCreate(false)
      await refresh()
      showToast(`已创建 Bucket ${name.trim()}`)
    } catch (reason) {
      setCreateError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function remove(bucket: string) {
    if (!await confirm({
      title: '删除 Bucket',
      message: `删除 Bucket “${bucket}”？此操作不可撤销。`,
      confirmLabel: '删除',
      danger: true,
    })) return
    const stopLoading = startLoading('正在删除 Bucket...')
    try {
      setError('')
      await api.deleteBucket(bucket)
      await refresh()
      showToast(`已删除 Bucket ${bucket}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  return (
    <section>
      <header className="page-header">
        <div>
          <p className="eyebrow">Buckets</p>
          <h2>Buckets</h2>
          <p className="page-description">组织和浏览 ZigFS 中的对象存储空间。</p>
        </div>
        <span className="count-badge">{buckets.length} 个 Bucket</span>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <div className="page-toolbar">
        <div className="toolbar-leading">
          <label className="search-box">
            <Search aria-hidden="true" />
            <input aria-label="搜索 Bucket" placeholder="搜索 Bucket 或 Owner" value={query} onChange={(event) => setQuery(event.target.value)} />
          </label>
        </div>
        <div className="toolbar-actions">
          <button className="primary-button create-action-button" type="button" onClick={() => { setCreateError(''); setShowCreate(true) }} aria-haspopup="dialog" aria-expanded={showCreate}>
            <Plus className="button-icon" aria-hidden="true" />创建 Bucket
          </button>
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={refreshing} aria-busy={refreshing}>
            <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />刷新
          </button>
        </div>
      </div>
      {showCreate && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setShowCreate(false)}>
          <section className="lifecycle-modal credential-modal bucket-create-modal" role="dialog" aria-modal="true" aria-labelledby="bucket-create-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><FolderPlus aria-hidden="true" /><h3 id="bucket-create-dialog-title">创建 Bucket</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={() => setShowCreate(false)}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={create}>
              <p className="credential-modal-description">名称创建后不可修改。Bucket 将自动绑定到当前管理员账号。</p>
              <div className="credential-modal-fields">
                <label>Bucket name<input aria-label="Bucket name" placeholder="bucket-name" value={name} onChange={(event) => setName(event.target.value)} required autoFocus /></label>
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
      <section className="panel table-panel">
        <div className="table-wrap">
          <table>
            <thead><tr><th>Bucket</th><th>Owner</th><th>Creation Date</th><th>Actions</th></tr></thead>
            <tbody>
              {filteredBuckets.map((bucket) => (
                <tr key={bucket.name}>
                  <td>
                    <div className="bucket-cell"><Folder className="bucket-symbol" aria-hidden="true" /><button className="link-button bucket-link" onClick={() => onOpenBucket(bucket.name)}>{bucket.name}</button></div>
                  </td>
                  <td>{bucket.owner}</td>
                  <td>{new Date(bucket.created_at).toLocaleString()}</td>
                  <td className="table-actions">
                    <button className="secondary-button" onClick={() => onOpenBucket(bucket.name)}><ArrowRight className="button-icon" aria-hidden="true" />打开</button>
                    <button className="danger-button" onClick={() => void remove(bucket.name)}><Trash2 className="button-icon" aria-hidden="true" />删除</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {filteredBuckets.length === 0 && (
          <div className="empty-state empty-panel">
            <strong>{buckets.length === 0 ? '还没有 Bucket' : '没有匹配的 Bucket'}</strong>
            <span>{buckets.length === 0 ? '创建第一个 Bucket 后，它会显示在这里。' : '请调整搜索条件后重试。'}</span>
          </div>
        )}
      </section>
    </section>
  )
}
