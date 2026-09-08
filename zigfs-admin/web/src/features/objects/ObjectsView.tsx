import { type ChangeEvent, type FormEvent, useEffect, useRef, useState } from 'react'
import {
  ArrowLeft,
  Copy,
  Download,
  ExternalLink,
  File,
  FolderOpen,
  History,
  Info,
  Pause,
  Play,
  RefreshCw,
  RotateCcw,
  Search,
  Trash2,
  Upload,
  X,
} from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import type { AccessKey, MultipartUpload, MultipartUploadSummary, ObjectSummary, ObjectVersion, PresignObjectResponse } from '../../types/api'
import {
  choosePartSize,
  formatBytes,
  inferPartSize,
  loadPersistedTasks,
  persistTasks,
  putPart,
  validateResumeFile,
  type UploadTask,
} from './multipart-upload'

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
  const [accessKeys, setAccessKeys] = useState<AccessKey[]>([])
  const bucket = initialBucket
  const [accessKey, setAccessKey] = useState('')
  const [prefix, setPrefix] = useState('')
  const [viewMode, setViewMode] = useState<'current' | 'versions'>('current')
  const [objects, setObjects] = useState<ObjectSummary[]>([])
  const [versions, setVersions] = useState<ObjectVersion[]>([])
  const [nextToken, setNextToken] = useState('')
  const [putKey, setPutKey] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [showUpload, setShowUpload] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [loading, setLoading] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState<UploadProgress | null>(null)
  const [uploadTasks, setUploadTasks] = useState<UploadTask[]>([])
  const [uploadsLoading, setUploadsLoading] = useState(false)
  const [deletingKey, setDeletingKey] = useState('')
  const [deletingVersion, setDeletingVersion] = useState('')
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailUrl, setDetailUrl] = useState<PresignObjectResponse | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')
  const fileInput = useRef<HTMLInputElement>(null)
  const uploadControl = useRef<{
    uploadId: string
    paused: boolean
    cancelled: boolean
    completing: boolean
    request: XMLHttpRequest | null
  } | null>(null)
  const uploadsHydrated = useRef(false)

  useEffect(() => {
    api.listAccessKeys()
      .then((keyItems) => {
        const enabledKeys = keyItems.filter((item) => item.enabled)
        setAccessKeys(enabledKeys)
        setAccessKey((current) => current || enabledKeys[0]?.access_key || '')
      })
      .catch((reason: Error) => setError(reason.message))
  }, [api])

  async function load(reset: boolean) {
    if (!bucket) return
    try {
      setLoading(true)
      setError('')
      if (viewMode === 'versions') {
        setVersions(await api.listObjectVersions(bucket, prefix.trim()))
        setNextToken('')
      } else {
        const result = await api.listObjects(bucket, prefix.trim(), reset ? '' : nextToken)
        setObjects((current) => reset ? result.items : [...current, ...result.items])
        setNextToken(result.continuation_token ?? '')
      }
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (bucket) void load(true)
  }, [bucket, viewMode])

  useEffect(() => () => {
    if (uploadControl.current) {
      uploadControl.current.paused = true
      uploadControl.current.request?.abort()
    }
  }, [])

  useEffect(() => {
    if (uploadsHydrated.current) persistTasks(uploadTasks, bucket)
  }, [uploadTasks])

  useEffect(() => {
    if (bucket) void loadMultipartUploads()
  }, [bucket])

  function selectFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0] ?? null
    setFile(selected)
    if (selected && !putKey) setPutKey(selected.name)
    setNotice('')
  }

  async function loadMultipartUploads() {
    if (!bucket) return
    try {
      uploadsHydrated.current = false
      setUploadsLoading(true)
      setError('')
      let keyMarker = ''
      let uploadIDMarker = ''
      const summaries: MultipartUploadSummary[] = []
      do {
        const page = await api.listMultipartUploads(bucket, '', keyMarker, uploadIDMarker)
        summaries.push(...page.items)
        keyMarker = page.is_truncated ? page.next_key_marker ?? '' : ''
        uploadIDMarker = page.is_truncated ? page.next_upload_id_marker ?? '' : ''
        if (!page.is_truncated) break
      } while (keyMarker)
      const detailResults = await Promise.all(summaries.map(async (summary) => {
        try {
          return await api.getMultipartUpload(summary.upload_id, summary.bucket, summary.key)
        } catch (reason) {
          // Complete removes the UploadId after publishing the Object. The
          // upload can therefore disappear between ListUploads and ListParts.
          if (isMultipartUploadMissing(reason)) return null
          throw reason
        }
      }))
      const details = detailResults.filter((upload): upload is MultipartUpload => upload !== null)
      const completedDuringSync = details.length !== summaries.length
      const persisted = loadPersistedTasks()
      setUploadTasks((current) => {
        const live = new Map(current.map((task) => [task.uploadId, task]))
        return details.map((upload) => {
          const existing = live.get(upload.upload_id)
          const saved = persisted.get(upload.upload_id)
          return {
            uploadId: upload.upload_id,
            bucket: upload.bucket,
            key: upload.key,
            fileName: existing?.fileName || saved?.fileName || upload.key.split('/').pop() || upload.key,
            fileSize: existing?.fileSize || saved?.fileSize || 0,
            lastModified: existing?.lastModified || saved?.lastModified || 0,
            contentType: existing?.contentType || saved?.contentType || upload.content_type,
            partSize: existing?.partSize || saved?.partSize || upload.parts[0]?.size || 0,
            initiatedAt: upload.initiated_at,
            uploadedBytes: upload.uploaded_bytes,
            completedParts: upload.parts.length,
            status: existing?.status === 'uploading' ? 'uploading' : 'paused',
            file: existing?.file,
          }
        })
      })
      uploadsHydrated.current = true
      if (completedDuringSync) await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setUploadsLoading(false)
    }
  }

  async function upload(event: FormEvent) {
    event.preventDefault()
    const key = putKey.trim()
    if (!file || !key || !bucket || !accessKey) return
    try {
      setError('')
      setNotice('')
      const created = await api.createMultipartUpload(bucket, key, file.type || 'application/octet-stream')
      const task: UploadTask = {
        uploadId: created.upload_id,
        bucket,
        key,
        fileName: file.name,
        fileSize: file.size,
        lastModified: file.lastModified,
        contentType: file.type || 'application/octet-stream',
        partSize: choosePartSize(file.size),
        initiatedAt: created.initiated_at,
        uploadedBytes: 0,
        completedParts: 0,
        status: 'paused',
        file,
      }
      setUploadTasks((current) => [task, ...current])
      setFile(null)
      setPutKey('')
      if (fileInput.current) fileInput.current.value = ''
      await runUpload(task, file)
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function runUpload(task: UploadTask, selectedFile: File) {
    if (!accessKey || uploadControl.current) return
    const control = {
      uploadId: task.uploadId,
      paused: false,
      cancelled: false,
      completing: false,
      request: null as XMLHttpRequest | null,
    }
    uploadControl.current = control
    setUploading(true)
    setError('')
    setNotice('')
    let committedBytes = task.uploadedBytes
    let committedParts = task.completedParts
    try {
      const serverUpload = await api.getMultipartUpload(task.uploadId, task.bucket, task.key)
      const partSize = inferPartSize(serverUpload, selectedFile.size, task.partSize)
      validateResumeFile(task, serverUpload, selectedFile, partSize)
      const completed = new Map(serverUpload.parts.map((part) => [part.part_number, part]))
      committedBytes = serverUpload.parts.reduce((sum, part) => sum + part.size, 0)
      committedParts = completed.size
      const partCount = Math.max(1, Math.ceil(selectedFile.size / partSize))
      updateUploadTask(task.uploadId, {
        file: selectedFile,
        fileName: selectedFile.name,
        fileSize: selectedFile.size,
        lastModified: selectedFile.lastModified,
        contentType: selectedFile.type || task.contentType || 'application/octet-stream',
        partSize,
        uploadedBytes: committedBytes,
        completedParts: completed.size,
        status: 'uploading',
        error: undefined,
      })
      reportUploadProgress(committedBytes, selectedFile.size)

      for (let partNumber = 1; partNumber <= partCount; partNumber += 1) {
        if (completed.has(partNumber)) continue
        if (control.paused) throw abortError()
        const start = (partNumber - 1) * partSize
        const body = selectedFile.slice(start, Math.min(start + partSize, selectedFile.size))
        let etag = ''
        let lastError: Error | null = null
        for (let attempt = 1; attempt <= 3; attempt += 1) {
          try {
            const presigned = await api.presignObject(accessKey, task.bucket, task.key, 'PUT', 900, {
              uploadId: task.uploadId,
              partNumber,
            })
            if (control.paused) throw abortError()
            etag = await putPart(
              presigned.url,
              body,
              task.contentType,
              ({ loaded }) => {
                const totalLoaded = Math.min(selectedFile.size, committedBytes + loaded)
                reportUploadProgress(totalLoaded, selectedFile.size)
                updateUploadTask(task.uploadId, { uploadedBytes: totalLoaded })
              },
              (request) => { control.request = request },
            )
            control.request = null
            break
          } catch (reason) {
            control.request = null
            if (control.paused || (reason instanceof Error && reason.name === 'AbortError')) throw abortError()
            lastError = reason as Error
            if (attempt < 3) await delay(attempt * 300)
          }
        }
        if (!etag) throw lastError ?? new Error(`第 ${partNumber} 分片上传失败`)
        completed.set(partNumber, {
          part_number: partNumber,
          size: body.size,
          etag,
          last_modified: new Date().toISOString(),
        })
        committedBytes += body.size
        committedParts = completed.size
        updateUploadTask(task.uploadId, {
          uploadedBytes: committedBytes,
          completedParts: committedParts,
        })
      }
      if (control.paused) throw abortError()
      control.completing = true
      updateUploadTask(task.uploadId, {
        uploadedBytes: selectedFile.size,
        completedParts: completed.size,
        status: 'completing',
        error: undefined,
      })
      const completionParts = [...completed.values()]
        .sort((left, right) => left.part_number - right.part_number)
        .map((part) => ({ part_number: part.part_number, etag: part.etag }))
      try {
        await api.completeMultipartUpload(task.uploadId, task.bucket, task.key, completionParts)
      } catch (reason) {
        // The response can be lost after ZigFS has committed the Object. Do
        // not leave a false failed task when the UploadId is already gone.
        if (!(await completionPublished(task))) throw reason
      }
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      setNotice(`已上传 ${task.key}`)
      await load(true)
    } catch (reason) {
      if (control.cancelled) {
        return
      }
      if (reason instanceof Error && reason.name === 'AbortError') {
        updateUploadTask(task.uploadId, {
          uploadedBytes: committedBytes,
          completedParts: committedParts,
          status: 'paused',
          error: undefined,
        })
        setNotice(`已暂停 ${task.key}`)
      } else {
        const message = (reason as Error).message
        updateUploadTask(task.uploadId, { status: 'failed', error: message })
        setError(message)
      }
    } finally {
      if (uploadControl.current === control) uploadControl.current = null
      setUploading(false)
      setUploadProgress(null)
    }
  }

  function pauseUpload(task: UploadTask) {
    const control = uploadControl.current
    if (!control || control.uploadId !== task.uploadId || control.completing) return
    control.paused = true
    control.request?.abort()
  }

  async function abortUpload(task: UploadTask) {
    if (!window.confirm(`取消上传“${task.key}”并删除已上传的分片？`)) return
    const control = uploadControl.current
    if (control?.uploadId === task.uploadId && control.completing) {
      setNotice(`正在完成 ${task.key}`)
      return
    }
    if (control?.uploadId === task.uploadId) {
      control.paused = true
      control.cancelled = true
      control.request?.abort()
    }
    try {
      await api.abortMultipartUpload(task.uploadId, task.bucket, task.key)
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      setNotice(`已取消 ${task.key}`)
    } catch (reason) {
      const message = (reason as Error).message
      updateUploadTask(task.uploadId, { status: 'failed', error: message })
      setError(message)
    }
  }

  function attachResumeFile(task: UploadTask, event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0]
    event.target.value = ''
    if (!selected) return
    if ((task.fileSize > 0 && task.fileSize !== selected.size) ||
        (task.lastModified > 0 && task.lastModified !== selected.lastModified)) {
      updateUploadTask(task.uploadId, { status: 'failed', error: '文件大小或修改时间与原上传任务不一致' })
      return
    }
    updateUploadTask(task.uploadId, {
      file: selected,
      fileName: selected.name,
      fileSize: selected.size,
      lastModified: selected.lastModified,
      contentType: selected.type || task.contentType,
      status: 'paused',
      error: undefined,
    })
  }

  function updateUploadTask(uploadId: string, changes: Partial<UploadTask>) {
    setUploadTasks((current) => current.map((task) => task.uploadId === uploadId ? { ...task, ...changes } : task))
  }

  function reportUploadProgress(loaded: number, total: number) {
    setUploadProgress({ loaded, total, percent: total > 0 ? Math.min(100, Math.round((loaded / total) * 100)) : 0 })
  }

  async function completionPublished(task: UploadTask) {
    try {
      await api.getMultipartUpload(task.uploadId, task.bucket, task.key)
      return false
    } catch (reason) {
      if (!isMultipartUploadMissing(reason)) throw reason
    }

    let continuationToken = ''
    do {
      const result = await api.listObjects(task.bucket, task.key, continuationToken)
      if (result.items.some((object) => object.key === task.key)) return true
      continuationToken = result.continuation_token ?? ''
    } while (continuationToken)
    return false
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

  async function downloadVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker) return
    try {
      setError('')
      setNotice(`正在准备 ${version.key} 的指定版本`)
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'GET', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url)
      if (!response.ok) throw new Error(`下载失败（${response.status}）`)
      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = version.key.split('/').pop() || version.key
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
      setNotice(`已下载 ${version.key} 的版本 ${shortVersionId(version.version_id)}`)
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

  async function removeVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || !window.confirm(`永久删除“${version.key}”的版本 ${shortVersionId(version.version_id)}？此操作不会创建 DeleteMarker。`)) return
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setDeletingVersion(identity)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`删除版本失败（${response.status}）`)
      setNotice(`已永久删除 ${version.key} 的版本 ${shortVersionId(version.version_id)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeletingVersion('')
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
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />返回 Bucket</button>
          <h2>Object Browser</h2>
          <p className="page-description">浏览、上传、下载和管理 Bucket 中的对象。</p>
        </div>
        <span className="count-badge">{viewMode === 'current' ? `${objects.length}${nextToken ? '+' : ''} 个对象` : `${versions.length} 个版本`}</span>
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
          <div className="segmented-control object-view-switch" aria-label="对象列表模式">
            <button type="button" className={viewMode === 'current' ? 'active' : ''} onClick={() => setViewMode('current')}>当前对象</button>
            <button type="button" className={viewMode === 'versions' ? 'active' : ''} onClick={() => setViewMode('versions')}><History className="button-icon" aria-hidden="true" />所有版本</button>
          </div>
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
          <button className="primary-button" type="button" onClick={() => setShowUpload((current) => !current)} disabled={!bucket || !accessKey}>
            <Upload className="button-icon" aria-hidden="true" />{showUpload ? '关闭上传' : uploadTasks.length > 0 ? `上传任务 (${uploadTasks.length})` : '上传文件'}
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
          <div className="section-heading"><div><h3>上传对象</h3><p>Multipart 分片通过 Presigned URL 直接传输到 ZigFS。</p></div></div>
          <form className="upload-form" onSubmit={upload}>
            <input ref={fileInput} type="file" onChange={selectFile} aria-label="选择文件" disabled={uploading} />
            <input aria-label="Object key" placeholder="对象 Key，例如 images/logo.png" value={putKey} onChange={(event) => setPutKey(event.target.value)} disabled={uploading} required />
            <button className="primary-button" type="submit" disabled={!file || !putKey.trim() || !bucket || !accessKey || uploading}><Upload className="button-icon" aria-hidden="true" />{uploading ? '上传中...' : '开始上传'}</button>
          </form>
          {(uploadTasks.length > 0 || uploadsLoading) && (
            <div className="upload-task-list" aria-live="polite">
              <div className="upload-task-list-heading"><strong>未完成上传</strong><span>{uploadsLoading ? '同步中...' : `${uploadTasks.length} 个任务`}</span></div>
              {uploadTasks.map((task) => {
                const active = task.status === 'uploading' || task.status === 'completing'
                const taskProgress = active && uploadProgress
                  ? uploadProgress
                  : {
                      loaded: task.uploadedBytes,
                      total: task.fileSize,
                      percent: task.fileSize > 0 ? Math.min(100, Math.round((task.uploadedBytes / task.fileSize) * 100)) : 0,
                    }
                return (
                  <article className="upload-task" key={task.uploadId}>
                    <div className="upload-task-main">
                      <div className="upload-task-title"><strong>{task.key}</strong><span className={`upload-status ${task.status}`}>{task.status === 'uploading' ? '上传中' : task.status === 'completing' ? '完成中' : task.status === 'failed' ? '失败' : '已暂停'}</span></div>
                      <span>{task.fileName} · {task.fileSize > 0 ? `${formatBytes(taskProgress.loaded)} / ${formatBytes(task.fileSize)}` : formatBytes(task.uploadedBytes)} · {task.completedParts} 个分片</span>
                      {task.status === 'completing' && <span>ZigFS 正在完成对象</span>}
                      {task.error && <span className="upload-task-error">{task.error}</span>}
                      {!task.file && task.status !== 'uploading' && <span>需要重新选择本地文件</span>}
                    </div>
                    <div className="upload-task-actions">
                      {task.status === 'uploading' ? (
                        <button className="secondary-button" type="button" onClick={() => pauseUpload(task)}><Pause className="button-icon" aria-hidden="true" />暂停</button>
                      ) : task.status === 'completing' ? (
                        <button className="secondary-button" type="button" disabled><RefreshCw className="button-icon spinning" aria-hidden="true" />完成中</button>
                      ) : task.file ? (
                        <button className="secondary-button" type="button" disabled={uploading || !accessKey} onClick={() => void runUpload(task, task.file!)}>
                          {task.status === 'failed' ? <RotateCcw className="button-icon" aria-hidden="true" /> : <Play className="button-icon" aria-hidden="true" />}
                          {task.status === 'failed' ? '重试' : '继续'}
                        </button>
                      ) : (
                        <label className={`secondary-button file-picker-button${uploading ? ' disabled' : ''}`}>
                          <Upload className="button-icon" aria-hidden="true" />选择原文件
                          <input type="file" disabled={uploading} onChange={(event) => attachResumeFile(task, event)} />
                        </label>
                      )}
                      <button className="danger-button" type="button" disabled={task.status === 'completing' || (uploading && !active)} onClick={() => void abortUpload(task)}><Trash2 className="button-icon" aria-hidden="true" />取消</button>
                    </div>
                    <div
                      className="upload-progress-track"
                      role="progressbar"
                      aria-label={`${task.fileName}上传进度`}
                      aria-valuemin={0}
                      aria-valuemax={100}
                      aria-valuenow={taskProgress.percent}
                    >
                      <span style={{ width: `${taskProgress.percent}%` }} />
                    </div>
                  </article>
                )
              })}
            </div>
          )}
        </section>
      )}

      <section className="panel table-panel">
        <div className="table-wrap">
          {viewMode === 'current' ? <table className="object-table">
            <thead><tr><th>Object</th><th>Size</th><th>Last Modified</th><th>Actions</th></tr></thead>
            <tbody>{objects.map((object) => (
                <tr key={object.key}>
                  <td className="object-key"><div className="file-cell"><File className="file-symbol" aria-hidden="true" /><span>{object.key}</span></div></td>
                  <td>{formatBytes(object.size)}</td>
                  <td>{new Date(object.last_modified).toLocaleString()}</td>
                  <td className="table-actions">
                    <button className="secondary-button" type="button" onClick={() => void openDetail(object)}><Info className="button-icon" aria-hidden="true" />详情</button>
                    <button className="secondary-button" type="button" onClick={() => void download(object)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>
                    <button className="danger-button" type="button" onClick={() => void removeObject(object)} disabled={!accessKey || deletingKey === object.key}><Trash2 className="button-icon" aria-hidden="true" />{deletingKey === object.key ? '删除中...' : '删除'}</button>
                  </td>
                </tr>
              ))}</tbody>
          </table> : <table className="object-table version-table">
            <thead><tr><th>Object</th><th>Version ID</th><th>State</th><th>Size</th><th>Last Modified</th><th>Actions</th></tr></thead>
            <tbody>{versions.map((version) => {
              const identity = `${version.key}\u0000${version.version_id}`
              return <tr key={identity} className={version.is_delete_marker ? 'delete-marker-row' : ''}>
                <td className="object-key"><div className="file-cell">{version.is_delete_marker ? <Trash2 className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{version.key}</span></div></td>
                <td><code className="version-id" title={version.version_id}>{shortVersionId(version.version_id)}</code></td>
                <td><div className="version-badges">{version.is_latest && <span className="status-badge latest">Latest</span>}{version.is_delete_marker && <span className="status-badge delete-marker">DeleteMarker</span>}{!version.is_latest && !version.is_delete_marker && <span className="status-badge">Previous</span>}</div></td>
                <td>{version.is_delete_marker ? '-' : formatBytes(version.size)}</td>
                <td>{new Date(version.last_modified).toLocaleString()}</td>
                <td className="table-actions">
                  {!version.is_delete_marker && <button className="secondary-button" type="button" onClick={() => void downloadVersion(version)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>}
                  <button className="danger-button" type="button" onClick={() => void removeVersion(version)} disabled={!accessKey || deletingVersion === identity}><Trash2 className="button-icon" aria-hidden="true" />{deletingVersion === identity ? '删除中...' : '永久删除'}</button>
                </td>
              </tr>
            })}</tbody>
          </table>}
        </div>
        {viewMode === 'current' && objects.length === 0 && !loading && <div className="empty-state empty-panel"><strong>这个 Bucket 还是空的</strong><span>上传文件后，对象会显示在这里。</span></div>}
        {viewMode === 'versions' && versions.length === 0 && !loading && <div className="empty-state empty-panel"><strong>没有对象版本</strong><span>启用 Versioning 后，新写入和删除会记录在这里。</span></div>}
        {loading && <p className="loading-state">正在加载{viewMode === 'current' ? '对象' : '版本'}...</p>}
      </section>
      {viewMode === 'current' && nextToken && <button className="load-more" type="button" onClick={() => void load(false)}>加载更多</button>}

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

function abortError() {
  const error = new Error('上传已暂停')
  error.name = 'AbortError'
  return error
}

function isMultipartUploadMissing(reason: unknown) {
  return reason instanceof ApiError && reason.status === 404 && reason.body.code === 'UploadNotFound'
}

function delay(milliseconds: number) {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds))
}

function fileExtension(key: string) {
  const name = key.split('/').pop() || key
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toUpperCase().slice(0, 8) : 'FILE'
}

function shortVersionId(versionId: string) {
  return versionId === 'null' ? 'null' : `${versionId.slice(0, 8)}...${versionId.slice(-6)}`
}

function isImageKey(key: string) {
  return /\.(avif|bmp|gif|jpe?g|png|svg|webp)$/i.test(key)
}
