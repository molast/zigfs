import { type FormEvent, useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { Bucket, ObjectSummary } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
}

export function BucketsView({ api }: BucketsViewProps) {
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [objects, setObjects] = useState<ObjectSummary[]>([])
  const [selected, setSelected] = useState('')
  const [name, setName] = useState('')
  const [error, setError] = useState('')

  const refresh = useCallback(() => {
    api.listBuckets().then(setBuckets).catch((reason: Error) => setError(reason.message))
  }, [api])

  useEffect(refresh, [refresh])

  async function create(event: FormEvent) {
    event.preventDefault()
    try {
      await api.createBucket(name.trim())
      setName('')
      refresh()
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function selectBucket(bucket: string) {
    setSelected(bucket)
    try {
      setObjects(await api.listObjects(bucket))
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function remove(bucket: string) {
    if (!window.confirm(`删除 Bucket “${bucket}”？`)) return
    try {
      await api.deleteBucket(bucket)
      if (selected === bucket) {
        setSelected('')
        setObjects([])
      }
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
          <button className="primary-button" type="submit">创建</button>
        </form>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <div className="split-view">
        <div className="table-wrap">
          <table>
            <thead><tr><th>Name</th><th>Created</th><th /></tr></thead>
            <tbody>
              {buckets.map((bucket) => (
                <tr key={bucket.name} className={selected === bucket.name ? 'selected-row' : ''}>
                  <td><button className="link-button" onClick={() => selectBucket(bucket.name)}>{bucket.name}</button></td>
                  <td>{new Date(bucket.created_at).toLocaleString()}</td>
                  <td><button className="danger-button" onClick={() => remove(bucket.name)}>删除</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="object-pane">
          <h3>{selected || 'Objects'}</h3>
          {selected && objects.length === 0 && <p className="empty-state">暂无对象</p>}
          {objects.map((object) => (
            <div className="object-row" key={object.key}>
              <span>{object.key}</span>
              <small>{object.size.toLocaleString()} B</small>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
