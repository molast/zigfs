import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, Folder, Plus, RefreshCw, Search, Trash2 } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
import type { Bucket } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
  onOpenBucket: (name: string) => void
}

export function BucketsView({ api, onOpenBucket }: BucketsViewProps) {
  const showToast = useToast()
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [name, setName] = useState('')
  const [owner, setOwner] = useState('')
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    try {
      setRefreshing(true)
      setError('')
      setBuckets(await api.listBuckets())
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRefreshing(false)
    }
  }, [api])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filteredBuckets = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return buckets
    return buckets.filter((bucket) => bucket.name.toLowerCase().includes(needle) || bucket.owner.toLowerCase().includes(needle))
  }, [buckets, query])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      setError('')
      await api.createBucket(name.trim(), owner.trim())
      setName('')
      setOwner('')
      setShowCreate(false)
      await refresh()
      showToast(`已创建 Bucket ${name.trim()}`)
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function remove(bucket: string) {
    if (!window.confirm(`删除 Bucket “${bucket}”？`)) return
    try {
      setError('')
      await api.deleteBucket(bucket)
      await refresh()
      showToast(`已删除 Bucket ${bucket}`)
    } catch (reason) {
      setError((reason as Error).message)
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
          <button className="primary-button" type="button" onClick={() => setShowCreate((current) => !current)}>
            <Plus className="button-icon" aria-hidden="true" />{showCreate ? '取消创建' : '创建 Bucket'}
          </button>
          <button className="secondary-button" type="button" onClick={() => void refresh()} disabled={refreshing}>
            <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />{refreshing ? '刷新中...' : '刷新'}
          </button>
        </div>
      </div>
      {showCreate && (
        <section className="panel create-panel">
          <div className="section-heading">
            <div><h3>创建 Bucket</h3><p>名称创建后不可修改，Owner 用于标识所属租户。</p></div>
          </div>
          <form className="form-grid" onSubmit={create}>
            <label>
              Bucket name
              <input aria-label="Bucket name" placeholder="bucket-name" value={name} onChange={(event) => setName(event.target.value)} required />
            </label>
            <label>
              Owner / tenant
              <input aria-label="Bucket owner" placeholder="owner / tenant" value={owner} onChange={(event) => setOwner(event.target.value)} required />
            </label>
            <button className="primary-button form-submit" type="submit">确认创建</button>
          </form>
        </section>
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
