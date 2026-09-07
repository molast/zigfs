import { type ChangeEvent, type FormEvent, useEffect, useRef, useState } from 'react'
import {
  ArrowLeft,
  Copy,
  Download,
  ExternalLink,
  File,
  FolderOpen,
  Info,
  RefreshCw,
  Search,
  Trash2,
  Upload,
  X,
} from 'lucide-react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, Bucket, ObjectSummary, PresignObjectResponse } from '../../types/api'

interface ObjectsViewProps {
  api: ApiClient
  initialBucket?: string
  onBack: () => void
}

interface UploadProgress {
  loaded: number
  total: number
  percent: number
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
  const [showUpload, setShowUpload] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [loading, setLoading] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState<UploadProgress | null>(null)
  const [deletingKey, setDeletingKey] = useState('')
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailUrl, setDetailUrl] = useState<PresignObjectResponse | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')
  const fileInput = useRef<HTMLInputElement>(null)
  const uploadRequest = useRef<XMLHttpRequest | null>(null)

  useEffect(() => {
    Promise.all([api.listBuckets(), api.listAccessKeys()])
      .then(([bucketItems, keyItems]) => {
        const enabledKeys = keyItems.filter((item) => item.enabled)
        setBuckets(bucketItems)
        setAccessKeys(enabledKeys)
        setBucket((current) => current || initialBucket || bucketItems[0]?.name || '')
        setAccessKey((current) => current || enabledKeys[0]?.access_key || '')
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api, initialBucket])

  async function load(reset: boolean) {
    if (!bucket) return
    try {
      setLoading(true)
      setError('')
      const result = await api.listObjects(bucket, prefix.trim(), reset ? '' : nextToken)
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

  useEffect(() => () => uploadRequest.current?.abort(), [])

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
      setUploadProgress({ loaded: 0, total: file.size, percent: 0 })
      await putFile(presigned.url, file, setUploadProgress, (request) => {
        uploadRequest.current = request
      })
      setFile(null)
      setPutKey('')
      setShowUpload(false)
      if (fileInput.current) fileInput.current.value = ''
      setNotice(`已上传 ${key}`)
      await load(true)
    } catch (reason) {
      if (reason instanceof Error && reason.name === 'AbortError') setNotice('上传已取消，可重新开始上传')
      else setError((reason as Error).message)
    } finally {
      uploadRequest.current = null
      setUploading(false)
      setUploadProgress(null)
    }
  }

  function cancelUpload() {
    uploadRequest.current?.abort()
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
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />返回 Buckets</button>
          <h2>Object Browser</h2>
          <p className="page-description">浏览、上传、下载和管理 Bucket 中的对象。</p>
        </div>
        <span className="count-badge">{objects.length}{nextToken ? '+' : ''} 个对象</span>
      </header>

      <div className="object-location" aria-label="当前对象路径">
        <FolderOpen className="object-location-icon" aria-hidden="true" />
        <button className="object-location-link" type="button" onClick={onBack} disabled={!bucket}>{bucket || '未选择 Bucket'}</button>
        <b>/</b><span>{prefix.trim() || 'root'}</span>
      </div>
      {error && <p className="error-banner">{error}</p>}
      {notice && <p className="success-banner">{notice}</p>}

      <div className="page-toolbar">
        <div className="toolbar-leading object-toolbar-leading">
          <select aria-label="Bucket" value={bucket} onChange={(event) => setBucket(event.target.value)} disabled={uploading} required>
            {buckets.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
          </select>
          <label className="search-box">
            <Search aria-hidden="true" />
            <input
              aria-label="Object prefix"
              placeholder="按对象 Key 前缀筛选"
              value={prefix}
              onChange={(event) => setPrefix(event.target.value)}
              onKeyDown={(event) => { if (event.key === 'Enter') void load(true) }}
            />
          </label>
        </div>
        <div className="toolbar-actions">
          <button className="primary-button" type="button" onClick={() => setShowUpload((current) => !current)} disabled={!bucket || !accessKey || uploading}>
            <Upload className="button-icon" aria-hidden="true" />{uploading ? '上传中...' : showUpload ? '关闭上传' : '上传文件'}
          </button>
          <button className="secondary-button" type="button" onClick={() => void load(true)} disabled={!bucket || loading}>
            <RefreshCw className={`button-icon${loading ? ' spinning' : ''}`} aria-hidden="true" />{loading ? '加载中...' : '刷新'}
          </button>
        </div>
      </div>

      <div className="signing-bar">
        <span>Signing credential</span>
        {accessKeys.length > 0 ? (
          <select value={accessKey} onChange={(event) => setAccessKey(event.target.value)} aria-label="Signing credential" disabled={uploading}>
            {accessKeys.map((item) => <option key={item.id} value={item.access_key}>{item.owner} · {item.access_key}</option>)}
          </select>
        ) : <strong>没有可用的 Access Key</strong>}
      </div>

      {showUpload && (
        <section className="panel create-panel upload-panel">
          <div className="section-heading"><div><h3>上传对象</h3><p>对象字节通过 Presigned URL 直接传输到 ZigFS。</p></div></div>
          <form className="upload-form" onSubmit={upload}>
            <input ref={fileInput} type="file" onChange={selectFile} aria-label="选择文件" disabled={uploading} />
            <input aria-label="Object key" placeholder="对象 Key，例如 images/logo.png" value={putKey} onChange={(event) => setPutKey(event.target.value)} disabled={uploading} required />
            <button className="primary-button" type="submit" disabled={!file || !putKey.trim() || !bucket || !accessKey || uploading}><Upload className="button-icon" aria-hidden="true" />{uploading ? '上传中...' : '开始上传'}</button>
          </form>
          {uploading && uploadProgress && (
            <div className="upload-progress" aria-live="polite">
              <div className="upload-progress-heading">
                <div><strong>{file?.name}</strong><span>{formatBytes(uploadProgress.loaded)} / {formatBytes(uploadProgress.total)} · {uploadProgress.percent}%</span></div>
                <button className="secondary-button" type="button" onClick={cancelUpload}><X className="button-icon" aria-hidden="true" />取消上传</button>
              </div>
              <div
                className="upload-progress-track"
                role="progressbar"
                aria-label={`${file?.name ?? '对象'}上传进度`}
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={uploadProgress.percent}
              >
                <span style={{ width: `${uploadProgress.percent}%` }} />
              </div>
            </div>
          )}
        </section>
      )}

      <section className="panel table-panel">
        <div className="table-wrap">
          <table className="object-table">
            <thead><tr><th>Object</th><th>Size</th><th>ETag</th><th>Last Modified</th><th>Actions</th></tr></thead>
            <tbody>
              {objects.map((object) => (
                <tr key={object.key}>
                  <td className="object-key"><div className="file-cell"><File className="file-symbol" aria-hidden="true" /><span>{object.key}</span></div></td>
                  <td>{formatBytes(object.size)}</td>
                  <td><code>{object.etag}</code></td>
                  <td>{new Date(object.last_modified).toLocaleString()}</td>
                  <td className="table-actions">
                    <button className="secondary-button" type="button" onClick={() => void openDetail(object)}><Info className="button-icon" aria-hidden="true" />详情</button>
                    <button className="secondary-button" type="button" onClick={() => void download(object)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>
                    <button className="danger-button" type="button" onClick={() => void removeObject(object)} disabled={!accessKey || deletingKey === object.key}><Trash2 className="button-icon" aria-hidden="true" />{deletingKey === object.key ? '删除中...' : '删除'}</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {objects.length === 0 && !loading && <div className="empty-state empty-panel"><strong>这个 Bucket 还是空的</strong><span>上传文件后，对象会显示在这里。</span></div>}
        {loading && <p className="loading-state">正在加载对象...</p>}
      </section>
      {nextToken && <button className="load-more" type="button" onClick={() => void load(false)}>加载更多</button>}

      {detail && (
        <div className="drawer-backdrop" role="presentation" onClick={closeDetail}>
          <aside className="detail-drawer" role="dialog" aria-modal="true" aria-label="对象详情" onClick={(event) => event.stopPropagation()}>
            <header className="drawer-header">
              <div><p className="eyebrow">Object details</p><h3>{detail.key}</h3></div>
              <button className="icon-button" type="button" aria-label="关闭详情" onClick={closeDetail}><X aria-hidden="true" /></button>
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
            {detailUrl && <div className="drawer-actions"><a className="secondary-button" href={detailUrl.url} target="_blank" rel="noreferrer"><ExternalLink className="button-icon" aria-hidden="true" />打开预览链接</a><button className="secondary-button" type="button" onClick={() => void copyDetailUrl()}><Copy className="button-icon" aria-hidden="true" />复制链接</button></div>}
          </aside>
        </div>
      )}
    </section>
  )
}

function putFile(
  url: string,
  file: File,
  onProgress: (progress: UploadProgress) => void,
  onRequest: (request: XMLHttpRequest) => void,
) {
  return new Promise<void>((resolve, reject) => {
    const request = new XMLHttpRequest()
    request.open('PUT', url)
    request.setRequestHeader('Content-Type', file.type || 'application/octet-stream')

    request.upload.addEventListener('progress', (event) => {
      const total = event.lengthComputable && event.total > 0 ? event.total : file.size
      const loaded = Math.min(event.loaded, total || event.loaded)
      const percent = total > 0 ? Math.min(100, Math.round((loaded / total) * 100)) : 0
      onProgress({ loaded, total, percent })
    })
    request.addEventListener('load', () => {
      if (request.status >= 200 && request.status < 300) {
        onProgress({ loaded: file.size, total: file.size, percent: 100 })
        resolve()
      } else {
        reject(new Error(`上传失败（${request.status}）`))
      }
    })
    request.addEventListener('error', () => reject(new Error('上传失败（网络错误）')))
    request.addEventListener('abort', () => {
      const error = new Error('上传已取消')
      error.name = 'AbortError'
      reject(error)
    })

    onRequest(request)
    request.send(file)
  })
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
