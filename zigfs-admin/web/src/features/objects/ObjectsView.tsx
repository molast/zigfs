import { type FormEvent, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, Bucket, ObjectSummary, PresignObjectResponse } from '../../types/api'

export function ObjectsView({ api }: { api: ApiClient }) {
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [accessKeys, setAccessKeys] = useState<AccessKey[]>([])
  const [bucket, setBucket] = useState('')
  const [accessKey, setAccessKey] = useState('')
  const [prefix, setPrefix] = useState('')
  const [objects, setObjects] = useState<ObjectSummary[]>([])
  const [nextToken, setNextToken] = useState('')
  const [putKey, setPutKey] = useState('')
  const [generated, setGenerated] = useState<PresignObjectResponse | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    Promise.all([api.listBuckets(), api.listAccessKeys()])
      .then(([bucketItems, keyItems]) => {
        setBuckets(bucketItems)
        setAccessKeys(keyItems.filter((item) => item.enabled))
        setBucket((current) => current || bucketItems[0]?.name || '')
        setAccessKey((current) => current || keyItems.find((item) => item.enabled)?.access_key || '')
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api])

  async function load(reset: boolean) {
    if (!bucket) return
    try {
      setError('')
      const result = await api.listObjects(bucket, prefix, reset ? '' : nextToken)
      setObjects((current) => reset ? result.items : [...current, ...result.items])
      setNextToken(result.continuation_token ?? '')
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function createPresign(key: string, method: 'GET' | 'PUT') {
    if (!accessKey || !bucket || !key) return
    try {
      setError('')
      setGenerated(await api.presignObject(accessKey, bucket, key, method, 900))
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  function submitFilter(event: FormEvent) {
    event.preventDefault()
    void load(true)
  }

  function submitPut(event: FormEvent) {
    event.preventDefault()
    void createPresign(putKey.trim(), 'PUT')
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Data plane</p><h2>Objects</h2></div>
        <form className="inline-form" onSubmit={submitFilter}>
          <select aria-label="Bucket" value={bucket} onChange={(event) => setBucket(event.target.value)} required>
            {buckets.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
          </select>
          <input aria-label="Object prefix" placeholder="prefix/" value={prefix} onChange={(event) => setPrefix(event.target.value)} />
          <button className="primary-button" type="submit" disabled={!bucket}>查询</button>
        </form>
      </header>
      {error && <p className="error-banner">{error}</p>}
      <div className="object-toolbar">
        <label>
          Signing key
          <select value={accessKey} onChange={(event) => setAccessKey(event.target.value)}>
            {accessKeys.map((item) => <option key={item.id} value={item.access_key}>{item.owner} · {item.access_key}</option>)}
          </select>
        </label>
        <form className="inline-form" onSubmit={submitPut}>
          <input aria-label="New object key" placeholder="new/object-key" value={putKey} onChange={(event) => setPutKey(event.target.value)} required />
          <button type="submit" disabled={!bucket || !accessKey}>生成 PUT URL</button>
        </form>
      </div>
      {generated && (
        <div className="presign-band">
          <a href={generated.url} target="_blank" rel="noreferrer">{generated.url}</a>
          <span>{new Date(generated.expires_at).toLocaleString()}</span>
          <button type="button" onClick={() => void navigator.clipboard.writeText(generated.url)}>复制</button>
        </div>
      )}
      <div className="table-wrap">
        <table>
          <thead><tr><th>Key</th><th>Size</th><th>ETag</th><th>Modified</th><th /></tr></thead>
          <tbody>
            {objects.map((object) => (
              <tr key={object.key}>
                <td className="object-key">{object.key}</td>
                <td>{formatBytes(object.size)}</td>
                <td><code>{object.etag}</code></td>
                <td>{new Date(object.last_modified).toLocaleString()}</td>
                <td><button type="button" onClick={() => void createPresign(object.key, 'GET')} disabled={!accessKey}>下载</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {objects.length === 0 && <p className="empty-state">暂无对象</p>}
      {nextToken && <button className="load-more" type="button" onClick={() => void load(false)}>加载更多</button>}
    </section>
  )
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index += 1
  }
  return `${value.toFixed(1)} ${units[index]}`
}
