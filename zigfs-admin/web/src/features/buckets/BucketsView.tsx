import { type FormEvent, useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { Bucket } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
}

export function BucketsView({ api }: BucketsViewProps) {
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
        </div>
        <form className="inline-form" onSubmit={create}>
          <input
            aria-label="Bucket name"
            placeholder="bucket-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            required
          />
          <input
            aria-label="Bucket owner"
            placeholder="owner / tenant"
            value={owner}
            onChange={(event) => setOwner(event.target.value)}
            required
          />
          <button className="primary-button" type="submit">创建</button>
        </form>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <div className="table-wrap">
          <table>
            <thead><tr><th>Name</th><th>Owner</th><th>Created</th><th /></tr></thead>
            <tbody>
              {buckets.map((bucket) => (
                <tr key={bucket.name}>
                  <td><strong>{bucket.name}</strong></td>
                  <td>{bucket.owner}</td>
                  <td>{new Date(bucket.created_at).toLocaleString()}</td>
                  <td><button className="danger-button" onClick={() => remove(bucket.name)}>删除</button></td>
                </tr>
              ))}
            </tbody>
          </table>
      </div>
    </section>
  )
}
