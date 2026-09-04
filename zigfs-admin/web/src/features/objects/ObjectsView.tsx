import { type ChangeEvent, type FormEvent, useEffect, useRef, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, Bucket, ObjectSummary, PresignObjectResponse } from '../../types/api'

interface ObjectsViewProps {
  api: ApiClient
  initialBucket?: string
  onBack: () => void
}

export function ObjectsView({ api, initialBucket = '', onBack }: ObjectsViewProps) {
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [accessKeys, setAccessKeys] = useState<AccessKey[]>([])
  const [bucket, setBucket] = useState('')
  const [accessKey, setAccessKey] = useState('')
  const [prefix, setPrefix] = useState('')
  const [objects, setObjects] = useState<ObjectSummary[]>([])
  const [nextToken, setNextToken] = useState('')
  const [putKey, setPutKey] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [generated, setGenerated] = useState<PresignObjectResponse | null>(null)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [loading, setLoading] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [deletingKey, setDeletingKey] = useState('')
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailUrl, setDetailUrl] = useState<PresignObjectResponse | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')
  const fileInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    Promise.all([api.listBuckets(), api.listAccessKeys()])
      .then(([bucketItems, keyItems]) => {
        setBuckets(bucketItems)
        setAccessKeys(keyItems.filter((item) => item.enabled))
        setBucket((current) => current || initialBucket || bucketItems[0]?.name || '')
        setAccessKey((current) => current || keyItems.find((item) => item.enabled)?.access_key || '')
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api])

  async function load(reset: boolean) {
    if (!bucket) return
    try {
      setLoading(true)
      setError('')
      const result = await api.listObjects(bucket, prefix, reset ? '' : nextToken)
      setObjects((current) => reset ? result.items : [...current, ...result.items])
      setNextToken(result.continuation_token ?? '')
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (bucket) void load(true)
  }, [bucket])

  async function createPresign(key: string, method: 'GET' | 'PUT' | 'DELETE') {
    if (!accessKey || !bucket || !key) return
    try {
      setError('')
      setGenerated(await api.presignObject(accessKey, bucket, key, method, 900))
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  function selectFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0] ?? null
    setFile(selected)
    if (selected && !putKey) setPutKey(selected.name)
    setNotice('')
  }

  async function upload(event: FormEvent) {
    event.preventDefault()
    const key = putKey.trim()
    if (!file || !key || !bucket || !accessKey) return
    try {
      setUploading(true)
      setError('')
      setNotice('')
      const presigned = await api.presignObject(accessKey, bucket, key, 'PUT', 900)
      const response = await fetch(presigned.url, {
        method: 'PUT',
        headers: { 'Content-Type': file.type || 'application/octet-stream' },
        body: file,
      })
      if (!response.ok) throw new Error(`上传失败（${response.status}）`)
      setFile(null)
      setPutKey('')
      if (fileInput.current) fileInput.current.value = ''
      setNotice(`已上传 ${key}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setUploading(false)
    }
  }

  async function download(object: ObjectSummary) {
    if (!accessKey || !bucket) return
    try {
      setError('')
      setNotice(`正在准备 ${object.key}`)
      const presigned = await api.presignObject(accessKey, bucket, object.key, 'GET', 900)
      const response = await fetch(presigned.url)
      if (!response.ok) throw new Error(`下载失败（${response.status}）`)
      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = object.key.split('/').pop() || object.key
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
      setNotice(`已下载 ${object.key}`)
    } catch (reason) {
      setError((reason as Error).message)
      setNotice('')
    }
  }

  async function openDetail(object: ObjectSummary) {
    setDetail(object)
    setDetailUrl(null)
    setDetailError('')
    if (!accessKey || !bucket) return
    try {
      setDetailLoading(true)
      setDetailUrl(await api.presignObject(accessKey, bucket, object.key, 'GET', 900))
    } catch (reason) {
      setDetailError((reason as Error).message)
    } finally {
      setDetailLoading(false)
    }
  }

  function closeDetail() {
    setDetail(null)
    setDetailUrl(null)
    setDetailError('')
  }

  async function removeObject(object: ObjectSummary) {
    if (!accessKey || !bucket || !window.confirm(`删除对象“${object.key}”？`)) return
    try {
      setDeletingKey(object.key)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, object.key, 'DELETE', 900)
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`删除失败（${response.status}）`)
      if (detail?.key === object.key) closeDetail()
      setNotice(`已删除 ${object.key}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeletingKey('')
    }
  }

  async function copyDetailUrl() {
    if (!detailUrl) return
    await navigator.clipboard.writeText(detailUrl.url)
    setNotice('预览链接已复制')
  }

  return (
    <section>
      <header className="page-header">
        <div>
          <button className="back-button" type="button" onClick={onBack}>← Buckets</button>
          <p className="eyebrow">Data plane</p>
          <h2>{bucket || 'Objects'}</h2>
          <p className="page-description">浏览、上传和下载这个 Bucket 中的对象。</p>
        </div>
        <span className="count-badge">{objects.length}{nextToken ? '+' : ''} 个对象</span>
      </header>
      {error && <p className="error-banner">{error}</p>}
      {notice && <p className="success-banner">{notice}</p>}
      <section className="panel object-controls">
        <div className="toolbar-row">
          <label>
            Bucket
            <select aria-label="Bucket" value={bucket} onChange={(event) => setBucket(event.target.value)} required>
              {buckets.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
            </select>
          </label>
          <label>
            Prefix filter
            <input aria-label="Object prefix" placeholder="prefix/" value={prefix} onChange={(event) => setPrefix(event.target.value)} />
          </label>
          <button className="secondary-button toolbar-button" type="button" onClick={() => void load(true)} disabled={!bucket || loading}>{loading ? '加载中...' : '查询'}</button>
          <button className="secondary-button toolbar-button" type="button" onClick={() => void load(true)} disabled={!bucket || loading}>刷新</button>
        </div>
        <div className="upload-row">
          <div className="upload-copy"><strong>上传对象</strong><span>文件将通过 Presigned URL 直接上传到 ZigFS。</span></div>
          <form className="upload-form" onSubmit={upload}>
            <input ref={fileInput} type="file" onChange={selectFile} aria-label="选择文件" />
            <input aria-label="Object key" placeholder="对象 Key，例如 images/logo.png" value={putKey} onChange={(event) => setPutKey(event.target.value)} required />
            <button className="primary-button" type="submit" disabled={!file || !putKey.trim() || !bucket || !accessKey || uploading}>{uploading ? '上传中...' : '上传文件'}</button>
          </form>
        </div>
        <label className="signing-key">
          Signing key
          <select value={accessKey} onChange={(event) => setAccessKey(event.target.value)}>
            {accessKeys.map((item) => <option key={item.id} value={item.access_key}>{item.owner} · {item.access_key}</option>)}
          </select>
        </label>
      </section>
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
                <td className="table-actions">
                  <button className="secondary-button" type="button" onClick={() => void openDetail(object)}>详情</button>
                  <button className="secondary-button" type="button" onClick={() => void download(object)} disabled={!accessKey}>下载</button>
                  <button className="danger-button" type="button" onClick={() => void removeObject(object)} disabled={!accessKey || deletingKey === object.key}>{deletingKey === object.key ? '删除中...' : '删除'}</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {objects.length === 0 && !loading && <div className="empty-state empty-panel"><strong>这个 Bucket 还是空的</strong><span>选择一个文件上传，对象会显示在这里。</span></div>}
      {loading && <p className="loading-state">正在加载对象...</p>}
      {nextToken && <button className="load-more" type="button" onClick={() => void load(false)}>加载更多</button>}
      {detail && (
        <div className="drawer-backdrop" role="presentation" onClick={closeDetail}>
          <aside className="detail-drawer" role="dialog" aria-modal="true" aria-label="对象详情" onClick={(event) => event.stopPropagation()}>
            <header className="drawer-header">
              <div><p className="eyebrow">Object details</p><h3>{detail.key}</h3></div>
              <button className="icon-button" type="button" aria-label="关闭详情" onClick={closeDetail}>×</button>
            </header>
            <div className="preview-frame">
              {isImageKey(detail.key) && detailUrl ? <img src={detailUrl.url} alt={detail.key} /> : <div className="format-icon" aria-label={`${fileExtension(detail.key)} 文件`}>{fileExtension(detail.key)}</div>}
              {!isImageKey(detail.key) && <span>暂不支持此格式预览</span>}
              {detailLoading && <span>正在生成预览链接...</span>}
            </div>
            {detailError && <p className="error-banner">{detailError}</p>}
            <dl className="detail-list">
              <div><dt>Object Key</dt><dd>{detail.key}</dd></div>
              <div><dt>Format</dt><dd>{fileExtension(detail.key)}</dd></div>
              <div><dt>Size</dt><dd>{formatBytes(detail.size)}</dd></div>
              <div><dt>ETag</dt><dd><code>{detail.etag}</code></dd></div>
              <div><dt>Modified</dt><dd>{new Date(detail.last_modified).toLocaleString()}</dd></div>
              {detailUrl && <div><dt>Link expires</dt><dd>{new Date(detailUrl.expires_at).toLocaleString()}</dd></div>}
            </dl>
            {detailUrl && <div className="drawer-actions"><a className="secondary-button" href={detailUrl.url} target="_blank" rel="noreferrer">打开预览链接</a><button className="secondary-button" type="button" onClick={() => void copyDetailUrl()}>复制链接</button></div>}
          </aside>
        </div>
      )}
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

function fileExtension(key: string) {
  const name = key.split('/').pop() || key
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toUpperCase().slice(0, 8) : 'FILE'
}

function isImageKey(key: string) {
  return /\.(avif|bmp|gif|jpe?g|png|svg|webp)$/i.test(key)
}
