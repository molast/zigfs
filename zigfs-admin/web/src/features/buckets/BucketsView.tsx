import { type FormEvent, useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { Bucket } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
  onOpenBucket: (name: string) => void
}

export function BucketsView({ api, onOpenBucket }: BucketsViewProps) {
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [name, setName] = useState('')
  const [owner, setOwner] = useState('')
  const [error, setError] = useState('')

  const refresh = useCallback(() => {
    api.listBuckets().then(setBuckets).catch((reason: Error) => setError(reason.message))
  }, [api])

  useEffect(refresh, [refresh])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      await api.createBucket(name.trim(), owner.trim())
      setName('')
      setOwner('')
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function remove(bucket: string) {
    if (!window.confirm(`删除 Bucket “${bucket}”？`)) return
    try {
      await api.deleteBucket(bucket)
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  return (
    <section>
      <header className="page-header">
        <div>
          <p className="eyebrow">Storage</p>
          <h2>Buckets</h2>
          <p className="page-description">组织对象和访问权限的存储空间。</p>
        </div>
        <span className="count-badge">{buckets.length} 个 Bucket</span>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <section className="panel create-panel">
        <div className="section-heading">
          <div>
            <h3>创建 Bucket</h3>
            <p>为新的对象空间设置名称和所属租户。</p>
          </div>
        </div>
        <form className="form-grid" onSubmit={create}>
          <label>
            Bucket name
            <input
              aria-label="Bucket name"
              placeholder="bucket-name"
              value={name}
              onChange={(event) => setName(event.target.value)}
              required
            />
          </label>
          <label>
            Owner / tenant
            <input
              aria-label="Bucket owner"
              placeholder="owner / tenant"
              value={owner}
              onChange={(event) => setOwner(event.target.value)}
              required
            />
          </label>
          <button className="primary-button form-submit" type="submit">创建 Bucket</button>
        </form>
      </section>
      <section className="panel table-panel">
        <div className="section-heading">
          <div>
            <h3>全部 Bucket</h3>
            <p>选择一个 Bucket 管理其中的对象。</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => refresh()}>刷新</button>
        </div>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Name</th><th>Owner</th><th>Created</th><th /></tr></thead>
            <tbody>
              {buckets.map((bucket) => (
                <tr key={bucket.name}>
                  <td><button className="link-button bucket-link" onClick={() => onOpenBucket(bucket.name)}>{bucket.name}</button></td>
                  <td>{bucket.owner}</td>
                  <td>{new Date(bucket.created_at).toLocaleString()}</td>
                  <td className="table-actions"><button className="secondary-button" onClick={() => onOpenBucket(bucket.name)}>打开</button><button className="danger-button" onClick={() => remove(bucket.name)}>删除</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {buckets.length === 0 && <div className="empty-state empty-panel"><strong>还没有 Bucket</strong><span>创建第一个 Bucket 后，它会显示在这里。</span></div>}
      </section>
    </section>
  )
}
