import { type ChangeEvent, type FormEvent, useEffect, useRef, useState } from 'react'
import {
  ArrowLeft,
  Archive,
  CheckCircle2,
  Copy,
  Download,
  ExternalLink,
  File,
  Folder,
  FolderOpen,
  FolderInput,
  FolderPlus,
  History,
  List,
  Pause,
  PanelRight,
  Play,
  RefreshCw,
  RotateCcw,
  Search,
  Trash2,
  Undo2,
  Upload,
  X,
} from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { ActionMenu } from '../../components/ActionMenu'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useToast } from '../../components/ToastProvider'
import type { AccessKey, Bucket, MultipartUpload, MultipartUploadSummary, ObjectSummary, ObjectVersion, PresignObjectResponse } from '../../types/api'
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
  initialPrefix?: string
  onNavigatePath: (prefix: string) => void
  onBack: () => void
}

interface UploadProgress {
  loaded: number
  total: number
  percent: number
}

interface CompletedUpload {
  uploadId: string
  key: string
  fileName: string
  fileSize: number
  completedAt: string
}

type SelectedObject = {
  kind: 'current'
  object: ObjectSummary
} | {
  kind: 'version'
  version: ObjectVersion
}

interface TransferDialogState {
  mode: 'copy' | 'move'
  items: SelectedObject[]
}

export function ObjectsView({ api, initialBucket = '', initialPrefix = '', onNavigatePath, onBack }: ObjectsViewProps) {
  const confirm = useConfirm()
  const { startLoading, withLoading } = useLoading()
  const [accessKeys, setAccessKeys] = useState<AccessKey[]>([])
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [bucketInfo, setBucketInfo] = useState<Bucket | null>(null)
  const bucket = initialBucket
  const [accessKey, setAccessKey] = useState('')
  const [prefix, setPrefix] = useState(initialPrefix)
  const [searchInput, setSearchInput] = useState('')
  const [searchQuery, setSearchQuery] = useState('')
  const [viewMode, setViewMode] = useState<'current' | 'versions'>('current')
  const [showDeleted, setShowDeleted] = useState(false)
  const [showDeletedVersions, setShowDeletedVersions] = useState(false)
  const [objects, setObjects] = useState<ObjectSummary[]>([])
  const [deletedObjects, setDeletedObjects] = useState<ObjectVersion[]>([])
  const [deletedObjectSizes, setDeletedObjectSizes] = useState<Map<string, number>>(new Map())
  const [versions, setVersions] = useState<ObjectVersion[]>([])
  const [nextToken, setNextToken] = useState('')
  const [error, setError] = useState('')
  const showToast = useToast()
  const [loading, setLoading] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState<UploadProgress | null>(null)
  const [uploadTasks, setUploadTasks] = useState<UploadTask[]>([])
  const [completedUploads, setCompletedUploads] = useState<CompletedUpload[]>([])
  const [uploadsLoading, setUploadsLoading] = useState(false)
  const [uploadsPanelOpen, setUploadsPanelOpen] = useState(false)
  const [showCreatePath, setShowCreatePath] = useState(false)
  const [pathName, setPathName] = useState('')
  const [pathError, setPathError] = useState('')
  const [deletingKey, setDeletingKey] = useState('')
  const [deletingVersion, setDeletingVersion] = useState('')
  const [restoringVersion, setRestoringVersion] = useState('')
  const [selectedObjectKeys, setSelectedObjectKeys] = useState<Set<string>>(new Set())
  const [selectedDeletedIds, setSelectedDeletedIds] = useState<Set<string>>(new Set())
  const [selectedVersionIds, setSelectedVersionIds] = useState<Set<string>>(new Set())
  const [transferDialog, setTransferDialog] = useState<TransferDialogState | null>(null)
  const [transferBucket, setTransferBucket] = useState(bucket)
  const [transferPath, setTransferPath] = useState('')
  const [transferError, setTransferError] = useState('')
  const [transferring, setTransferring] = useState(false)
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailUrl, setDetailUrl] = useState<PresignObjectResponse | null>(null)
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
  const routeLocation = useRef({ bucket: initialBucket, prefix: initialPrefix })
  const accessKeysLoaded = useRef(false)
  const bucketInfoLoaded = useRef('')
  const multipartSyncBucket = useRef('')
  const initialLoadKey = useRef('')
  const listRequestId = useRef(0)
  const listLoading = useRef(false)
  const loadMoreSentinel = useRef<HTMLDivElement>(null)
  const visibleVersions = showDeletedVersions
    ? versions.filter((version) => !isDirectoryKey(version.key) && version.is_delete_marker && version.is_latest)
    : versions.filter((version) => !isDirectoryKey(version.key) && !version.is_delete_marker)
  const normalizedSearchQuery = searchQuery.trim().toLocaleLowerCase()
  const filteredObjects = normalizedSearchQuery
    ? objects.filter((object) => object.key.toLocaleLowerCase().includes(normalizedSearchQuery))
    : objects
  const filteredDeletedObjects = normalizedSearchQuery
    ? deletedObjects.filter((version) => version.key.toLocaleLowerCase().includes(normalizedSearchQuery))
    : deletedObjects
  const filteredVersions = normalizedSearchQuery
    ? visibleVersions.filter((version) => version.key.toLocaleLowerCase().includes(normalizedSearchQuery))
    : visibleVersions

  useEffect(() => {
    if (accessKeysLoaded.current) return
    accessKeysLoaded.current = true
    withLoading('正在加载 Access Keys...', () => api.listAccessKeys())
      .then((keyItems) => {
        const enabledKeys = keyItems.filter((item) => item.enabled)
        setAccessKeys(enabledKeys)
        setAccessKey((current) => current || enabledKeys[0]?.access_key || '')
      })
      .catch((reason: Error) => {
        accessKeysLoaded.current = false
        setError(reason.message)
      })
  }, [api, withLoading])

  useEffect(() => {
    if (!bucket || bucketInfoLoaded.current === bucket) return
    bucketInfoLoaded.current = bucket
    withLoading('正在加载 Bucket 信息...', () => api.listBuckets())
      .then((items) => {
        setBuckets(items)
        setBucketInfo(items.find((item) => item.name === bucket) ?? null)
      })
      .catch((reason: Error) => {
        if (bucketInfoLoaded.current === bucket) bucketInfoLoaded.current = ''
        setError(reason.message)
      })
  }, [api, bucket, withLoading])

  async function load(reset: boolean, requestedPrefix = prefix) {
    if (!bucket) return
    if (!reset && (listLoading.current || !nextToken || viewMode !== 'current' || showDeleted)) return
    const requestId = ++listRequestId.current
    listLoading.current = true
    const stopLoading = startLoading(`正在加载${viewMode === 'versions' ? '对象版本' : '对象'}...`)
    try {
      if (reset) {
        setSelectedObjectKeys(new Set())
        setSelectedDeletedIds(new Set())
        setSelectedVersionIds(new Set())
      }
      setLoading(true)
      setError('')
      const currentPrefix = requestedPrefix.trim()
      if (viewMode === 'versions') {
        const loadedVersions = await api.listObjectVersions(bucket, currentPrefix)
        if (requestId !== listRequestId.current) return
        setVersions(sortObjectVersions(hideCurrentDirectoryMarker(loadedVersions, currentPrefix)))
        setDeletedObjects([])
        setDeletedObjectSizes(new Map())
        setNextToken('')
      } else if (showDeleted) {
        const history = await api.listObjectVersions(bucket, currentPrefix)
        if (requestId !== listRequestId.current) return
        setObjects([])
        setNextToken('')
        const visibleHistory = hideCurrentDirectoryMarker(history, currentPrefix)
        const objectSizes = latestObjectSizes(visibleHistory)
        setDeletedObjectSizes(objectSizes)
        setDeletedObjects(sortObjectVersions(visibleHistory.filter((item) => !isDirectoryKey(item.key) && item.is_delete_marker && item.is_latest)))
      } else {
        const search = searchQuery.trim()
        const result = await api.listObjects(bucket, search ? '' : currentPrefix, reset ? '' : nextToken, search, 10, search ? '' : '/')
        if (requestId !== listRequestId.current) return
        const directoryItems = (result.directories ?? []).map((directory) => directorySummary(directory.key, directory.last_modified))
        const visibleItems = hideCurrentDirectoryMarker([...result.items, ...directoryItems], currentPrefix)
        setObjects((current) => sortObjectSummaries(reset ? visibleItems : [...current, ...visibleItems]))
        setNextToken(result.is_truncated ? (result.continuation_token ?? '') : '')
        setDeletedObjects([])
        setDeletedObjectSizes(new Map())
      }
    } catch (reason) {
      if (requestId === listRequestId.current) setError((reason as Error).message)
    } finally {
      if (requestId === listRequestId.current) {
        setLoading(false)
        listLoading.current = false
      }
      stopLoading()
    }
  }

  useEffect(() => {
    const routeChanged = routeLocation.current.bucket !== bucket || routeLocation.current.prefix !== initialPrefix
    if (routeChanged) {
      routeLocation.current = { bucket, prefix: initialPrefix }
      setPrefix(initialPrefix)
      setSearchInput('')
      if (searchQuery) {
        setSearchQuery('')
        initialLoadKey.current = ''
        return
      }
      initialLoadKey.current = ''
    }
    const loadKey = `${bucket}\u0000${initialPrefix}\u0000${viewMode}\u0000${showDeleted}\u0000${showDeletedVersions}\u0000${searchQuery.trim()}`
    if (initialLoadKey.current === loadKey) return
    initialLoadKey.current = loadKey
    if (!bucket) return
    void load(true, routeChanged ? initialPrefix : prefix)
  }, [bucket, initialPrefix, viewMode, showDeleted, showDeletedVersions, searchQuery])

  useEffect(() => {
    const sentinel = loadMoreSentinel.current
    if (!sentinel || viewMode !== 'current' || showDeleted || !nextToken) return
    const handleScroll = () => {
      if (sentinel.getBoundingClientRect().top <= window.innerHeight + 240 && !loading && !listLoading.current) {
        void load(false)
      }
    }
    window.addEventListener('scroll', handleScroll, { passive: true })
    return () => window.removeEventListener('scroll', handleScroll)
  }, [nextToken, loading, viewMode, showDeleted, searchQuery, prefix])

  useEffect(() => {
    setSelectedObjectKeys(new Set())
    setSelectedDeletedIds(new Set())
    setSelectedVersionIds(new Set())
  }, [searchQuery])

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
    if (!bucket || multipartSyncBucket.current === bucket) return
    multipartSyncBucket.current = bucket
    void loadMultipartUploads()
  }, [bucket])

  function selectFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = [...(event.target.files ?? [])]
    event.target.value = ''
    if (selected.length > 0) void beginUploads(selected)
  }

  function openRewind() {
    setSelectedObjectKeys(new Set())
    setSelectedDeletedIds(new Set())
    setSelectedVersionIds(new Set())
    setShowDeleted(false)
    setShowDeletedVersions(false)
    if (viewMode === 'versions') {
      setViewMode('current')
      return
    }
    setViewMode('versions')
  }

  function toggleObjectSelection(key: string, checked: boolean) {
    setSelectedObjectKeys((current) => {
      const next = new Set(current)
      if (checked) next.add(key)
      else next.delete(key)
      return next
    })
  }

  function toggleDeletedSelection(version: ObjectVersion, checked: boolean) {
    const identity = versionIdentity(version)
    setSelectedDeletedIds((current) => {
      const next = new Set(current)
      if (checked) next.add(identity)
      else next.delete(identity)
      return next
    })
  }

  function toggleVersionSelection(version: ObjectVersion, checked: boolean) {
    const identity = versionIdentity(version)
    setSelectedVersionIds((current) => {
      const next = new Set(current)
      if (checked) next.add(identity)
      else next.delete(identity)
      return next
    })
  }

  function toggleAllCurrent(checked: boolean) {
    if (showDeleted) {
      setSelectedDeletedIds(checked ? new Set(filteredDeletedObjects.map(versionIdentity)) : new Set())
      return
    }
    setSelectedObjectKeys(checked ? new Set(filteredObjects.map((object) => object.key)) : new Set())
  }

  function toggleAllVersions(checked: boolean) {
    setSelectedVersionIds(checked
      ? new Set(filteredVersions.map(versionIdentity))
      : new Set())
  }

  function selectedItems(): SelectedObject[] {
    if (viewMode === 'versions') {
      return filteredVersions
        .filter((version) => selectedVersionIds.has(versionIdentity(version)))
        .map((version) => ({ kind: 'version' as const, version }))
    }
    if (showDeleted) {
      return filteredDeletedObjects
        .filter((version) => selectedDeletedIds.has(versionIdentity(version)))
        .map((version) => ({ kind: 'version' as const, version }))
    }
    return filteredObjects
      .filter((object) => selectedObjectKeys.has(object.key))
      .map((object) => ({ kind: 'current' as const, object }))
  }

  function openTransfer(mode: 'copy' | 'move', item?: SelectedObject) {
    const items = (item ? [item] : selectedItems())
      .filter((selected) => selected.kind === 'current' || !selected.version.is_delete_marker)
      .filter((selected) => mode === 'move' || !isDirectoryKey(selected.kind === 'current' ? selected.object.key : selected.version.key))
    if (items.length === 0) return
    setTransferBucket(bucket)
    setTransferPath(prefix.trim())
    setTransferError('')
    setTransferDialog({ mode, items })
  }

  function goToParentPath() {
    const parent = parentObjectPath(prefix)
    if (parent === prefix.trim()) return
    setPrefix(parent)
    onNavigatePath(parent)
  }

  function enterDirectory(key: string) {
    const directory = key.endsWith('/') ? key : `${key}/`
    setPrefix(directory)
    onNavigatePath(directory)
  }

  function openObject(object: ObjectSummary) {
    if (isDirectoryKey(object.key)) {
      enterDirectory(object.key)
      return
    }
    void openDetail(object)
  }

  async function copyCurrentPath() {
    if (!bucket) return
    const path = displayObjectPath(prefix)
    try {
      await navigator.clipboard.writeText(path ? `${bucket}/${path}` : bucket)
      showToast('当前路径已复制')
    } catch (reason) {
      setError((reason as Error).message)
    }
  }

  async function loadMultipartUploads() {
    if (!bucket) return
    const stopLoading = startLoading('正在同步分片上传任务...')
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
      stopLoading()
    }
  }

  async function beginUploads(files: File[]) {
    if (!bucket || !accessKey || files.length === 0) return
    setError('')
    setUploadsPanelOpen(true)
    const tasks: UploadTask[] = []
    const failures: string[] = []
    for (const file of files) {
      const key = joinObjectPath(prefix, file.name)
      try {
        const created = await api.createMultipartUpload(bucket, key, file.type || 'application/octet-stream')
        tasks.push({
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
        })
      } catch (reason) {
        failures.push(`${file.name}: ${(reason as Error).message}`)
      }
    }
    if (tasks.length > 0) setUploadTasks((current) => [...tasks, ...current])
    if (failures.length > 0) setError(`以下文件未能创建上传任务：${failures.join('；')}`)
    for (const task of tasks) {
      if (task.file) await runUpload(task, task.file)
    }
  }

  async function createPath(event: FormEvent) {
    event.preventDefault()
    const name = pathName.trim().replace(/^\/+|\/+$/g, '')
    if (!name || !bucket || !accessKey) return
    if (name.includes('/')) {
      setPathError('目录名称只能创建一级目录，不能包含“/”。')
      return
    }
    const key = `${joinObjectPath(prefix, name)}/`
    const stopLoading = startLoading('正在创建路径...')
    try {
      setPathError('')
      await api.createDirectory(bucket, key)
      setShowCreatePath(false)
      setPathName('')
      showToast(`已创建路径 ${displayDirectoryKey(key)}`)
      setPrefix(key)
      onNavigatePath(key)
    } catch (reason) {
      setPathError((reason as Error).message)
    } finally {
      stopLoading()
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
      setCompletedUploads((current) => [
        {
          uploadId: task.uploadId,
          key: task.key,
          fileName: task.fileName,
          fileSize: selectedFile.size,
          completedAt: new Date().toISOString(),
        },
        ...current,
      ].slice(0, 20))
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      showToast(`已上传 ${displayFileName(task.key)}`)
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
        showToast(`已暂停 ${displayFileName(task.key)}`)
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
    if (!await confirm({
      title: '取消分片上传',
      message: `取消上传“${task.key}”并删除已上传的分片？`,
      confirmLabel: '取消上传',
      danger: true,
    })) return
    const control = uploadControl.current
    if (control?.uploadId === task.uploadId && control.completing) {
      showToast(`正在完成 ${displayFileName(task.key)}`)
      return
    }
    if (control?.uploadId === task.uploadId) {
      control.paused = true
      control.cancelled = true
      control.request?.abort()
    }
    const stopLoading = startLoading('正在取消分片上传...')
    try {
      await api.abortMultipartUpload(task.uploadId, task.bucket, task.key)
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      showToast(`已取消 ${displayFileName(task.key)}`)
    } catch (reason) {
      const message = (reason as Error).message
      updateUploadTask(task.uploadId, { status: 'failed', error: message })
      setError(message)
    } finally {
      stopLoading()
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
      continuationToken = result.is_truncated ? (result.continuation_token ?? '') : ''
    } while (continuationToken)
    return false
  }

  async function download(object: ObjectSummary) {
    if (!accessKey || !bucket) return false
    const stopLoading = startLoading('正在下载对象...')
    try {
      setError('')
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
      showToast(`已下载 ${displayFileName(object.key)}`)
      return true
    } catch (reason) {
      setError((reason as Error).message)
      return false
    } finally {
      stopLoading()
    }
  }

  async function downloadVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker) return false
    const stopLoading = startLoading('正在下载对象版本...')
    try {
      setError('')
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
      showToast(`已下载 ${displayFileName(version.key)} 的版本 ${shortVersionId(version.version_id)}`)
      return true
    } catch (reason) {
      setError((reason as Error).message)
      return false
    } finally {
      stopLoading()
    }
  }

  async function listAllObjectsForPrefix(objectPrefix: string) {
    if (!bucket) return []
    let continuationToken = ''
    const items: ObjectSummary[] = []
    do {
      const page = await api.listObjects(bucket, objectPrefix, continuationToken)
      items.push(...page.items)
      const nextToken = page.is_truncated ? (page.continuation_token ?? '') : ''
      if (!nextToken || nextToken === continuationToken) break
      continuationToken = nextToken
    } while (continuationToken)
    return items
  }

  async function copyObjectKey(sourceKey: string, destinationBucket: string, destinationKey: string, versionId?: string) {
    if (!accessKey || !bucket) return
    if (destinationBucket === bucket && destinationKey === sourceKey) {
      throw new Error(`目标路径与源对象相同：${displayKeyForMessage(sourceKey)}`)
    }
    const presigned = await api.presignObject(accessKey, destinationBucket, destinationKey, 'PUT', 900, {
      copySource: { bucket, key: sourceKey, ...(versionId ? { versionId } : {}) },
    })
    const response = await fetch(presigned.url, {
      method: 'PUT',
      headers: presigned.required_headers,
    })
    if (!response.ok) throw new Error(`复制 ${displayKeyForMessage(sourceKey)} 失败（${response.status}）`)
  }

  async function deleteObjectKey(key: string, versionId?: string) {
    if (!accessKey || !bucket) return
    const presigned = await api.presignObject(accessKey, bucket, key, 'DELETE', 900, versionId ? { versionId } : undefined)
    const response = await fetch(presigned.url, { method: 'DELETE' })
    if (!response.ok) throw new Error(`删除 ${key} 失败（${response.status}）`)
  }

  async function copyDirectory(sourceKey: string, destinationBucket: string, destinationPath: string) {
    const sourcePrefix = sourceKey.endsWith('/') ? sourceKey : `${sourceKey}/`
    const directoryName = sourcePrefix.slice(0, -1).split('/').pop()
    if (!directoryName) throw new Error(`无法确定目录名称：${displayDirectoryKey(sourceKey)}`)
    const destinationPrefix = `${joinObjectPath(destinationPath, directoryName)}/`
    if (destinationBucket === bucket && (destinationPrefix === sourcePrefix || destinationPrefix.startsWith(sourcePrefix))) {
      throw new Error(`目标路径不能位于源目录内：${displayDirectoryKey(sourcePrefix)}`)
    }
    const listed = await listAllObjectsForPrefix(sourcePrefix)
    const sourceKeys = [...new Set(listed.map((object) => object.key).filter((key) => key.startsWith(sourcePrefix)))]
    if (!sourceKeys.includes(sourcePrefix)) sourceKeys.unshift(sourcePrefix)
    for (const key of sourceKeys) {
      await copyObjectKey(key, destinationBucket, `${destinationPrefix}${key.slice(sourcePrefix.length)}`)
    }
  }

  async function deleteDirectory(sourceKey: string) {
    const sourcePrefix = sourceKey.endsWith('/') ? sourceKey : `${sourceKey}/`
    const listed = await listAllObjectsForPrefix(sourcePrefix)
    const sourceKeys = [...new Set(listed.map((object) => object.key).filter((key) => key.startsWith(sourcePrefix)))]
    sourceKeys.sort((left, right) => right.length - left.length)
    for (const key of sourceKeys) await deleteObjectKey(key)
    await api.deleteDirectory(bucket, sourcePrefix)
  }

  async function copyItem(item: SelectedObject, destinationBucket: string, destinationPath: string) {
    const sourceKey = item.kind === 'current' ? item.object.key : item.version.key
    if (item.kind === 'current' && isDirectoryKey(sourceKey)) {
      await copyDirectory(sourceKey, destinationBucket, destinationPath)
      return
    }
    const fileName = sourceKey.split('/').pop() || sourceKey
    const destinationKey = joinObjectPath(destinationPath, fileName)
    await copyObjectKey(sourceKey, destinationBucket, destinationKey, item.kind === 'version' ? item.version.version_id : undefined)
  }

  async function ensureDirectoryCanBeDeleted(key: string) {
    if (!isDirectoryKey(key)) return true
    if (!bucket) return false

    const stopLoading = startLoading('正在检查目录...')
    let hasChildren = false
    try {
      setError('')
      const [page, versions] = await Promise.all([
        api.listObjects(bucket, key, '', '', 1, '/'),
        api.listObjectVersions(bucket, key),
      ])
      hasChildren = page.items.some((item) => item.key !== key) ||
        (page.common_prefixes ?? []).some((prefixKey) => prefixKey !== key) ||
        (page.directories ?? []).some((directory) => directory.key !== key) ||
        versions.some((version) => version.key !== key && version.key.startsWith(key))
    } catch (reason) {
      setError((reason as Error).message)
      return false
    } finally {
      stopLoading()
    }

    if (!hasChildren) return true
    await confirm({
      title: '删除目录',
      message: `删除目录“${displayDirectoryKey(key)}”？目录必须为空，目录下的对象不会被删除。`,
      cancelLabel: '知道了',
      danger: true,
      hideConfirm: true,
    })
    return false
  }

  async function deleteItem(item: SelectedObject) {
    if (!accessKey || !bucket) return
    if (item.kind === 'current') {
      if (isDirectoryKey(item.object.key)) {
        await api.deleteDirectory(bucket, item.object.key)
        return
      }
      const presigned = await api.presignObject(accessKey, bucket, item.object.key, 'DELETE', 900)
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`删除 ${displayKeyForMessage(item.object.key)} 失败（${response.status}）`)
      return
    }
    const presigned = await api.presignObject(accessKey, bucket, item.version.key, 'DELETE', 900, { versionId: item.version.version_id })
    const response = await fetch(presigned.url, { method: 'DELETE' })
    if (!response.ok) throw new Error(`删除版本 ${shortVersionId(item.version.version_id)} 失败（${response.status}）`)
  }

  async function purgeObject(key: string) {
    if (!accessKey || !bucket) return
    const history = await api.listObjectVersions(bucket, key)
    const exactVersions = history
      .filter((version) => version.key === key)
      .sort((left, right) => Number(left.is_delete_marker) - Number(right.is_delete_marker))
    for (const version of exactVersions) {
      await deleteItem({ kind: 'version', version })
    }
  }

  async function removeDeletedObject(version: ObjectVersion) {
    if (!accessKey || !bucket || !version.is_delete_marker) return
    if (!await ensureDirectoryCanBeDeleted(version.key)) return
    if (!await confirm({
      title: '永久删除对象',
      message: `永久删除对象“${version.key}”？该对象的全部版本和 DeleteMarker 都会被清除，且无法恢复。`,
      confirmLabel: '永久删除',
      danger: true,
    })) return
    const identity = versionIdentity(version)
    const stopLoading = startLoading('正在永久删除对象...')
    try {
      setDeletingVersion(identity)
      setError('')
      await purgeObject(version.key)
      showToast(`已永久删除 ${displayFileName(version.key)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeletingVersion('')
      stopLoading()
    }
  }

  async function downloadSelected() {
    const items = selectedItems().filter((item) => {
      if (item.kind === 'current') return !isDirectoryKey(item.object.key)
      return !item.version.is_delete_marker && !isDirectoryKey(item.version.key)
    })
    if (items.length === 0) return
    let failed = false
    for (const item of items) {
      const completed = item.kind === 'current' ? await download(item.object) : await downloadVersion(item.version)
      if (!completed) failed = true
    }
    if (!failed) {
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
    } else {
      setError('部分对象下载失败，请重试。')
    }
  }

  async function removeSelected() {
    const items = selectedItems()
    if (items.length === 0) return
    for (const item of items) {
      const key = item.kind === 'current' ? item.object.key : item.version.key
      if (!await ensureDirectoryCanBeDeleted(key)) return
    }
    const deleteMarkers = items.filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker)
    const purgingDeletedObjects = deleteMarkers.length === items.length
    const permanent = viewMode === 'versions' || items.some((item) => item.kind === 'version')
    const label = permanent ? '永久删除选中的对象版本' : '删除选中的对象'
    if (!await confirm({
      title: purgingDeletedObjects ? '永久删除对象' : label,
      message: purgingDeletedObjects
        ? `确定永久删除 ${new Set(deleteMarkers.map((item) => item.version.key)).size} 个对象？对象的全部版本和 DeleteMarker 都会被清除，且无法恢复。`
        : permanent
        ? `确定永久删除 ${items.length} 个对象版本？此操作无法恢复。`
        : `确定删除 ${items.length} 个对象？启用版本管理时会创建 DeleteMarker。`,
      confirmLabel: permanent ? '永久删除' : '删除',
      danger: true,
    })) return
    const stopLoading = startLoading(permanent ? '正在永久删除对象版本...' : '正在删除对象...')
    try {
      setError('')
      if (purgingDeletedObjects) {
        for (const key of new Set(deleteMarkers.map((item) => item.version.key))) await purgeObject(key)
      } else {
        for (const item of items) await deleteItem(item)
      }
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
      showToast(`已处理 ${items.length} 个对象`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function restoreSelected() {
    const items = selectedItems().filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker && item.version.is_latest)
    if (items.length === 0) return
    if (!await confirm({
      title: '恢复已删除对象',
      message: `确定恢复 ${items.length} 个已删除对象？将删除对应的最新 DeleteMarker。`,
      confirmLabel: '恢复对象',
    })) return
    const stopLoading = startLoading('正在恢复对象...')
    try {
      setError('')
      for (const item of items) await deleteItem(item)
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
      showToast(`已恢复 ${items.length} 个对象`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function submitTransfer(event: FormEvent) {
    event.preventDefault()
    if (!transferDialog || !transferBucket || transferring) return
    const destinationPath = transferPath.trim().replace(/^\/+|\/+$/g, '')
    const { mode, items } = transferDialog
    setTransferring(true)
    setTransferError('')
    const stopLoading = startLoading(mode === 'copy' ? '正在复制对象...' : '正在移动对象...')
    try {
      setError('')
      for (const item of items) await copyItem(item, transferBucket, destinationPath)
      if (mode === 'move') {
        for (const item of items) {
          if (item.kind === 'current' && isDirectoryKey(item.object.key)) await deleteDirectory(item.object.key)
          else await deleteItem(item)
        }
      }
      setTransferDialog(null)
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
      showToast(`${mode === 'copy' ? '已复制' : '已移动'} ${items.length} 个对象`)
      await load(true)
    } catch (reason) {
      setTransferError((reason as Error).message)
    } finally {
      setTransferring(false)
      stopLoading()
    }
  }

  async function openDetail(object: ObjectSummary) {
    setDetail(object)
    setDetailUrl(null)
    setDetailError('')
    if (!accessKey || !bucket) return
    const stopLoading = startLoading('正在生成预览链接...')
    try {
      setDetailUrl(await api.presignObject(accessKey, bucket, object.key, 'GET', 900))
    } catch (reason) {
      setDetailError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  function closeDetail() {
    setDetail(null)
    setDetailUrl(null)
    setDetailError('')
  }

  async function removeDirectory(object: ObjectSummary) {
    if (!accessKey || !bucket || !isDirectoryKey(object.key)) return
    if (!await ensureDirectoryCanBeDeleted(object.key)) return
    if (!await confirm({
      title: '删除目录',
      message: `删除目录“${displayDirectoryKey(object.key)}”？目录必须为空，目录下的对象不会被删除。`,
      confirmLabel: '删除目录',
      danger: true,
    })) return
    const stopLoading = startLoading('正在删除目录...')
    try {
      setDeletingKey(object.key)
      setError('')
      await api.deleteDirectory(bucket, object.key)
      showToast(`已删除目录 ${displayDirectoryKey(object.key)}`)
      await load(true)
    } catch (reason) {
      if (reason instanceof ApiError && reason.body.code === 'DirectoryNotEmpty') {
        stopLoading()
        await confirm({
          title: '无法删除目录',
          message: `目录“${displayDirectoryKey(object.key)}”必须为空才能删除。请先删除目录下的所有对象和子目录。`,
          cancelLabel: '知道了',
          hideConfirm: true,
        })
      } else {
        setError((reason as Error).message)
      }
    } finally {
      setDeletingKey('')
      stopLoading()
    }
  }

  async function removeObject(object: ObjectSummary) {
    if (!accessKey || !bucket) return
    if (isDirectoryKey(object.key)) {
      await removeDirectory(object)
      return
    }
    if (!await ensureDirectoryCanBeDeleted(object.key)) return
    if (!await confirm({
      title: '删除对象',
      message: `删除对象“${object.key}”？如果 Bucket 启用了版本管理，ZigFS 会创建 DeleteMarker。`,
      confirmLabel: '删除',
      danger: true,
    })) return
    const stopLoading = startLoading('正在删除对象...')
    try {
      setDeletingKey(object.key)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, object.key, 'DELETE', 900)
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`删除失败（${response.status}）`)
      if (detail?.key === object.key) closeDetail()
      showToast(`已删除 ${displayFileName(object.key)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeletingKey('')
      stopLoading()
    }
  }

  async function removeVersion(version: ObjectVersion) {
    const target = version.is_delete_marker ? 'DeleteMarker' : '对象版本'
    if (!accessKey || !bucket) return
    if (!await ensureDirectoryCanBeDeleted(version.key)) return
    if (!await confirm({
      title: '永久删除版本',
      message: `永久删除“${version.key}”的${target} ${shortVersionId(version.version_id)}？此操作不会创建新的 DeleteMarker，且无法恢复。`,
      confirmLabel: '永久删除',
      danger: true,
    })) return
    const stopLoading = startLoading('正在永久删除对象版本...')
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setDeletingVersion(identity)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`删除版本失败（${response.status}）`)
      showToast(`已永久删除 ${displayFileName(version.key)} 的${target} ${shortVersionId(version.version_id)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeletingVersion('')
      stopLoading()
    }
  }

  async function restoreDeletedObject(version: ObjectVersion) {
    if (!accessKey || !bucket || !version.is_delete_marker || !version.is_latest) return
    if (!await confirm({
      title: '恢复已删除对象',
      message: `删除最新 DeleteMarker 并恢复对象“${version.key}”？`,
      confirmLabel: '恢复对象',
    })) return
    const stopLoading = startLoading('正在恢复对象...')
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(`恢复对象失败（${response.status}）`)
      showToast(`已恢复 ${displayFileName(version.key)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRestoringVersion('')
      stopLoading()
    }
  }

  async function rewindVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker || version.is_latest) return
    if (!await confirm({
      title: '回溯对象版本',
      message: `将“${version.key}”回溯到版本 ${shortVersionId(version.version_id)}？ZigFS 会创建一个新的当前版本。`,
      confirmLabel: '回溯版本',
    })) return
    const stopLoading = startLoading('正在回溯对象版本...')
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'PUT', 900, {
        copySource: { bucket, key: version.key, versionId: version.version_id },
      })
      const response = await fetch(presigned.url, {
        method: 'PUT',
        headers: presigned.required_headers,
      })
      if (!response.ok) throw new Error(`回溯版本失败（${response.status}）`)
      showToast(`已将 ${displayFileName(version.key)} 回溯到版本 ${shortVersionId(version.version_id)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRestoringVersion('')
      stopLoading()
    }
  }

  async function restoreVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker || version.is_latest) return
    const deleted = versions.some((item) => item.key === version.key && item.is_delete_marker && item.is_latest)
    if (!deleted) return
    if (!await confirm({
      title: '恢复对象版本',
      message: `将“${version.key}”恢复为版本 ${shortVersionId(version.version_id)}？该版本会成为新的当前版本，对象将恢复可见。`,
      confirmLabel: '恢复',
    })) return
    const stopLoading = startLoading('正在恢复对象版本...')
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      setError('')
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'PUT', 900, {
        copySource: { bucket, key: version.key, versionId: version.version_id },
      })
      const response = await fetch(presigned.url, {
        method: 'PUT',
        headers: presigned.required_headers,
      })
      if (!response.ok) throw new Error(`恢复对象版本失败（${response.status}）`)
      showToast(`已恢复 ${displayFileName(version.key)}，当前版本为 ${shortVersionId(version.version_id)}`)
      await load(true)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setRestoringVersion('')
      stopLoading()
    }
  }

  async function copyDetailUrl() {
    if (!detailUrl) return
    await navigator.clipboard.writeText(detailUrl.url)
    showToast('预览链接已复制')
  }

  const visibleObjectCount = viewMode === 'current' ? (showDeleted ? filteredDeletedObjects.length : filteredObjects.length) : filteredVersions.length
  const selected = selectedItems()
  const selectedDeleted = selected.filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker)
  const selectedData = selected.filter((item) => item.kind === 'current' || !item.version.is_delete_marker)
  const selectedFiles = selectedData.filter((item) => !isDirectoryKey(item.kind === 'current' ? item.object.key : item.version.key))
  const selectedCount = selected.length
  const selectableCurrentCount = showDeleted ? filteredDeletedObjects.length : filteredObjects.length
  const selectableVersionCount = filteredVersions.length
  const allCurrentSelected = selectableCurrentCount > 0 && (showDeleted
    ? filteredDeletedObjects.every((version) => selectedDeletedIds.has(versionIdentity(version)))
    : filteredObjects.every((object) => selectedObjectKeys.has(object.key)))
  const allVersionsSelected = selectableVersionCount > 0 && filteredVersions.every((version) => selectedVersionIds.has(versionIdentity(version)))
  const hasDeleteMarkerSelection = selectedDeleted.length > 0
  const permanentDeleteOnly = viewMode === 'versions' || hasDeleteMarkerSelection
  const deletedObjectKeys = new Set(
    versions.filter((version) => version.is_delete_marker && version.is_latest).map((version) => version.key),
  )
  const deletedVersionSizes = latestObjectSizes(versions)
  const TransferIcon = transferDialog?.mode === 'copy' ? Copy : FolderInput
  const activeShowDeleted = viewMode === 'versions' ? showDeletedVersions : showDeleted

  return (
    <section>
      <header className="page-header">
        <div>
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />返回 Bucket</button>
          <h2>Object Browser</h2>
          <p className="page-description">浏览、上传、下载和管理 Bucket 中的对象。</p>
        </div>
        <span className="count-badge">{viewMode === 'current' ? `${visibleObjectCount}${!showDeleted && nextToken ? '+' : ''} 个对象` : `${visibleObjectCount} 条版本记录`}</span>
      </header>

      <div className="page-toolbar">
        <div className="toolbar-leading object-toolbar-leading">
          <div className="object-bucket-summary">
            <span className="object-bucket-summary-icon" aria-hidden="true"><Archive /></span>
            <div className="object-bucket-summary-copy">
              <strong>{bucketInfo?.name ?? (bucket || '未选择 Bucket')}</strong>
              <span>Created on: {bucketInfo ? new Date(bucketInfo.created_at).toLocaleString() : '-'}</span>
              <span>Access: <b>PRIVATE</b></span>
            </div>
          </div>
          <label className="search-box">
            <Search aria-hidden="true" />
            <input
              aria-label="搜索对象 Key"
              placeholder="搜索对象 Key（模糊查询）"
              value={searchInput}
              onChange={(event) => setSearchInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== 'Enter') return
                event.preventDefault()
                setSearchQuery(searchInput.trim())
              }}
            />
        </label>
        </div>
        <div className="toolbar-actions object-toolbar-actions">
          <button className={`secondary-button rewind-button${viewMode === 'versions' ? ' active' : ''}`} type="button" onClick={openRewind} disabled={!bucket} title={viewMode === 'versions' ? '返回当前对象' : '打开版本回溯'} aria-label={viewMode === 'versions' ? '返回当前对象' : '打开版本回溯'} aria-pressed={viewMode === 'versions'}>
            <Undo2 className="button-icon" aria-hidden="true" />rewind
          </button>
          <input ref={fileInput} className="hidden-file-input" type="file" multiple onChange={selectFile} aria-label="选择要上传的文件" disabled={uploading} />
          <button className="primary-button" type="button" onClick={() => fileInput.current?.click()} disabled={!bucket || !accessKey || uploading}>
            <Upload className="button-icon" aria-hidden="true" />上传文件
          </button>
          {(uploadTasks.length > 0 || completedUploads.length > 0 || uploadsLoading) && <button className="secondary-button uploads-toggle-button" type="button" onClick={() => setUploadsPanelOpen(true)} aria-haspopup="dialog" aria-expanded={uploadsPanelOpen}>
            <PanelRight className="button-icon" aria-hidden="true" />上传任务{uploadTasks.length + completedUploads.length > 0 ? ` (${uploadTasks.length + completedUploads.length})` : ''}
          </button>
          }
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void load(true)} disabled={!bucket || loading} aria-busy={loading}>
            <RefreshCw className={`button-icon${loading ? ' spinning' : ''}`} aria-hidden="true" />刷新
          </button>
        </div>
      </div>

      <div className="object-location" aria-label="当前对象路径">
        <button className="icon-button path-back-button" type="button" onClick={goToParentPath} disabled={!bucket || !prefix.trim()} title="返回上一级路径" aria-label="返回上一级路径">
          <ArrowLeft aria-hidden="true" />
        </button>
        <FolderOpen className="object-location-icon" aria-hidden="true" />
        <div className="object-location-path">
          <button className="object-location-link" type="button" onClick={() => onNavigatePath('')} disabled={!bucket}>{bucket || '未选择 Bucket'}</button>
          {prefix.trim() && <><b>/</b><span>{displayObjectPath(prefix)}</span></>}
        </div>
        <div className="object-location-actions">
          <button className="icon-button copy-path-button" type="button" onClick={() => void copyCurrentPath()} disabled={!bucket} title="复制当前路径" aria-label="复制当前路径">
            <Copy aria-hidden="true" />
          </button>
          {viewMode !== 'versions' && <label className="deleted-toggle">
            <input key={viewMode} type="checkbox" checked={activeShowDeleted} onChange={(event) => {
              setSelectedObjectKeys(new Set())
              setSelectedDeletedIds(new Set())
              setSelectedVersionIds(new Set())
              setShowDeleted(event.target.checked)
            }} disabled={!bucket} />
            <span>显示已删除对象</span>
          </label>}
          <button className="secondary-button create-path-button" type="button" onClick={() => { setPathError(''); setPathName(''); setShowCreatePath(true) }} disabled={!bucket || !accessKey || viewMode !== 'current'}>
            <FolderPlus className="button-icon" aria-hidden="true" />Create new path
          </button>
        </div>
      </div>
      {error && <p className="error-banner">{error}</p>}

      {selectedCount > 0 && (
        <div className="selection-toolbar" role="toolbar" aria-label="批量对象操作">
          <strong>已选择 {selectedCount} 个对象</strong>
          <div className="selection-toolbar-actions">
            {selectedFiles.length > 0 && <>
              <button className="secondary-button" type="button" onClick={() => void downloadSelected()} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>
              <button className="secondary-button" type="button" onClick={() => openTransfer('copy')} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />复制</button>
            </>}
            {selectedData.length > 0 && <button className="secondary-button" type="button" onClick={() => openTransfer('move')} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />移动</button>}
            {selectedDeleted.length > 0 && <button className="secondary-button" type="button" onClick={() => void restoreSelected()} disabled={!accessKey}><RotateCcw className="button-icon" aria-hidden="true" />恢复</button>}
            <button className="danger-button" type="button" onClick={() => void removeSelected()} disabled={!accessKey}><Trash2 className="button-icon" aria-hidden="true" />{permanentDeleteOnly ? '永久删除' : '删除'}</button>
            <button className="icon-button" type="button" onClick={() => { setSelectedObjectKeys(new Set()); setSelectedDeletedIds(new Set()); setSelectedVersionIds(new Set()) }} title="清除选择" aria-label="清除选择"><X aria-hidden="true" /></button>
          </div>
        </div>
      )}

      <section className="panel table-panel">
        <div className="table-wrap">
          {viewMode === 'current' ? <table className="object-table">
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allCurrentSelected} onChange={(event) => toggleAllCurrent(event.target.checked)} aria-label="选择全部对象" /></th><th className="object-column-title">Object</th><th>Size</th><th>Last Modified</th><th className="sticky-actions-column">Actions</th></tr></thead>
            <tbody>{!showDeleted && filteredObjects.map((object) => (
                <tr key={object.key}>
                  <td className="selection-column"><input type="checkbox" checked={selectedObjectKeys.has(object.key)} onChange={(event) => toggleObjectSelection(object.key, event.target.checked)} aria-label={`选择 ${object.key}`} /></td>
                  <td className="object-key"><div className="file-cell object-tree-cell object-key-trigger" role="button" tabIndex={0} onClick={() => openObject(object)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openObject(object) } }} title={isDirectoryKey(object.key) ? '打开目录' : '查看对象详情'}><ObjectTreeIndent depth={objectTreeDepth(object.key, prefix)} />{isDirectoryKey(object.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(object.key, prefix)}</span></div></td>
                  <td>{isDirectoryKey(object.key) ? '-' : formatBytes(object.size)}</td>
                  <td>{object.last_modified ? new Date(object.last_modified).toLocaleString() : '-'}</td>
                  <td className="table-actions sticky-actions-column">
                    <ActionMenu label={`${isDirectoryKey(object.key) ? '管理目录' : '管理'} ${displayKeyForMessage(object.key)}`}>
                      {!isDirectoryKey(object.key) && <button type="button" role="menuitem" onClick={() => void download(object)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>}
                      {!isDirectoryKey(object.key) && <button type="button" role="menuitem" onClick={() => openTransfer('copy', { kind: 'current', object })} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />复制</button>}
                      <button type="button" role="menuitem" onClick={() => openTransfer('move', { kind: 'current', object })} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />移动</button>
                      <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeObject(object)} disabled={!accessKey || deletingKey === object.key || (isDirectoryKey(object.key) && objects.some((item) => item.key !== object.key && item.key.startsWith(object.key)))}><Trash2 className="button-icon" aria-hidden="true" />{isDirectoryKey(object.key) ? '删除目录' : '删除'}</button>
                    </ActionMenu>
                  </td>
                </tr>
              ))}
              {showDeleted && filteredDeletedObjects.map((version) => {
                const identity = `${version.key}\u0000${version.version_id}`
                const restoring = restoringVersion === identity
                return <tr key={identity} className="delete-marker-row">
                  <td className="selection-column"><input type="checkbox" checked={selectedDeletedIds.has(identity)} onChange={(event) => toggleDeletedSelection(version, event.target.checked)} aria-label={`选择已删除对象 ${version.key}`} /></td>
                  <td className="object-key"><div className="file-cell object-tree-cell"><ObjectTreeIndent depth={objectTreeDepth(version.key, prefix)} /><Trash2 className="file-symbol" aria-hidden="true" /><span>{displayObjectKey(version.key, prefix)}</span><span className="status-badge delete-marker">已删除</span></div></td>
                  <td>{deletedObjectSizes.has(version.key) ? formatBytes(deletedObjectSizes.get(version.key)!) : '-'}</td>
                  <td>{new Date(version.last_modified).toLocaleString()}</td>
                  <td className="table-actions sticky-actions-column">
                    <ActionMenu label={`管理已删除对象 ${version.key}`}>
                      <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />恢复对象</button>
                      <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={!accessKey || deletingVersion === identity}><Trash2 className="button-icon" aria-hidden="true" />永久删除</button>
                    </ActionMenu>
                  </td>
                </tr>
              })}</tbody>
          </table> : <table className="object-table version-table">
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allVersionsSelected} onChange={(event) => toggleAllVersions(event.target.checked)} aria-label="选择全部对象版本" /></th><th className="object-column-title">Object</th><th>State</th><th>Size</th><th>Last Modified</th><th className="sticky-actions-column">Actions</th></tr></thead>
            <tbody>{filteredVersions.map((version) => {
              const identity = `${version.key}\u0000${version.version_id}`
              const restoring = restoringVersion === identity
              const objectDeleted = deletedObjectKeys.has(version.key)
              return <tr key={identity} className={version.is_delete_marker ? 'delete-marker-row' : ''}>
                <td className="selection-column"><input type="checkbox" checked={selectedVersionIds.has(identity)} onChange={(event) => toggleVersionSelection(version, event.target.checked)} aria-label={`选择 ${version.key} 的版本`} /></td>
                <td className="object-key"><div className="file-cell object-tree-cell"><ObjectTreeIndent depth={objectTreeDepth(version.key, prefix)} />{version.is_delete_marker ? <Trash2 className="file-symbol" aria-hidden="true" /> : isDirectoryKey(version.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(version.key, prefix)}</span></div></td>
                <td><div className="version-badges">{version.is_latest && <span className="status-badge latest">Latest</span>}{version.is_delete_marker && <span className="status-badge delete-marker">DeleteMarker</span>}{!version.is_latest && !version.is_delete_marker && <span className="status-badge">Previous</span>}</div></td>
                <td>{version.is_delete_marker
                  ? (deletedVersionSizes.has(version.key) ? formatBytes(deletedVersionSizes.get(version.key)!) : '-')
                  : isDirectoryKey(version.key) ? '-' : formatBytes(version.size)}</td>
                <td>{new Date(version.last_modified).toLocaleString()}</td>
                <td className="table-actions sticky-actions-column">
                  <ActionMenu label={`管理 ${version.key} 的版本 ${shortVersionId(version.version_id)}`}>
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => void downloadVersion(version)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />下载</button>}
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => openTransfer('copy', { kind: 'version', version })} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />复制</button>}
                    {!version.is_delete_marker && <button type="button" role="menuitem" onClick={() => openTransfer('move', { kind: 'version', version })} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />移动</button>}
                    {version.is_delete_marker && version.is_latest && <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />恢复对象</button>}
                    {!version.is_delete_marker && !version.is_latest && <button type="button" role="menuitem" onClick={() => void rewindVersion(version)} disabled={!accessKey || restoring}><History className="button-icon" aria-hidden="true" />回溯到此版本</button>}
                    {!version.is_delete_marker && !version.is_latest && objectDeleted && <button type="button" role="menuitem" onClick={() => void restoreVersion(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />恢复</button>}
                    {version.is_delete_marker
                      ? <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={!accessKey || deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />永久删除</button>
                      : <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeVersion(version)} disabled={!accessKey || deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />永久删除</button>}
                  </ActionMenu>
                </td>
              </tr>
            })}</tbody>
          </table>}
        </div>
        {viewMode === 'current' && (showDeleted ? filteredDeletedObjects.length === 0 : filteredObjects.length === 0) && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? '没有匹配对象' : showDeleted ? '没有已删除对象' : '这个 Bucket 还是空的'}</strong><span>{normalizedSearchQuery ? '没有找到匹配当前搜索的对象 Key。' : showDeleted ? '当前路径下没有 DeleteMarker。' : '上传文件后，对象会显示在这里。'}</span></div>}
        {viewMode === 'versions' && filteredVersions.length === 0 && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? '没有匹配版本' : showDeleted ? '没有删除标记' : '没有对象版本'}</strong><span>{normalizedSearchQuery ? '没有找到匹配当前搜索的对象 Key。' : showDeleted ? '当前没有可查看的 DeleteMarker。' : '启用 Versioning 后，新写入和删除会记录在这里。'}</span></div>}
      </section>
      {viewMode === 'current' && !showDeleted && nextToken && <div ref={loadMoreSentinel} className="list-load-sentinel" aria-live="polite">{loading ? '正在加载更多...' : '继续下拉加载更多'}</div>}

      {uploadsPanelOpen && (
        <aside className="uploads-drawer" role="dialog" aria-modal="false" aria-labelledby="uploads-drawer-title">
          <header className="uploads-drawer-header">
            <div className="uploads-drawer-title"><List aria-hidden="true" /><div><p className="eyebrow">Transfers</p><h3 id="uploads-drawer-title">Downloads / Uploads</h3></div></div>
            <button className="icon-button" type="button" aria-label="关闭上传面板" title="关闭" onClick={() => setUploadsPanelOpen(false)}><X aria-hidden="true" /></button>
          </header>
          <div className="uploads-drawer-body" aria-live="polite">
            {uploadsLoading && <p className="uploads-drawer-status">正在同步分片上传任务...</p>}
            {!uploadsLoading && uploadTasks.length === 0 && completedUploads.length === 0 && <p className="uploads-drawer-status">当前没有上传任务。</p>}
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
                    <div className="upload-task-title"><strong>{displayFileName(task.key)}</strong><span className={`upload-status ${task.status}`}>{task.status === 'uploading' ? '上传中' : task.status === 'completing' ? '完成中' : task.status === 'failed' ? '失败' : '已暂停'}</span></div>
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
            {completedUploads.map((item) => (
              <article className="upload-task upload-task-completed" key={item.uploadId}>
                <div className="upload-task-main">
                  <div className="upload-task-title"><CheckCircle2 className="upload-complete-icon" aria-hidden="true" /><strong>{displayFileName(item.key)}</strong><span className="upload-status completed">已完成</span></div>
                  <span>{item.fileName} · {formatBytes(item.fileSize)} · {new Date(item.completedAt).toLocaleTimeString()}</span>
                </div>
                <strong className="upload-complete-percent">100%</strong>
                <div className="upload-progress-track" role="progressbar" aria-label={`${item.fileName}上传进度`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={100}><span style={{ width: '100%' }} /></div>
              </article>
            ))}
          </div>
        </aside>
      )}

      {showCreatePath && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setShowCreatePath(false)}>
          <section className="lifecycle-modal credential-modal create-path-modal" role="dialog" aria-modal="true" aria-labelledby="create-path-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><FolderPlus aria-hidden="true" /><h3 id="create-path-dialog-title">Create new path</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={() => setShowCreatePath(false)}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={createPath}>
              <p className="credential-modal-description">将在当前路径下创建一级目录。当前路径：<strong>{prefix.trim() || '/'}</strong></p>
              <div className="credential-modal-fields create-path-fields">
                <label>目录名称<input aria-label="目录名称" placeholder="例如 images" value={pathName} onChange={(event) => setPathName(event.target.value)} required autoFocus /></label>
              </div>
              {pathError && <p className="form-error credential-form-error" role="alert">{pathError}</p>}
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setShowCreatePath(false)}>取消</button>
                <button className="primary-button" type="submit">创建路径</button>
              </footer>
            </form>
          </section>
        </div>
      )}

      {transferDialog && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => { if (!transferring) setTransferDialog(null) }}>
          <section className="lifecycle-modal credential-modal transfer-modal" role="dialog" aria-modal="true" aria-labelledby="transfer-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><TransferIcon aria-hidden="true" /><h3 id="transfer-dialog-title">{transferDialog.mode === 'copy' ? '复制对象' : '移动对象'}</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={() => { if (!transferring) setTransferDialog(null) }}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={submitTransfer}>
              <p className="credential-modal-description">已选择 {transferDialog.items.length} 项。目标路径填写父目录，文件名保持不变，目录会保留目录名及其全部内容。</p>
              <div className="credential-modal-fields transfer-fields">
                <label>目标 Bucket
                  <select value={transferBucket} onChange={(event) => setTransferBucket(event.target.value)} required disabled={transferring}>
                    <option value="" disabled>选择 Bucket</option>
                    {buckets.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
                  </select>
                </label>
                <label>目标路径
                  <input value={transferPath} onChange={(event) => setTransferPath(event.target.value)} placeholder="例如 archive/2026" disabled={transferring} />
                </label>
              </div>
              {transferError && <p className="form-error credential-form-error" role="alert">{transferError}</p>}
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setTransferDialog(null)} disabled={transferring}>取消</button>
                <button className="primary-button" type="submit" disabled={transferring || !transferBucket}>{transferring ? '处理中...' : transferDialog.mode === 'copy' ? '开始复制' : '开始移动'}</button>
              </footer>
            </form>
          </section>
        </div>
      )}

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

function joinObjectPath(path: string, name: string) {
  const base = path.trim().replace(/^\/+|\/+$/g, '')
  return base ? `${base}/${name}` : name
}

function parentObjectPath(path: string) {
  const normalized = path.trim().replace(/^\/+|\/+$/g, '')
  if (!normalized) return ''
  const separator = normalized.lastIndexOf('/')
  return separator >= 0 ? `${normalized.slice(0, separator + 1)}` : ''
}

function objectTreeDepth(key: string, prefix: string) {
  const normalizedKey = key.trim().replace(/^\/+|\/+$/g, '')
  const normalizedPrefix = prefix.trim().replace(/^\/+|\/+$/g, '')
  const relativeKey = normalizedPrefix && (normalizedKey === normalizedPrefix || normalizedKey.startsWith(`${normalizedPrefix}/`))
    ? normalizedKey.slice(normalizedPrefix.length).replace(/^\/+/, '')
    : normalizedKey
  return Math.max(0, relativeKey.split('/').filter(Boolean).length - 1)
}

function isDirectoryKey(key: string) {
  return key.endsWith('/')
}

function displayDirectoryKey(key: string) {
  return key.replace(/\/+$/, '')
}

function displayKeyForMessage(key: string) {
  return isDirectoryKey(key) ? displayDirectoryKey(key) : key
}

function displayFileName(key: string) {
  const normalized = key.replace(/\/+$/, '')
  return normalized.split('/').pop() || normalized
}

function directorySummary(key: string, lastModified = ''): ObjectSummary {
  return {
    key,
    size: 0,
    etag: '',
    last_modified: lastModified,
  }
}

function displayObjectKey(key: string, prefix: string) {
  const normalizedPrefix = prefix.trim().replace(/^\/+/, '')
  if (!normalizedPrefix) return isDirectoryKey(key) ? key.replace(/\/+$/, '') : key
  const prefixWithSlash = normalizedPrefix.endsWith('/') ? normalizedPrefix : `${normalizedPrefix}/`
  if (!key.startsWith(prefixWithSlash)) return isDirectoryKey(key) ? key.replace(/\/+$/, '') : key
  const relativeKey = key.slice(prefixWithSlash.length)
  return isDirectoryKey(key) ? relativeKey.replace(/\/+$/, '') : relativeKey
}

function displayObjectPath(path: string) {
  return path.trim().replace(/^\/+|\/+$/g, '')
}

function compareObjectKeys(left: { key: string }, right: { key: string }) {
  const directoryOrder = Number(isDirectoryKey(right.key)) - Number(isDirectoryKey(left.key))
  return directoryOrder || left.key.localeCompare(right.key)
}

function sortObjectSummaries(objects: ObjectSummary[]) {
  return [...objects].sort(compareObjectKeys)
}

function sortObjectVersions(versions: ObjectVersion[]) {
  return [...versions].sort(compareObjectKeys)
}

function hideCurrentDirectoryMarker<T extends { key: string }>(items: T[], prefix: string) {
  const currentDirectory = prefix.trim()
  if (!currentDirectory.endsWith('/')) return items
  return items.filter((item) => item.key !== currentDirectory)
}

function ObjectTreeIndent({ depth }: { depth: number }) {
  if (depth <= 0) return null
  return <span className="object-tree-guides" style={{ width: `${depth * 20}px` }} aria-hidden="true" />
}

function fileExtension(key: string) {
  const name = key.split('/').pop() || key
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toUpperCase().slice(0, 8) : 'FILE'
}

function shortVersionId(versionId: string) {
  return versionId === 'null' ? 'null' : `${versionId.slice(0, 8)}...${versionId.slice(-6)}`
}

function latestObjectSizes(versions: ObjectVersion[]) {
  const sizes = new Map<string, number>()
  for (const version of versions) {
    if (!version.is_delete_marker && !sizes.has(version.key)) sizes.set(version.key, version.size)
  }
  return sizes
}

function versionIdentity(version: ObjectVersion) {
  return `${version.key}\u0000${version.version_id}`
}

function isImageKey(key: string) {
  return /\.(avif|bmp|gif|jpe?g|png|svg|webp)$/i.test(key)
}
