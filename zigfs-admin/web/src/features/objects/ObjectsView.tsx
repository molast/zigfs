import { t, getFormatLocale } from '@/locales'
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
  Play,
  RefreshCw,
  RotateCcw,
  Trash2,
  Undo2,
  Upload,
  X,
} from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { ActionMenu } from '../../components/ActionMenu'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import { ToolbarControls, ToolbarRefreshButton, ToolbarSearch } from '../../components/ui/ToolbarControls'
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

interface FolderSizeSummary {
  bytes: number
  objects: number
  generatedAt: string
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
  const notifyError = useErrorToast()
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
  const [deletingKey, setDeletingKey] = useState('')
  const [deletingVersion, setDeletingVersion] = useState('')
  const [restoringVersion, setRestoringVersion] = useState('')
  const [selectedObjectKeys, setSelectedObjectKeys] = useState<Set<string>>(new Set())
  const [selectedDeletedIds, setSelectedDeletedIds] = useState<Set<string>>(new Set())
  const [selectedVersionIds, setSelectedVersionIds] = useState<Set<string>>(new Set())
  const [transferDialog, setTransferDialog] = useState<TransferDialogState | null>(null)
  const [transferBucket, setTransferBucket] = useState(bucket)
  const [transferPath, setTransferPath] = useState('')
  const [transferDirectories, setTransferDirectories] = useState<string[]>([])
  const [transferTreeOpen, setTransferTreeOpen] = useState(false)
  const [transferring, setTransferring] = useState(false)
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailVersionId, setDetailVersionId] = useState<string | null>(null)
  const [detailUrl, setDetailUrl] = useState<PresignObjectResponse | null>(null)
  const [detailTags, setDetailTags] = useState('')
  const [detailTagsSaving, setDetailTagsSaving] = useState(false)
  const [directorySizeSummaries, setDirectorySizeSummaries] = useState<Map<string, FolderSizeSummary>>(new Map())
  const [directorySizeLoading, setDirectorySizeLoading] = useState<Set<string>>(new Set())
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
    withLoading(t('objects.loadingAccessKeys'), () => api.listAccessKeys())
      .then((keyItems) => {
        const enabledKeys = keyItems.filter((item) => item.enabled)
        setAccessKeys(enabledKeys)
        setAccessKey((current) => current || enabledKeys[0]?.access_key || '')
      })
      .catch((reason: Error) => {
        accessKeysLoaded.current = false
        notifyError(reason.message)
      })
  }, [api, withLoading])

  useEffect(() => {
    if (!bucket || bucketInfoLoaded.current === bucket) return
    bucketInfoLoaded.current = bucket
    withLoading(t('objects.loadingBucketInformation'), () => api.listBuckets())
      .then((items) => {
        setBuckets(items)
        setBucketInfo(items.find((item) => item.name === bucket) ?? null)
      })
      .catch((reason: Error) => {
        if (bucketInfoLoaded.current === bucket) bucketInfoLoaded.current = ''
        notifyError(reason.message)
      })
  }, [api, bucket, withLoading])

  async function load(reset: boolean, requestedPrefix = prefix, requestedShowDeleted = showDeleted) {
    if (!bucket) return
    if (!reset && (listLoading.current || !nextToken || viewMode !== 'current' || requestedShowDeleted)) return
    const requestId = ++listRequestId.current
    listLoading.current = true
    const stopLoading = startLoading(t('objects.loadingValue', { '0': viewMode === 'versions' ? t('objects.objectVersion') : t('common.objects') }))
    try {
      if (reset) {
        setSelectedObjectKeys(new Set())
        setSelectedDeletedIds(new Set())
        setSelectedVersionIds(new Set())
        setDirectorySizeSummaries(new Map())
        setDirectorySizeLoading(new Set())
      }
      setLoading(true)
      const currentPrefix = requestedPrefix.trim()
      if (viewMode === 'versions') {
        const loadedVersions = await api.listObjectVersions(bucket, currentPrefix)
        if (requestId !== listRequestId.current) return
        setVersions(sortObjectVersions(hideCurrentDirectoryMarker(loadedVersions, currentPrefix)))
        setDeletedObjects([])
        setDeletedObjectSizes(new Map())
        setNextToken('')
      } else if (requestedShowDeleted) {
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
        // Deleted markers still occupy index pagination slots in ZigFS. Read a
        // larger page here so a bucket with many deleted versions does not
        // produce an empty visible page before active objects are reached.
        const result = await api.listObjects(bucket, search ? '' : currentPrefix, reset ? '' : nextToken, search, 1000, search ? '' : '/')
        if (requestId !== listRequestId.current) return
        const directoryItems = (result.directories ?? []).map((directory) => directorySummary(directory.key, directory.last_modified))
        const visibleItems = hideCurrentDirectoryMarker([...result.items, ...directoryItems], currentPrefix)
        setObjects((current) => reset ? sortObjectSummaries(visibleItems) : [...current, ...visibleItems])
        setNextToken(result.is_truncated ? (result.continuation_token ?? '') : '')
        setDeletedObjects([])
        setDeletedObjectSizes(new Map())
      }
    } catch (reason) {
      if (requestId === listRequestId.current) notifyError((reason as Error).message)
    } finally {
      if (requestId === listRequestId.current) {
        setLoading(false)
        listLoading.current = false
      }
      stopLoading()
    }
  }

  async function calculateFolderSize(folderPrefix: string): Promise<FolderSizeSummary> {
    let continuation = ''
    let bytes = 0
    let objectsCount = 0
    do {
      const result = await api.listObjects(bucket, folderPrefix, continuation, '', 1000, '')
      for (const item of result.items) {
        if (isDirectoryKey(item.key)) continue
        bytes += item.size
        objectsCount += 1
      }
      continuation = result.is_truncated ? (result.continuation_token ?? '') : ''
    } while (continuation)
    return { bytes, objects: objectsCount, generatedAt: new Date().toISOString() }
  }

  async function refreshDirectorySize(directoryKey: string) {
    if (!bucket || directorySizeLoading.has(directoryKey)) return
    setDirectorySizeLoading((current) => new Set(current).add(directoryKey))
    try {
      const summary = await calculateFolderSize(directoryKey)
      setDirectorySizeSummaries((current) => new Map(current).set(directoryKey, summary))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setDirectorySizeLoading((current) => {
        const next = new Set(current)
        next.delete(directoryKey)
        return next
      })
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

  useEffect(() => {
    if (!transferDialog || !transferBucket) return
    let cancelled = false
    async function loadTransferDirectories() {
      const found = new Set<string>()
      const queue = ['']
      while (queue.length > 0) {
        const current = queue.shift()!
        let continuation = ''
        do {
          const page = await api.listObjects(transferBucket, current, continuation, '', 1000, '/')
          for (const directory of [...(page.directories ?? []), ...(page.common_prefixes ?? []).map((key) => ({ key }))]) {
            const key = typeof directory === 'string' ? directory : directory.key
            if (!found.has(key)) {
              found.add(key)
              queue.push(key)
            }
          }
          continuation = page.is_truncated ? page.continuation_token ?? '' : ''
        } while (continuation)
      }
      if (!cancelled) setTransferDirectories([...found].sort((left, right) => compareObjectKeys({ key: left }, { key: right })))
    }
    void loadTransferDirectories().catch(() => { if (!cancelled) setTransferDirectories([]) })
    return () => { cancelled = true }
  }, [api, transferBucket, transferDialog])

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
    setSelectedObjectKeys(checked ? new Set(filteredObjects.filter((object) => !isDirectoryKey(object.key)).map((object) => object.key)) : new Set())
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
    setTransferDirectories([])
    setTransferTreeOpen(false)
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
      showToast(t('objects.currentPathCopied'))
    } catch (reason) {
      notifyError((reason as Error).message)
    }
  }

  async function loadMultipartUploads() {
    if (!bucket) return
    const stopLoading = startLoading(t('objects.syncingMultipartUploads'))
    try {
      uploadsHydrated.current = false
      setUploadsLoading(true)
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
      notifyError((reason as Error).message)
    } finally {
      setUploadsLoading(false)
      stopLoading()
    }
  }

  async function beginUploads(files: File[]) {
    if (!bucket || !accessKey || files.length === 0) return
    const startNewUploadSession = !uploadsPanelOpen
    if (startNewUploadSession) {
      setUploadTasks([])
      setCompletedUploads([])
    }
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
    if (failures.length > 0) notifyError(t('objects.unableToCreateUploadsForValue', { '0': failures.join('；') }))
    for (const task of tasks) {
      if (task.file) await runUpload(task, task.file)
    }
  }

  async function createPath(event: FormEvent) {
    event.preventDefault()
    const name = pathName.trim().replace(/^\/+|\/+$/g, '')
    if (!name || !bucket || !accessKey) return
    if (name.includes('/')) {
      notifyError(t('objects.enterASingleDirectoryNameWithout'))
      return
    }
    const key = `${joinObjectPath(prefix, name)}/`
    const stopLoading = startLoading(t('objects.creatingPath'))
    try {
      await api.createDirectory(bucket, key)
      setShowCreatePath(false)
      setPathName('')
      setShowDeleted(false)
      setShowDeletedVersions(false)
      setViewMode('current')
      showToast(t('objects.createdPathValue', { '0': displayDirectoryKey(key) }))
      setPrefix(key)
      onNavigatePath(key)
    } catch (reason) {
      notifyError((reason as Error).message)
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
        if (!etag) throw lastError ?? new Error(t('objects.partValueFailedToUpload', { '0': partNumber }))
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
        showToast(t('objects.pausedValue', { '0': displayFileName(task.key) }))
      } else {
        const message = (reason as Error).message
        updateUploadTask(task.uploadId, { status: 'failed', error: message })
        notifyError(message)
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
      title: t('objects.cancelMultipartUpload'),
      message: t('objects.cancelUploadValueAndDeleteItsUploadedParts', { '0': task.key }),
      confirmLabel: t('objects.cancelUpload'),
      danger: true,
    })) return
    const control = uploadControl.current
    if (control?.uploadId === task.uploadId && control.completing) {
      showToast(t('objects.completingValue', { '0': displayFileName(task.key) }))
      return
    }
    if (control?.uploadId === task.uploadId) {
      control.paused = true
      control.cancelled = true
      control.request?.abort()
    }
    const stopLoading = startLoading(t('objects.cancellingMultipartUpload'))
    try {
      await api.abortMultipartUpload(task.uploadId, task.bucket, task.key)
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      showToast(t('objects.cancelledValue', { '0': displayFileName(task.key) }))
    } catch (reason) {
      const message = (reason as Error).message
      updateUploadTask(task.uploadId, { status: 'failed', error: message })
      notifyError(message)
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
      updateUploadTask(task.uploadId, { status: 'failed', error: t('objects.fileSizeOrModificationTimeDoesNotMatchThe') })
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
    const stopLoading = startLoading(t('objects.downloadingObject'))
    try {
      const presigned = await api.presignObject(accessKey, bucket, object.key, 'GET', 900)
      const response = await fetch(presigned.url)
      if (!response.ok) throw new Error(t('objects.downloadFailedValue', { '0': response.status }))
      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = object.key.split('/').pop() || object.key
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
      showToast(t('objects.downloadedValue', { '0': displayFileName(object.key) }))
      return true
    } catch (reason) {
      notifyError((reason as Error).message)
      return false
    } finally {
      stopLoading()
    }
  }

  async function downloadVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker) return false
    const stopLoading = startLoading(t('objects.downloadingObjectVersion'))
    try {
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'GET', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url)
      if (!response.ok) throw new Error(t('objects.downloadFailedValue', { '0': response.status }))
      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = version.key.split('/').pop() || version.key
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
      showToast(t('objects.downloadedVersionValueOfValue', { '0': displayFileName(version.key), '1': shortVersionId(version.version_id) }))
      return true
    } catch (reason) {
      notifyError((reason as Error).message)
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
      throw new Error(t('objects.destinationMatchesTheSourceValue', { '0': displayKeyForMessage(sourceKey) }))
    }
    const presigned = await api.presignObject(accessKey, destinationBucket, destinationKey, 'PUT', 900, {
      copySource: { bucket, key: sourceKey, ...(versionId ? { versionId } : {}) },
    })
    const response = await fetch(presigned.url, {
      method: 'PUT',
      headers: presigned.required_headers,
    })
    if (!response.ok) throw new Error(t('objects.failedToCopyValueValue', { '0': displayKeyForMessage(sourceKey), '1': response.status }))
  }

  async function deleteObjectKey(key: string, versionId?: string) {
    if (!accessKey || !bucket) return
    const presigned = await api.presignObject(accessKey, bucket, key, 'DELETE', 900, versionId ? { versionId } : undefined)
    const response = await fetch(presigned.url, { method: 'DELETE' })
    if (!response.ok) throw new Error(t('objects.failedToDeleteValueValue', { '0': key, '1': response.status }))
  }

  async function copyDirectory(sourceKey: string, destinationBucket: string, destinationPath: string) {
    const sourcePrefix = sourceKey.endsWith('/') ? sourceKey : `${sourceKey}/`
    const directoryName = sourcePrefix.slice(0, -1).split('/').pop()
    if (!directoryName) throw new Error(t('objects.unableToDetermineDirectoryNameValue', { '0': displayDirectoryKey(sourceKey) }))
    const destinationPrefix = `${joinObjectPath(destinationPath, directoryName)}/`
    if (destinationBucket === bucket && (destinationPrefix === sourcePrefix || destinationPrefix.startsWith(sourcePrefix))) {
      throw new Error(t('objects.destinationCannotBeInsideTheSourceDirectoryValue', { '0': displayDirectoryKey(sourcePrefix) }))
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

    const stopLoading = startLoading(t('objects.checkingDirectory'))
    let hasChildren = false
    try {
      const [page, versions] = await Promise.all([
        api.listObjects(bucket, key, '', '', 1, '/'),
        api.listObjectVersions(bucket, key),
      ])
      hasChildren = page.items.some((item) => item.key !== key) ||
        (page.common_prefixes ?? []).some((prefixKey) => prefixKey !== key) ||
        (page.directories ?? []).some((directory) => directory.key !== key) ||
        versions.some((version) => version.key !== key && version.key.startsWith(key))
    } catch (reason) {
      notifyError((reason as Error).message)
      return false
    } finally {
      stopLoading()
    }

    if (!hasChildren) return true
    await confirm({
      title: t('objects.deleteDirectory'),
      message: t('objects.deleteDirectoryValueItMustBeEmptyItsObjects', { '0': displayDirectoryKey(key) }),
      cancelLabel: t('objects.gotIt'),
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
      if (!response.ok) throw new Error(t('objects.failedToDeleteValueValue', { '0': displayKeyForMessage(item.object.key), '1': response.status }))
      return
    }
    const presigned = await api.presignObject(accessKey, bucket, item.version.key, 'DELETE', 900, { versionId: item.version.version_id })
    const response = await fetch(presigned.url, { method: 'DELETE' })
    if (!response.ok) throw new Error(t('objects.failedToDeleteVersionValueValue', { '0': shortVersionId(item.version.version_id), '1': response.status }))
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
      title: t('objects.permanentlyDeleteObject'),
      message: t('objects.permanentlyDeleteValueIncludingAllVersionsAndDeleteMarkers', { '0': version.key }),
      confirmLabel: t('objects.permanentlyDelete'),
      danger: true,
    })) return
    const identity = versionIdentity(version)
    const stopLoading = startLoading(t('objects.permanentlyDeletingObjects'))
    try {
      setDeletingVersion(identity)
      await purgeObject(version.key)
      showToast(t('objects.permanentlyDeletedValue', { '0': displayFileName(version.key) }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
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
      notifyError(t('objects.someObjectsFailedToDownloadPleaseRetry'))
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
    const label = permanent ? t('objects.permanentlyDeleteSelectedVersions') : t('objects.deleteSelectedObjects')
    if (!await confirm({
      title: purgingDeletedObjects ? t('objects.permanentlyDeleteObject') : label,
      message: purgingDeletedObjects
        ? t('objects.permanentlyDeleteValueObjectsIncludingAllVersionsAndDelete', { '0': new Set(deleteMarkers.map((item) => item.version.key)).size })
        : permanent
        ? t('objects.permanentlyDeleteValueObjectVersionsThisCannotBeUndone', { '0': items.length })
        : t('objects.deleteValueObjectsADeleteMarkerIsCreatedWhen', { '0': items.length }),
      confirmLabel: permanent ? t('objects.permanentlyDelete') : t('objects.delete'),
      danger: true,
    })) return
    const stopLoading = startLoading(permanent ? t('objects.permanentlyDeletingObjectVersions') : t('objects.deletingObjects'))
    try {
      if (purgingDeletedObjects) {
        for (const key of new Set(deleteMarkers.map((item) => item.version.key))) await purgeObject(key)
      } else {
        for (const item of items) await deleteItem(item)
      }
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
      showToast(t('objects.processedValueObjects', { '0': items.length }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function restoreSelected() {
    const items = selectedItems().filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker && item.version.is_latest)
    if (items.length === 0) return
    if (!await confirm({
      title: t('objects.restoreDeletedObjects'),
      message: t('objects.restoreValueDeletedObjectsByRemovingTheirLatestDelete', { '0': items.length }),
      confirmLabel: t('objects.restoreObjects'),
    })) return
    const stopLoading = startLoading(t('objects.restoringObjects'))
    try {
      for (const item of items) await deleteItem(item)
      setSelectedObjectKeys(new Set())
      setSelectedDeletedIds(new Set())
      setSelectedVersionIds(new Set())
      initialLoadKey.current = ''
      setShowDeleted(false)
      showToast(t('objects.restoredValueObjects', { '0': items.length }))
      await load(true, prefix, false)
    } catch (reason) {
      notifyError((reason as Error).message)
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
    const stopLoading = startLoading(mode === 'copy' ? t('objects.copyingObjects') : t('objects.movingObjects'))
    try {
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
      showToast(t('objects.valueValueObjects', { '0': mode === 'copy' ? t('common.copied') : t('common.moved'), '1': items.length }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setTransferring(false)
      stopLoading()
    }
  }

  async function openDetail(object: ObjectSummary) {
    setDetail(object)
    setDetailVersionId(null)
    setDetailUrl(null)
    setDetailTags('')
    if (!accessKey || !bucket) return
    const stopLoading = startLoading(t('objects.generatingPreviewLink'))
    try {
      setDetailUrl(await api.presignObject(accessKey, bucket, object.key, 'GET', 900))
      const tagUrl = await api.presignObject(accessKey, bucket, object.key, 'GET', 900, { tagging: true })
      const tagResponse = await fetch(tagUrl.url)
      if (!tagResponse.ok) throw new Error(t('objects.failedToReadObjectTagsValue', { '0': tagResponse.status }))
      const xml = new DOMParser().parseFromString(await tagResponse.text(), 'application/xml')
      const tags = [...xml.querySelectorAll('Tag')].map((tag) => ({ key: tag.querySelector('Key')?.textContent ?? '', value: tag.querySelector('Value')?.textContent ?? '' }))
      setDetailTags(JSON.stringify(Object.fromEntries(tags.map((tag) => [tag.key, tag.value])), null, 2))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      stopLoading()
    }
  }

  async function openVersionTagDetail(version: ObjectVersion) {
    setDetail({ key: version.key, size: version.size, etag: '', last_modified: version.last_modified })
    setDetailVersionId(version.version_id)
    setDetailUrl(null)
    setDetailTags('')
    if (!accessKey || !bucket) return
    try {
      setDetailUrl(await api.presignObject(accessKey, bucket, version.key, 'GET', 900, { versionId: version.version_id }))
      const tagUrl = await api.presignObject(accessKey, bucket, version.key, 'GET', 900, { versionId: version.version_id, tagging: true })
      const response = await fetch(tagUrl.url)
      if (!response.ok) throw new Error(t('objects.failedToReadVersionTagsValue', { '0': response.status }))
      const xml = new DOMParser().parseFromString(await response.text(), 'application/xml')
      setDetailTags(JSON.stringify(Object.fromEntries([...xml.querySelectorAll('Tag')].map((tag) => [tag.querySelector('Key')?.textContent ?? '', tag.querySelector('Value')?.textContent ?? ''])), null, 2))
    } catch (reason) {
      notifyError((reason as Error).message)
    }
  }

  async function saveDetailTags() {
    if (!detail || !accessKey || !bucket) return
    setDetailTagsSaving(true)
    try {
      const parsed = JSON.parse(detailTags || '{}') as Record<string, string>
      const tagEntries = Object.entries(parsed)
      if (tagEntries.some(([key, value]) => !key || typeof value !== 'string')) throw new Error(t('objects.objectTagsMustBeAJsonObjectOfString'))
      const signed = await api.presignObject(accessKey, bucket, detail.key, tagEntries.length === 0 ? 'DELETE' : 'PUT', 900, { tagging: true, ...(detailVersionId ? { versionId: detailVersionId } : {}) })
      if (tagEntries.length === 0) {
        const response = await fetch(signed.url, { method: 'DELETE', headers: signed.required_headers })
        if (!response.ok) throw new Error(t('objects.failedToDeleteObjectTagsValue', { '0': response.status }))
        showToast(t('objects.objectTagsDeleted'))
        return
      }
      const body = `<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet>${tagEntries.map(([key, value]) => `<Tag><Key>${escapeXml(key)}</Key><Value>${escapeXml(value)}</Value></Tag>`).join('')}</TagSet></Tagging>`
      const response = await fetch(signed.url, { method: 'PUT', headers: { ...signed.required_headers, 'content-type': 'application/xml' }, body })
      if (!response.ok) throw new Error(t('objects.failedToSaveObjectTagsValue', { '0': response.status }))
      showToast(t('objects.objectTagsSaved'))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setDetailTagsSaving(false)
    }
  }

  function closeDetail() {
    setDetail(null)
    setDetailVersionId(null)
    setDetailUrl(null)
    setDetailTags('')
  }

  async function removeDirectory(object: ObjectSummary) {
    if (!accessKey || !bucket || !isDirectoryKey(object.key)) return
    if (!await ensureDirectoryCanBeDeleted(object.key)) return
    if (!await confirm({
      title: t('objects.deleteDirectory'),
      message: t('objects.deleteDirectoryValueItMustBeEmptyItsObjects', { '0': displayDirectoryKey(object.key) }),
      confirmLabel: t('objects.deleteDirectory'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('objects.deletingDirectory'))
    try {
      setDeletingKey(object.key)
      await api.deleteDirectory(bucket, object.key)
      showToast(t('objects.deletedDirectoryValue', { '0': displayDirectoryKey(object.key) }))
      await load(true)
    } catch (reason) {
      if (reason instanceof ApiError && reason.body.code === 'DirectoryNotEmpty') {
        stopLoading()
        await confirm({
          title: t('objects.unableToDeleteDirectory'),
          message: t('objects.directoryValueMustBeEmptyDeleteAllObjectsAnd', { '0': displayDirectoryKey(object.key) }),
          cancelLabel: t('objects.gotIt'),
          hideConfirm: true,
        })
      } else {
        notifyError((reason as Error).message)
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
      title: t('objects.deleteObject'),
      message: t('objects.deleteObjectValueZigfsCreatesADeleteMarkerIf', { '0': object.key }),
      confirmLabel: t('objects.delete'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('objects.deletingObjects'))
    try {
      setDeletingKey(object.key)
      const presigned = await api.presignObject(accessKey, bucket, object.key, 'DELETE', 900)
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(t('objects.deletionFailedValue', { '0': response.status }))
      if (detail?.key === object.key) closeDetail()
      showToast(t('objects.deletedValue', { '0': displayFileName(object.key) }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setDeletingKey('')
      stopLoading()
    }
  }

  async function removeVersion(version: ObjectVersion) {
    const target = version.is_delete_marker ? t('objects.deletemarker') : t('objects.objectVersion')
    if (!accessKey || !bucket) return
    if (!await ensureDirectoryCanBeDeleted(version.key)) return
    if (!await confirm({
      title: t('objects.permanentlyDeleteVersion'),
      message: t('objects.permanentlyDeleteValueValueOfValueNoNewDelete', { '0': version.key, '1': target, '2': shortVersionId(version.version_id) }),
      confirmLabel: t('objects.permanentlyDelete'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('objects.permanentlyDeletingObjectVersions'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setDeletingVersion(identity)
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(t('objects.versionDeletionFailedValue', { '0': response.status }))
      showToast(t('objects.permanentlyDeletedValueValueOfValue', { '0': displayFileName(version.key), '1': target, '2': shortVersionId(version.version_id) }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setDeletingVersion('')
      stopLoading()
    }
  }

  async function restoreDeletedObject(version: ObjectVersion) {
    if (!accessKey || !bucket || !version.is_delete_marker || !version.is_latest) return
    if (!await confirm({
      title: t('objects.restoreDeletedObjects'),
      message: t('objects.removeTheLatestDeleteMarkerAndRestoreValue', { '0': version.key }),
      confirmLabel: t('objects.restoreObjects'),
    })) return
    const stopLoading = startLoading(t('objects.restoringObjects'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(t('objects.objectRestorationFailedValue', { '0': response.status }))
      initialLoadKey.current = ''
      setShowDeleted(false)
      showToast(t('objects.restoredValue', { '0': displayFileName(version.key) }))
      await load(true, prefix, false)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setRestoringVersion('')
      stopLoading()
    }
  }

  async function rewindVersion(version: ObjectVersion) {
    if (!accessKey || !bucket || version.is_delete_marker || version.is_latest) return
    if (!await confirm({
      title: t('objects.rewindObjectVersion'),
      message: t('objects.rewindValueToVersionValueZigfsWillCreateA', { '0': version.key, '1': shortVersionId(version.version_id) }),
      confirmLabel: t('objects.rewindVersion'),
    })) return
    const stopLoading = startLoading(t('objects.rewindingObjectVersion'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'PUT', 900, {
        copySource: { bucket, key: version.key, versionId: version.version_id },
      })
      const response = await fetch(presigned.url, {
        method: 'PUT',
        headers: presigned.required_headers,
      })
      if (!response.ok) throw new Error(t('objects.versionRewindFailedValue', { '0': response.status }))
      showToast(t('objects.rewoundValueToVersionValue', { '0': displayFileName(version.key), '1': shortVersionId(version.version_id) }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
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
      title: t('objects.restoreObjectVersion'),
      message: t('objects.restoreValueAsVersionValueThisBecomesTheNew', { '0': version.key, '1': shortVersionId(version.version_id) }),
      confirmLabel: t('objects.restore'),
    })) return
    const stopLoading = startLoading(t('objects.restoringObjectVersion'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      const presigned = await api.presignObject(accessKey, bucket, version.key, 'PUT', 900, {
        copySource: { bucket, key: version.key, versionId: version.version_id },
      })
      const response = await fetch(presigned.url, {
        method: 'PUT',
        headers: presigned.required_headers,
      })
      if (!response.ok) throw new Error(t('objects.versionRestorationFailedValue', { '0': response.status }))
      showToast(t('objects.restoredValueCurrentVersionIsValue', { '0': displayFileName(version.key), '1': shortVersionId(version.version_id) }))
      await load(true)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setRestoringVersion('')
      stopLoading()
    }
  }

  async function copyDetailUrl() {
    if (!detailUrl) return
    await navigator.clipboard.writeText(detailUrl.url)
    showToast(t('objects.previewLinkCopied'))
  }

  const visibleObjectCount = viewMode === 'current' ? (showDeleted ? filteredDeletedObjects.length : filteredObjects.length) : filteredVersions.length
  const selected = selectedItems()
  const selectedDeleted = selected.filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker)
  const selectedData = selected.filter((item) => item.kind === 'current' || !item.version.is_delete_marker)
  const selectedFiles = selectedData.filter((item) => !isDirectoryKey(item.kind === 'current' ? item.object.key : item.version.key))
  const selectedCount = selected.length
  const selectableObjects = filteredObjects.filter((object) => !isDirectoryKey(object.key))
  const selectableCurrentCount = showDeleted ? filteredDeletedObjects.length : selectableObjects.length
  const selectableVersionCount = filteredVersions.length
  const allCurrentSelected = selectableCurrentCount > 0 && (showDeleted
    ? filteredDeletedObjects.every((version) => selectedDeletedIds.has(versionIdentity(version)))
    : selectableObjects.length > 0 && selectableObjects.every((object) => selectedObjectKeys.has(object.key)))
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
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />{t('objects.backToBucket')}</button>
          <h2>{t('objects.objectBrowser')}</h2>
          <p className="page-description">{t('objects.browseUploadDownloadAndManageObjectsInThisBucket')}</p>
        </div>
        <span className="count-badge">{viewMode === 'current' ? t('objects.valuevalueObjects', { '0': visibleObjectCount, '1': !showDeleted && nextToken ? '+' : '' }) : t('objects.valueVersions', { '0': visibleObjectCount })}</span>
      </header>

      <div className="page-toolbar">
        <div className="toolbar-leading object-toolbar-leading">
          <div className="object-bucket-summary">
            <span className="object-bucket-summary-icon" aria-hidden="true"><Archive /></span>
            <div className="object-bucket-summary-copy">
              <strong>{bucketInfo?.name ?? (bucket || t('objects.noBucketSelected'))}</strong>
              <span>{t('objects.createdOn')} {bucketInfo ? new Date(bucketInfo.created_at).toLocaleString(getFormatLocale()) : '-'}</span>
              <span>{t('objects.access')} <b>{t('objects.private')}</b></span>
            </div>
          </div>
        </div>
        <ToolbarControls className="object-toolbar-actions">
          <ToolbarSearch
            label={t('objects.searchObjectKeys')}
            placeholder={t('objects.searchObjectKeysPartialMatch')}
            value={searchInput}
            onChange={(event) => setSearchInput(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== 'Enter') return
              event.preventDefault()
              setSearchQuery(searchInput.trim())
            }}
          />
          <button className={`secondary-button rewind-button${viewMode === 'versions' ? ' active' : ''}`} type="button" onClick={openRewind} disabled={!bucket} title={viewMode === 'versions' ? t('objects.backToCurrentObjects') : t('objects.openVersionHistory')} aria-label={viewMode === 'versions' ? t('objects.backToCurrentObjects') : t('objects.openVersionHistory')} aria-pressed={viewMode === 'versions'}>
            <Undo2 className="button-icon" aria-hidden="true" />{t('objects.rewind')}</button>
          <input ref={fileInput} className="hidden-file-input" type="file" multiple onChange={selectFile} aria-label={t('objects.selectFilesToUpload')} disabled={uploading} />
          <button className="primary-button" type="button" onClick={() => fileInput.current?.click()} disabled={!bucket || !accessKey || uploading}>
            <Upload className="button-icon" aria-hidden="true" />{t('objects.uploadFiles')}</button>
          <ToolbarRefreshButton label={t('objects.refresh')} onClick={() => void load(true)} disabled={!bucket} busy={loading} />
        </ToolbarControls>
      </div>

      <div className="object-location" aria-label={t('objects.currentObjectPath')}>
        <button className="icon-button path-back-button" type="button" onClick={goToParentPath} disabled={!bucket || !prefix.trim()} title={t('objects.goToParentDirectory')} aria-label={t('objects.goToParentDirectory')}>
          <ArrowLeft aria-hidden="true" />
        </button>
        <FolderOpen className="object-location-icon" aria-hidden="true" />
        <div className="object-location-path">
          <button className="object-location-link" type="button" onClick={() => onNavigatePath('')} disabled={!bucket}>{bucket || t('objects.noBucketSelected')}</button>
          {prefix.trim() && prefix.split('/').filter(Boolean).map((segment, index, segments) => {
            const target = `${segments.slice(0, index + 1).join('/')}/`
            return <span className="object-location-crumb" key={target}><b>/</b><button className="object-location-link" type="button" onClick={() => onNavigatePath(target)}>{segment}</button></span>
          })}
        </div>
        <div className="object-location-actions">
          <button className="icon-button copy-path-button" type="button" onClick={() => void copyCurrentPath()} disabled={!bucket} title={t('objects.copyCurrentPath')} aria-label={t('objects.copyCurrentPath')}>
            <Copy aria-hidden="true" />
          </button>
          {viewMode !== 'versions' && <label className="deleted-toggle">
            <input key={viewMode} type="checkbox" checked={activeShowDeleted} onChange={(event) => {
              setSelectedObjectKeys(new Set())
              setSelectedDeletedIds(new Set())
              setSelectedVersionIds(new Set())
              setShowDeleted(event.target.checked)
            }} disabled={!bucket} />
            <span>{t('objects.showDeletedObjects')}</span>
          </label>}
          {viewMode === 'current' && !showDeleted && <button className="secondary-button create-path-button" type="button" onClick={() => { setPathName(''); setShowCreatePath(true) }} disabled={!bucket || !accessKey}>
            <FolderPlus className="button-icon" aria-hidden="true" />{t('objects.createNewPath')}</button>}
        </div>
      </div>

      {selectedCount > 0 && (
        <div className="selection-toolbar" role="toolbar" aria-label={t('objects.bulkObjectActions')}>
          <strong>{t('objects.selected')} {selectedCount} {t('objects.objects')}</strong>
          <div className="selection-toolbar-actions">
            {selectedFiles.length > 0 && <>
              <button className="secondary-button" type="button" onClick={() => void downloadSelected()} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />{t('objects.download')}</button>
              <button className="secondary-button" type="button" onClick={() => openTransfer('copy')} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />{t('objects.copy')}</button>
            </>}
            {selectedData.length > 0 && <button className="secondary-button" type="button" onClick={() => openTransfer('move')} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />{t('objects.move')}</button>}
            {selectedDeleted.length > 0 && <button className="secondary-button" type="button" onClick={() => void restoreSelected()} disabled={!accessKey}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restore')}</button>}
            <button className="danger-button" type="button" onClick={() => void removeSelected()} disabled={!accessKey}><Trash2 className="button-icon" aria-hidden="true" />{permanentDeleteOnly ? t('objects.permanentlyDelete') : t('objects.delete')}</button>
            <button className="icon-button" type="button" onClick={() => { setSelectedObjectKeys(new Set()); setSelectedDeletedIds(new Set()); setSelectedVersionIds(new Set()) }} title={t('objects.clearSelection')} aria-label={t('objects.clearSelection')}><X aria-hidden="true" /></button>
          </div>
        </div>
      )}

      <section className="panel table-panel">
        <div className="table-wrap">
          {viewMode === 'current' ? <table className={`object-table${showDeleted ? ' deleted-object-table' : ''}`}>
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allCurrentSelected} onChange={(event) => toggleAllCurrent(event.target.checked)} aria-label={t('objects.selectAllObjects')} /></th><th className="object-column-title">{t('objects.object')}</th>{showDeleted && <th>{t('objects.status')}</th>}<th>{t('objects.size')}</th><th>{t('objects.lastModified')}</th><th className="sticky-actions-column">{t('objects.actions')}</th></tr></thead>
            <tbody>{!showDeleted && filteredObjects.map((object) => (
                <tr key={object.key}>
                  <td className="selection-column"><input type="checkbox" checked={selectedObjectKeys.has(object.key)} onChange={(event) => toggleObjectSelection(object.key, event.target.checked)} aria-label={t('objects.selectValue', { '0': object.key })} /></td>
                  <td className="object-key"><div className="file-cell object-tree-cell object-key-trigger" role="button" tabIndex={0} onClick={() => openObject(object)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openObject(object) } }} title={isDirectoryKey(object.key) ? t('objects.openDirectory') : t('objects.viewObjectDetails')}><ObjectTreeIndent depth={objectTreeDepth(object.key, prefix)} />{isDirectoryKey(object.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(object.key, prefix)}</span>{object.legal_hold && <span className="status-badge locked">{t('objects.legalHold')}</span>}{object.retention_until_unix_seconds && <span className="status-badge locked">{object.retention_mode ?? t('objects.retention')} {t('objects.until')} {new Date(object.retention_until_unix_seconds * 1000).toLocaleDateString(getFormatLocale())}</span>}</div></td>
                  <td>{isDirectoryKey(object.key) ? (() => {
                    const summary = directorySizeSummaries.get(object.key)
                    const calculating = directorySizeLoading.has(object.key)
                    return <div className="directory-size-cell" title={summary ? t('objects.generatedAtValue', { '0': new Date(summary.generatedAt).toLocaleString(getFormatLocale()) }) : t('objects.calculateFileSizesInThisDirectoryAndItsSubdirectories')}>
                      <span>{summary ? formatBytes(summary.bytes) : t('objects.notCalculated')}</span>
                      <button className="icon-button directory-size-refresh" type="button" onClick={() => void refreshDirectorySize(object.key)} disabled={calculating} aria-label={t('objects.refreshSizeOfDirectoryValue', { '0': displayObjectKey(object.key, prefix) })} title={t('objects.refreshDirectorySize')}><RefreshCw className={calculating ? 'spinning' : ''} aria-hidden="true" /></button>
                    </div>
                  })() : formatBytes(object.size)}</td>
                  <td>{object.last_modified ? new Date(object.last_modified).toLocaleString(getFormatLocale()) : '-'}</td>
                  <td className="table-actions sticky-actions-column">
                    <ActionMenu label={`${isDirectoryKey(object.key) ? t('objects.manageDirectory') : t('objects.manage')} ${displayKeyForMessage(object.key)}`}>
                      {!isDirectoryKey(object.key) && <button type="button" role="menuitem" onClick={() => void download(object)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />{t('objects.download')}</button>}
                      {!isDirectoryKey(object.key) && <button type="button" role="menuitem" onClick={() => openTransfer('copy', { kind: 'current', object })} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />{t('objects.copy')}</button>}
                      <button type="button" role="menuitem" onClick={() => openTransfer('move', { kind: 'current', object })} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />{t('objects.move')}</button>
                      <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeObject(object)} disabled={!accessKey || deletingKey === object.key || (isDirectoryKey(object.key) && objects.some((item) => item.key !== object.key && item.key.startsWith(object.key)))}><Trash2 className="button-icon" aria-hidden="true" />{isDirectoryKey(object.key) ? t('objects.deleteDirectory') : t('objects.delete')}</button>
                    </ActionMenu>
                  </td>
                </tr>
              ))}
              {showDeleted && filteredDeletedObjects.map((version) => {
                const identity = `${version.key}\u0000${version.version_id}`
                const restoring = restoringVersion === identity
                return <tr key={identity} className="delete-marker-row">
                  <td className="selection-column"><input type="checkbox" checked={selectedDeletedIds.has(identity)} onChange={(event) => toggleDeletedSelection(version, event.target.checked)} aria-label={t('objects.selectDeletedObjectValue', { '0': version.key })} /></td>
                  <td className="object-key"><div className="file-cell object-tree-cell"><ObjectTreeIndent depth={objectTreeDepth(version.key, prefix)} /><Trash2 className="file-symbol" aria-hidden="true" /><span>{displayObjectKey(version.key, prefix)}</span></div></td>
                  <td><span className="status-badge delete-marker">{t('objects.deleted')}</span></td>
                  <td>{deletedObjectSizes.has(version.key) ? formatBytes(deletedObjectSizes.get(version.key)!) : '-'}</td>
                  <td>{new Date(version.last_modified).toLocaleString(getFormatLocale())}</td>
                  <td className="table-actions sticky-actions-column">
                    <ActionMenu label={t('objects.manageDeletedObjectValue', { '0': version.key })}>
                      <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restoreObjects')}</button>
                      <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={!accessKey || deletingVersion === identity}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>
                    </ActionMenu>
                  </td>
                </tr>
              })}</tbody>
          </table> : <table className="object-table version-table">
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allVersionsSelected} onChange={(event) => toggleAllVersions(event.target.checked)} aria-label={t('objects.selectAllObjectVersions')} /></th><th className="object-column-title">{t('objects.object')}</th><th>{t('objects.state')}</th><th>{t('objects.size')}</th><th>{t('objects.lastModified')}</th><th className="sticky-actions-column">{t('objects.actions')}</th></tr></thead>
            <tbody>{filteredVersions.map((version) => {
              const identity = `${version.key}\u0000${version.version_id}`
              const restoring = restoringVersion === identity
              const objectDeleted = deletedObjectKeys.has(version.key)
              return <tr key={identity} className={version.is_delete_marker ? 'delete-marker-row' : ''}>
                <td className="selection-column"><input type="checkbox" checked={selectedVersionIds.has(identity)} onChange={(event) => toggleVersionSelection(version, event.target.checked)} aria-label={t('objects.selectVersionOfValue', { '0': version.key })} /></td>
                <td className="object-key"><div className="file-cell object-tree-cell"><ObjectTreeIndent depth={objectTreeDepth(version.key, prefix)} />{version.is_delete_marker ? <Trash2 className="file-symbol" aria-hidden="true" /> : isDirectoryKey(version.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(version.key, prefix)}</span></div></td>
                <td><div className="version-badges">{version.is_latest && <span className="status-badge latest">{t('objects.latest')}</span>}{version.is_delete_marker && <span className="status-badge delete-marker">{t('objects.deletemarker')}</span>}{!version.is_latest && !version.is_delete_marker && <span className="status-badge">{t('objects.previous')}</span>}{version.legal_hold && <span className="status-badge locked">{t('objects.legalHold')}</span>}{version.retention_until_unix_seconds && <span className="status-badge locked">{version.retention_mode ?? t('objects.retention')} {t('objects.until')} {new Date(version.retention_until_unix_seconds * 1000).toLocaleDateString(getFormatLocale())}</span>}</div></td>
                <td>{version.is_delete_marker
                  ? (deletedVersionSizes.has(version.key) ? formatBytes(deletedVersionSizes.get(version.key)!) : '-')
                  : isDirectoryKey(version.key) ? '-' : formatBytes(version.size)}</td>
                <td>{new Date(version.last_modified).toLocaleString(getFormatLocale())}</td>
                <td className="table-actions sticky-actions-column">
                  <ActionMenu label={t('objects.manageVersionValueOfValue', { '0': version.key, '1': shortVersionId(version.version_id) })}>
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => void openVersionTagDetail(version)} disabled={!accessKey}>{t('objects.editObjectTags')}</button>}
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => void downloadVersion(version)} disabled={!accessKey}><Download className="button-icon" aria-hidden="true" />{t('objects.download')}</button>}
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => openTransfer('copy', { kind: 'version', version })} disabled={!accessKey}><Copy className="button-icon" aria-hidden="true" />{t('objects.copy')}</button>}
                    {!version.is_delete_marker && <button type="button" role="menuitem" onClick={() => openTransfer('move', { kind: 'version', version })} disabled={!accessKey}><FolderInput className="button-icon" aria-hidden="true" />{t('objects.move')}</button>}
                    {version.is_delete_marker && version.is_latest && <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restoreObjects')}</button>}
                    {!version.is_delete_marker && !version.is_latest && <button type="button" role="menuitem" onClick={() => void rewindVersion(version)} disabled={!accessKey || restoring}><History className="button-icon" aria-hidden="true" />{t('objects.rewindToThisVersion')}</button>}
                    {!version.is_delete_marker && !version.is_latest && objectDeleted && <button type="button" role="menuitem" onClick={() => void restoreVersion(version)} disabled={!accessKey || restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restore')}</button>}
                    {version.is_delete_marker
                      ? <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={!accessKey || deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>
                      : <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeVersion(version)} disabled={!accessKey || deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>}
                  </ActionMenu>
                </td>
              </tr>
            })}</tbody>
          </table>}
        </div>
        {viewMode === 'current' && (showDeleted ? filteredDeletedObjects.length === 0 : filteredObjects.length === 0) && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? t('objects.noMatchingObjects') : showDeleted ? t('objects.noDeletedObjects') : t('objects.thisBucketIsEmpty')}</strong><span>{normalizedSearchQuery ? t('objects.noObjectKeysMatchYourSearch') : showDeleted ? t('objects.noDeleteMarkersInThisPath') : t('objects.uploadFilesToSeeObjectsHere')}</span></div>}
        {viewMode === 'versions' && filteredVersions.length === 0 && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? t('objects.noMatchingVersions') : showDeleted ? t('objects.noDeleteMarkers') : t('objects.noObjectVersions')}</strong><span>{normalizedSearchQuery ? t('objects.noObjectKeysMatchYourSearch') : showDeleted ? t('objects.noDeleteMarkersAreAvailable') : t('objects.enableVersioningToTrackNewWritesAndDeletesHere')}</span></div>}
      </section>
      {viewMode === 'current' && !showDeleted && nextToken && <div ref={loadMoreSentinel} className="list-load-sentinel" aria-live="polite">{loading ? t('objects.loadingMore') : t('objects.scrollDownToLoadMore')}</div>}

      {uploadsPanelOpen && (
        <aside className="uploads-drawer" role="dialog" aria-modal="false" aria-labelledby="uploads-drawer-title">
          <header className="uploads-drawer-header">
            <div className="uploads-drawer-title"><List aria-hidden="true" /><div><p className="eyebrow">{t('objects.transfers')}</p><h3 id="uploads-drawer-title">{t('objects.downloadsUploads')}</h3></div></div>
            <button className="icon-button" type="button" aria-label={t('objects.closeTransferPanel')} title={t('objects.close')} onClick={() => setUploadsPanelOpen(false)}><X aria-hidden="true" /></button>
          </header>
          <div className="uploads-drawer-body" aria-live="polite">
            {uploadsLoading && <p className="uploads-drawer-status">{t('objects.syncingMultipartUploads')}</p>}
            {!uploadsLoading && uploadTasks.length === 0 && completedUploads.length === 0 && <p className="uploads-drawer-status">{t('objects.noActiveUploads')}</p>}
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
                    <div className="upload-task-title"><strong>{displayFileName(task.key)}</strong><span className={`upload-status ${task.status}`}>{task.status === 'uploading' ? t('objects.uploading') : task.status === 'completing' ? t('objects.completing') : task.status === 'failed' ? t('objects.failed') : t('objects.paused')}</span></div>
                    <span>{task.fileName} · {task.fileSize > 0 ? `${formatBytes(taskProgress.loaded)} / ${formatBytes(task.fileSize)}` : formatBytes(task.uploadedBytes)} · {task.completedParts} {t('objects.parts')}</span>
                    {task.status === 'completing' && <span>{t('objects.zigfsIsCompletingTheObject')}</span>}
                    {task.error && <span className="upload-task-error">{task.error}</span>}
                    {!task.file && task.status !== 'uploading' && <span>{t('objects.selectTheLocalFileAgain')}</span>}
                  </div>
                  <div className="upload-task-actions">
                    {task.status === 'uploading' ? (
                      <button className="secondary-button" type="button" onClick={() => pauseUpload(task)}><Pause className="button-icon" aria-hidden="true" />{t('objects.pause')}</button>
                    ) : task.status === 'completing' ? (
                      <button className="secondary-button" type="button" disabled><RefreshCw className="button-icon spinning" aria-hidden="true" />{t('objects.completing')}</button>
                    ) : task.file ? (
                      <button className="secondary-button" type="button" disabled={uploading || !accessKey} onClick={() => void runUpload(task, task.file!)}>
                        {task.status === 'failed' ? <RotateCcw className="button-icon" aria-hidden="true" /> : <Play className="button-icon" aria-hidden="true" />}
                        {task.status === 'failed' ? t('objects.retry') : t('objects.resume')}
                      </button>
                    ) : (
                      <label className={`secondary-button file-picker-button${uploading ? ' disabled' : ''}`}>
                        <Upload className="button-icon" aria-hidden="true" />{t('objects.selectOriginalFile')}<input type="file" disabled={uploading} onChange={(event) => attachResumeFile(task, event)} />
                      </label>
                    )}
                    <button className="danger-button" type="button" disabled={task.status === 'completing' || (uploading && !active)} onClick={() => void abortUpload(task)}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.cancel')}</button>
                  </div>
                  <div
                    className="upload-progress-track"
                    role="progressbar"
                    aria-label={t('objects.uploadProgressForValue', { '0': task.fileName })}
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
                  <div className="upload-task-title"><CheckCircle2 className="upload-complete-icon" aria-hidden="true" /><strong>{displayFileName(item.key)}</strong><span className="upload-status completed">{t('objects.completed')}</span></div>
                  <span>{item.fileName} · {formatBytes(item.fileSize)} · {new Date(item.completedAt).toLocaleTimeString(getFormatLocale())}</span>
                </div>
                <strong className="upload-complete-percent">100%</strong>
                <div className="upload-progress-track" role="progressbar" aria-label={t('objects.uploadProgressForValue', { '0': item.fileName })} aria-valuemin={0} aria-valuemax={100} aria-valuenow={100}><span style={{ width: '100%' }} /></div>
              </article>
            ))}
          </div>
        </aside>
      )}

      {showCreatePath && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setShowCreatePath(false)}>
          <section className="lifecycle-modal credential-modal create-path-modal" role="dialog" aria-modal="true" aria-labelledby="create-path-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><FolderPlus aria-hidden="true" /><h3 id="create-path-dialog-title">{t('objects.createNewPath')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('objects.close')} onClick={() => setShowCreatePath(false)}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={createPath}>
              <p className="credential-modal-description">{t('objects.createADirectoryUnderTheCurrentPath')}<strong>{prefix.trim() || '/'}</strong></p>
              <div className="credential-modal-fields create-path-fields">
                <label>{t('objects.directoryName')}<input aria-label={t('objects.directoryName')} placeholder={t('objects.forExampleImages')} value={pathName} onChange={(event) => setPathName(event.target.value)} required autoFocus /></label>
              </div>
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setShowCreatePath(false)}>{t('objects.cancel')}</button>
                <button className="primary-button" type="submit">{t('objects.createPath')}</button>
              </footer>
            </form>
          </section>
        </div>
      )}

      {transferDialog && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => { if (!transferring) setTransferDialog(null) }}>
          <section className="lifecycle-modal credential-modal transfer-modal" role="dialog" aria-modal="true" aria-labelledby="transfer-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><TransferIcon aria-hidden="true" /><h3 id="transfer-dialog-title">{transferDialog.mode === 'copy' ? t('objects.copyObjects') : t('objects.moveObjects')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('objects.close')} onClick={() => { if (!transferring) setTransferDialog(null) }}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={submitTransfer}>
              <p className="credential-modal-description">{t('objects.selected')} {transferDialog.items.length} {t('objects.itemsEnterTheDestinationParentPathFileNamesAnd')}</p>
              <div className="credential-modal-fields transfer-fields">
                <label>{t('objects.destinationBucket')}<select value={transferBucket} onChange={(event) => { setTransferBucket(event.target.value); setTransferPath(''); setTransferTreeOpen(false) }} required disabled={transferring}>
                    <option value="" disabled>{t('objects.selectBucket')}</option>
                    {buckets.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
                  </select>
                </label>
                <label className="transfer-tree-field">{t('objects.destinationPath')}<button className="transfer-tree-trigger" type="button" onClick={() => setTransferTreeOpen((open) => !open)} disabled={transferring} aria-haspopup="listbox" aria-expanded={transferTreeOpen}>
                    {transferPath ? `${transferBucket}/${transferPath.replace(/\/+$/, '')}` : t('objects.valueRoot', { '0': transferBucket || t('objects.bucket') })}
                    <span aria-hidden="true">⌄</span>
                  </button>
                  {transferTreeOpen && <div className="transfer-tree-menu" role="listbox">
                    <button type="button" role="option" aria-selected={!transferPath} onClick={() => { setTransferPath(''); setTransferTreeOpen(false) }}>⌂ <span>{t('objects.rootDirectory')}</span></button>
                    {transferDirectories.map((directory) => {
                      const value = directory.replace(/\/+$/, '')
                      const depth = value ? value.split('/').length - 1 : 0
                      return <button key={directory} type="button" role="option" aria-selected={transferPath === value} style={{ paddingLeft: `${14 + depth * 18}px` }} onClick={() => { setTransferPath(value); setTransferTreeOpen(false) }}><Folder className="button-icon" aria-hidden="true" /><span>{value.split('/').pop() || value}</span></button>
                    })}
                  </div>}
                </label>
              </div>
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setTransferDialog(null)} disabled={transferring}>{t('objects.cancel')}</button>
                <button className="primary-button" type="submit" disabled={transferring || !transferBucket}>{transferring ? t('objects.processing') : transferDialog.mode === 'copy' ? t('objects.startCopy') : t('objects.startMove')}</button>
              </footer>
            </form>
          </section>
        </div>
      )}

      {detail && (
        <div className="drawer-backdrop" role="presentation" onClick={closeDetail}>
          <aside className="detail-drawer" role="dialog" aria-modal="true" aria-label={t('objects.objectDetails')} onClick={(event) => event.stopPropagation()}>
            <header className="drawer-header">
              <div><p className="eyebrow">{t('objects.objectDetails')}</p><h3>{detail.key}</h3></div>
              <button className="icon-button" type="button" aria-label={t('objects.closeDetails')} onClick={closeDetail}><X aria-hidden="true" /></button>
            </header>
            <div className="preview-frame">
              {isImageKey(detail.key) && detailUrl ? <img src={detailUrl.url} alt={detail.key} /> : <div className="format-icon" aria-label={t('objects.valueFile', { '0': fileExtension(detail.key) })}>{fileExtension(detail.key)}</div>}
              {!isImageKey(detail.key) && <span>{t('objects.previewIsNotAvailableForThisFormat')}</span>}
            </div>
            <dl className="detail-list">
              <div><dt>{t('objects.objectKey')}</dt><dd>{detail.key}</dd></div>
              <div><dt>{t('objects.format')}</dt><dd>{fileExtension(detail.key)}</dd></div>
              <div><dt>{t('objects.size')}</dt><dd>{formatBytes(detail.size)}</dd></div>
              <div><dt>ETag</dt><dd><code>{detail.etag}</code></dd></div>
              <div><dt>{t('objects.modified')}</dt><dd>{new Date(detail.last_modified).toLocaleString(getFormatLocale())}</dd></div>
              {detailUrl && <div><dt>{t('objects.linkExpires')}</dt><dd>{new Date(detailUrl.expires_at).toLocaleString(getFormatLocale())}</dd></div>}
            </dl>
            <label className="detail-tags-editor">{t('objects.objectTagsJson')}<textarea value={detailTags} onChange={(event) => setDetailTags(event.target.value)} rows={5} placeholder={'{\n  "team": "blue"\n}'} />
              <button className="primary-button" type="button" onClick={() => void saveDetailTags()} disabled={detailTagsSaving}>{detailTagsSaving ? t('objects.saving') : t('objects.saveTags')}</button>
            </label>
            {detailUrl && <div className="drawer-actions"><a className="secondary-button" href={detailUrl.url} target="_blank" rel="noreferrer"><ExternalLink className="button-icon" aria-hidden="true" />{t('objects.openPreviewLink')}</a><button className="secondary-button" type="button" onClick={() => void copyDetailUrl()}><Copy className="button-icon" aria-hidden="true" />{t('objects.copyLink')}</button></div>}
          </aside>
        </div>
      )}
    </section>
  )
}

function abortError() {
  const error = new Error(t('objects.uploadPaused'))
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

function escapeXml(value: string) {
  return value.replace(/[<>&'\"]/g, (character) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[character] ?? character))
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
