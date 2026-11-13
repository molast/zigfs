import { ObjectDetailsSheet } from './ObjectDetailsSheet'
import { formatDate, formatDateTime } from '@/lib/dateTime'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '../../components/ui/Tabs'
import { Progress } from '../../components/ui/progress'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '../../components/ui/sheet'
import { Empty, EmptyHeader, EmptyMedia, EmptyTitle, EmptyDescription } from '../../components/ui/empty'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '../../components/ui/Dialog'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '../../components/ui/field'
import { Input } from '../../components/ui/Input'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from '../../components/ui/table'
import { Button } from '../../components/ui/Button'
import { RadioGroup, RadioGroupItem } from '../../components/ui/radio-group'
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem, DropdownMenuGroup } from '../../components/ui/dropdown-menu'
import { EllipsisVertical } from 'lucide-react'
import { OptionSelect } from '../../components/ui/OptionSelect'
import { t } from '@/locales'
import { type ChangeEvent, type FormEvent, useEffect, useRef, useState } from 'react'
import {
  CheckCircle2,
  CloudUpload,
  Copy,
  Download,
  File,
  Folder,
  FolderInput,
  FolderPlus,
  History,
  List,
  Pause,
  Pencil,
  Ellipsis,
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
import { ToolbarSearch } from '../../components/ui/ToolbarControls'
import type { Bucket, MultipartUpload, MultipartUploadSummary, ObjectSummary, ObjectVersion } from '../../types/api'
import {
  choosePartSize,
  chooseUploadConcurrency,
  formatBytes,
  formatUploadProgress,
  inferPartSize,
  loadPersistedTasks,
  persistTasks,
  putPart,
  validateResumeFile,
  uploadPartsConcurrently,
  type UploadTask,
} from './multipart-upload'

interface ObjectsViewProps {
  api: ApiClient
  initialBucket?: string
  initialPrefix?: string
  onNavigatePath: (prefix: string) => void
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
  initiatedAt: string
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

export function ObjectsView({ api, initialBucket = '', initialPrefix = '', onNavigatePath }: ObjectsViewProps) {
  const confirm = useConfirm()
  const { startLoading, withLoading } = useLoading()
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [, setBucketInfo] = useState<Bucket | null>(null)
  const bucket = initialBucket
  const [prefix, setPrefix] = useState(initialPrefix)
  const [searchQuery, setSearchQuery] = useState('')
  const [viewMode, setViewMode] = useState<'current' | 'versions'>('current')
  const [onlyDeleted, setOnlyDeleted] = useState(false)
  const [localFilter, setLocalFilter] = useState('')
  const [sortField, setSortField] = useState<'key' | 'size' | 'last_modified'>('key')
  const [sortDirection, setSortDirection] = useState(1)
  const [uploadDialogOpen, setUploadDialogOpen] = useState(false)
  const [pendingFiles, setPendingFiles] = useState<File[]>([])
  const [uploadSubdirectory, setUploadSubdirectory] = useState('')
  const [startingUploads, setStartingUploads] = useState(false)
  const folderInput = useRef<HTMLInputElement>(null)
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
  const [taskTab, setTaskTab] = useState<string | null>(null)
  const [cancelledUploads, setCancelledUploads] = useState<{ uploadId: string; key: string; fileSize: number; initiatedAt: string }[]>([])
  const [deleteTasks, setDeleteTasks] = useState<{ id: string; key: string; directory: boolean; initiatedAt: string; status: 'processing' | 'completed' | 'failed'; error?: string }[]>([])
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
  const [renameObject, setRenameObject] = useState<ObjectSummary | null>(null)
  const [renameName, setRenameName] = useState('')
  const [renaming, setRenaming] = useState(false)
  const [transferDialog, setTransferDialog] = useState<TransferDialogState | null>(null)
  const [transferBucket, setTransferBucket] = useState(bucket)
  const [transferPath, setTransferPath] = useState('')
  const [transferDirectories, setTransferDirectories] = useState<string[]>([])
  const [transferTreeOpen, setTransferTreeOpen] = useState(false)
  const [transferring, setTransferring] = useState(false)
  const [detail, setDetail] = useState<ObjectSummary | null>(null)
  const [detailVersionId, setDetailVersionId] = useState<string | null>(null)
  const [directorySizeSummaries, setDirectorySizeSummaries] = useState<Map<string, FolderSizeSummary>>(new Map())
  const [directorySizeLoading, setDirectorySizeLoading] = useState<Set<string>>(new Set())
  const [uploadSpeed, setUploadSpeed] = useState(0)
  const fileInput = useRef<HTMLInputElement>(null)
  const uploadControl = useRef<{
    uploadId: string
    paused: boolean
    cancelled: boolean
    completing: boolean
    stopped: boolean
    requests: Set<XMLHttpRequest>
  } | null>(null)
  const uploadsHydrated = useRef(false)
  const routeLocation = useRef({ bucket: initialBucket, prefix: initialPrefix })
  const bucketInfoLoaded = useRef('')
  const multipartSyncBucket = useRef('')
  const initialLoadKey = useRef('')
  const listRequestId = useRef(0)
  const listLoading = useRef(false)
  const loadMoreSentinel = useRef<HTMLDivElement>(null)
  const visibleVersions = showDeletedVersions
    ? versions.filter((version) => !isDirectoryKey(version.key) && version.is_delete_marker && version.is_latest)
    : versions.filter((version) => !isDirectoryKey(version.key) && !version.is_delete_marker)
  const normalizedSearchQuery = localFilter.trim().toLocaleLowerCase()
  const filteredObjects = [...objects].filter(item => item.key.toLocaleLowerCase().includes(normalizedSearchQuery)).sort((a, b) => Number(isDirectoryKey(b.key)) - Number(isDirectoryKey(a.key)) || sortDirection * (sortField === 'size' ? (a.size ?? 0) - (b.size ?? 0) : sortField === 'last_modified' ? Date.parse(a.last_modified) - Date.parse(b.last_modified) : a.key.localeCompare(b.key)))
  const filteredDeletedObjects = [...deletedObjects].filter(item => item.key.toLocaleLowerCase().includes(normalizedSearchQuery)).sort((a, b) => Number(isDirectoryKey(b.key)) - Number(isDirectoryKey(a.key)) || sortDirection * (sortField === 'size' ? (a.size ?? 0) - (b.size ?? 0) : sortField === 'last_modified' ? Date.parse(a.last_modified) - Date.parse(b.last_modified) : a.key.localeCompare(b.key)))
  const filteredVersions = [...visibleVersions].filter(item => item.key.toLocaleLowerCase().includes(normalizedSearchQuery)).sort((a, b) => Number(isDirectoryKey(b.key)) - Number(isDirectoryKey(a.key)) || sortDirection * (sortField === 'size' ? (a.size ?? 0) - (b.size ?? 0) : sortField === 'last_modified' ? Date.parse(a.last_modified) - Date.parse(b.last_modified) : a.key.localeCompare(b.key)))


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
        setObjects(hideCurrentDirectoryMarker(history.filter(item => item.is_latest && !item.is_delete_marker).map(item => ({ ...item, etag: '' })), currentPrefix))
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
      setLocalFilter('')
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
      uploadControl.current.requests.forEach(request => request.abort())
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
    if (selected.length === 0) return
    const next = new Map(pendingFiles.map(file => [file.webkitRelativePath || file.name, file]))
    for (const file of selected) next.set(file.webkitRelativePath || file.name, file)
    if (next.size > 10000) { notifyError(t('objects.uploadQueueLimit')); return }
    setPendingFiles([...next.values()])
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
      if (onlyDeleted) return
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
    return [
      ...(!onlyDeleted || !showDeleted ? filteredObjects.filter(object => selectedObjectKeys.has(object.key)).map(object => ({ kind: 'current' as const, object })) : []),
      ...(showDeleted ? filteredDeletedObjects.filter(version => selectedDeletedIds.has(versionIdentity(version))).map(version => ({ kind: 'version' as const, version })) : []),
    ]
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

  async function startPendingUploads() {
    if (startingUploads || uploading || !pendingFiles.length) return
    const directory = uploadSubdirectory.trim().replace(/^\/+|\/+$/g, '')
    if (directory.split('/').some(segment => segment === '.' || segment === '..') || directory.includes('\\')) {
      notifyError(t('objects.invalidUploadDirectory'))
      return
    }
    setStartingUploads(true)
    try { await beginUploads([...pendingFiles], directory) }
    finally { setStartingUploads(false) }
  }

  async function beginUploads(files: File[], destinationPrefix: string) {
    if (!bucket || files.length === 0) return

    const tasks: UploadTask[] = []
    const failures: string[] = []
    const failedFiles: File[] = []
    for (const file of files) {
      const key = joinObjectPath(destinationPrefix, file.webkitRelativePath || file.name)
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
        failedFiles.push(file)
        failures.push(`${file.name}: ${(reason as Error).message}`)
      }
    }
    setPendingFiles(failedFiles)
    if (failedFiles.length === 0) { setUploadDialogOpen(false); setTaskTab(null); setUploadsPanelOpen(true) }
    if (tasks.length > 0) setUploadTasks((current) => [...tasks, ...current])
    if (failures.length > 0) notifyError(t('objects.unableToCreateUploadsForValue', { '0': failures.join('；') }))
    for (const task of tasks) {
      if (task.file) await runUpload(task, task.file)
    }
  }

  async function createPath(event: FormEvent) {
    event.preventDefault()
    const name = pathName.trim().replace(/^\/+|\/+$/g, '')
    if (!name || !bucket) return
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
    if (uploadControl.current) return
    const control = {
      uploadId: task.uploadId,
      paused: false,
      cancelled: false,
      completing: false,
      stopped: false,
      requests: new Set<XMLHttpRequest>(),
    }
    uploadControl.current = control
    setUploadSpeed(0)
    let transferredBytes = 0
    const speedSamples = [{ time: performance.now(), bytes: 0 }]
    // A rolling three-second average smooths progress events across parts.
    // Sample even without progress so a stalled transfer falls back to zero.
    const speedTimer = window.setInterval(() => {
      const now = performance.now()
      speedSamples.push({ time: now, bytes: transferredBytes })
      while (speedSamples.length > 2 && speedSamples[1].time <= now - 3000) speedSamples.shift()
      const first = speedSamples[0]
      setUploadSpeed(Math.round((transferredBytes - first.bytes) * 1000 / Math.max(1, now - first.time)))
    }, 1000)
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

      const inFlight = new Map<number, number>()
      const reportProgress = () => {
        const totalLoaded = Math.min(selectedFile.size, committedBytes + [...inFlight.values()].reduce((sum, bytes) => sum + bytes, 0))
        reportUploadProgress(totalLoaded, selectedFile.size)
        updateUploadTask(task.uploadId, { uploadedBytes: totalLoaded, completedParts: committedParts })
      }
      const pendingParts = Array.from({ length: partCount }, (_, index) => index + 1).filter(number => !completed.has(number))
      await uploadPartsConcurrently(pendingParts, chooseUploadConcurrency(partSize), async (partNumber) => {
        if (control.paused || control.stopped) throw abortError()
        const start = (partNumber - 1) * partSize
        const body = selectedFile.slice(start, Math.min(start + partSize, selectedFile.size))
        let etag = ''
        let lastError: Error | null = null
        for (let attempt = 1; attempt <= 3; attempt += 1) {
          if (control.paused || control.stopped) throw abortError()
          let activeRequest: XMLHttpRequest | undefined
          try {
            const presigned = await api.presignObject('', task.bucket, task.key, 'PUT', 900, {
              uploadId: task.uploadId,
              partNumber,
            })
            if (control.paused || control.stopped) throw abortError()
            let attemptLoaded = 0
            etag = await putPart(
              presigned.url,
              body,
              task.contentType,
              ({ loaded }) => {
                transferredBytes += Math.max(0, loaded - attemptLoaded)
                attemptLoaded = loaded
                inFlight.set(partNumber, loaded)
                reportProgress()
              },
              (request) => {
                activeRequest = request
                control.requests.add(request)
              },
            )
            break
          } catch (reason) {
            inFlight.delete(partNumber)
            reportProgress()
            if (control.paused || control.stopped || (reason instanceof Error && reason.name === 'AbortError')) throw abortError()
            lastError = reason as Error
            if (attempt < 3) await delay(attempt * 300)
          } finally {
            if (activeRequest) control.requests.delete(activeRequest)
          }
        }
        if (!etag) throw lastError ?? new Error(t('objects.partValueFailedToUpload', { '0': partNumber }))
        completed.set(partNumber, {
          part_number: partNumber,
          size: body.size,
          etag,
          last_modified: new Date().toISOString(),
        })
        inFlight.delete(partNumber)
        committedBytes += body.size
        committedParts = completed.size
        reportProgress()
      }, () => {
        control.stopped = true
        control.requests.forEach(request => request.abort())
      })
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
          initiatedAt: task.initiatedAt,
          completedAt: new Date().toISOString(),
        },
        ...current,
      ])
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
        updateUploadTask(task.uploadId, { uploadedBytes: committedBytes, completedParts: committedParts, status: 'failed', error: message })
        notifyError(message)
      }
    } finally {
      window.clearInterval(speedTimer)
      setUploadSpeed(0)
      if (uploadControl.current === control) uploadControl.current = null
      setUploading(false)
      setUploadProgress(null)
    }
  }

  function pauseUpload(task: UploadTask) {
    const control = uploadControl.current
    if (!control || control.uploadId !== task.uploadId || control.completing) return
    control.paused = true
    control.requests.forEach(request => request.abort())
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
      control.requests.forEach(request => request.abort())
    }
    const stopLoading = startLoading(t('objects.cancellingMultipartUpload'))
    try {
      await api.abortMultipartUpload(task.uploadId, task.bucket, task.key)
      setUploadTasks((current) => current.filter((item) => item.uploadId !== task.uploadId))
      setCancelledUploads(current => [...current.filter(item => item.uploadId !== task.uploadId), { uploadId: task.uploadId, key: task.key, fileSize: task.fileSize, initiatedAt: task.initiatedAt }])
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

  function startBrowserDownload(url: string, key: string) {
    // Content-Disposition on the signed S3 response also works across origins.
    // The browser owns the transfer; never buffer the object with fetch/blob.
    const link = document.createElement('a')
    link.href = url
    link.download = key.split('/').pop() || key
    link.target = '_blank'
    link.rel = 'noopener noreferrer'
    document.body.appendChild(link)
    link.click()
    link.remove()
  }

  async function download(object: ObjectSummary) {
    if (!bucket) return false
    try {
      const presigned = await api.presignObject('', bucket, object.key, 'GET', 900, { download: true })
      startBrowserDownload(presigned.url, object.key)
      showToast(t('objects.downloadStartedValue', { '0': displayFileName(object.key) }))
      return true
    } catch (reason) {
      notifyError((reason as Error).message)
      return false
    }
  }

  async function downloadVersion(version: ObjectVersion) {
    if (!bucket || version.is_delete_marker) return false
    try {
      const presigned = await api.presignObject('', bucket, version.key, 'GET', 900, { versionId: version.version_id, download: true })
      startBrowserDownload(presigned.url, version.key)
      showToast(t('objects.downloadStartedValue', { '0': displayFileName(version.key) }))
      return true
    } catch (reason) {
      notifyError((reason as Error).message)
      return false
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
    if (!bucket) return
    if (destinationBucket === bucket && destinationKey === sourceKey) {
      throw new Error(t('objects.destinationMatchesTheSourceValue', { '0': displayKeyForMessage(sourceKey) }))
    }
    const presigned = await api.presignObject('', destinationBucket, destinationKey, 'PUT', 900, {
      copySource: { bucket, key: sourceKey, ...(versionId ? { versionId } : {}) },
    })
    const response = await fetch(presigned.url, {
      method: 'PUT',
      headers: presigned.required_headers,
    })
    if (!response.ok) throw new Error(t('objects.failedToCopyValueValue', { '0': displayKeyForMessage(sourceKey), '1': response.status }))
  }

  async function trackDeletion(key: string, directory: boolean, operation: () => Promise<void>) {
    const id = crypto.randomUUID()
    setDeleteTasks(current => [...current, { id, key, directory, initiatedAt: new Date().toISOString(), status: 'processing' }])
    try {
      await operation()
      setDeleteTasks(current => current.map(task => task.id === id ? { ...task, status: 'completed' } : task))
      setTaskTab('completed')
      setUploadsPanelOpen(true)
    } catch (reason) {
      setDeleteTasks(current => current.map(task => task.id === id ? { ...task, status: 'failed', error: (reason as Error).message } : task))
      throw reason
    }
  }

  async function deleteObjectKey(key: string, versionId?: string) {
    if (!bucket) return
    const presigned = await api.presignObject('', bucket, key, 'DELETE', 900, versionId ? { versionId } : undefined)
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
    // Directory deletion is handled by the prefix delete operation. It is
    // valid for a directory to contain objects at any depth.
    return true
  }

  async function deleteItem(item: SelectedObject) {
    if (!bucket) return
    if (item.kind === 'current') {
      if (isDirectoryKey(item.object.key)) {
        await deleteDirectory(item.object.key)
        return
      }
      const presigned = await api.presignObject('', bucket, item.object.key, 'DELETE', 900)
      const response = await fetch(presigned.url, { method: 'DELETE' })
      if (!response.ok) throw new Error(t('objects.failedToDeleteValueValue', { '0': displayKeyForMessage(item.object.key), '1': response.status }))
      return
    }
    const presigned = await api.presignObject('', bucket, item.version.key, 'DELETE', 900, { versionId: item.version.version_id })
    const response = await fetch(presigned.url, { method: 'DELETE' })
    if (!response.ok) throw new Error(t('objects.failedToDeleteVersionValueValue', { '0': shortVersionId(item.version.version_id), '1': response.status }))
  }

  async function purgeObject(key: string) {
    if (!bucket) return
    // Deleting a version rewrites the metadata history. Re-read after every
    // pass so a large history cannot leave a stale marker behind.
    for (;;) {
      const history = await api.listObjectVersions(bucket, key)
      const exactVersions = history.filter((version) => version.key === key)
      if (exactVersions.length === 0) return
      // Delete one version per read. The metadata generation changes after
      // every deletion, so never continue with a stale batch.
      await deleteItem({ kind: 'version', version: exactVersions[0] })
    }
  }

  async function removeDeletedObject(version: ObjectVersion) {
    if (!bucket || !version.is_delete_marker) return
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
      await trackDeletion(version.key, false, () => purgeObject(version.key))
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
      message: deleteMarkers.length > 0 && !purgingDeletedObjects && viewMode === 'current'
        ? t('objects.mixedDeleteConfirmation')
        : purgingDeletedObjects
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
        for (const key of new Set(deleteMarkers.map((item) => item.version.key))) await trackDeletion(key, false, () => purgeObject(key))
      } else {
        for (const item of items) {
          const key = item.kind === 'current' ? item.object.key : item.version.key
          await trackDeletion(key, item.kind === 'current' && isDirectoryKey(key), () =>
            viewMode === 'current' && item.kind === 'version' && item.version.is_delete_marker ? purgeObject(key) : deleteItem(item))
        }
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

  const renameSourceName = renameObject?.key.slice(renameObject.key.lastIndexOf('/') + 1) ?? ''
  const renameInvalid = !renameName.trim() || renameName === renameSourceName || renameName.includes('/') || renameName === '.' || renameName === '..'

  async function submitRename(event: FormEvent) {
    event.preventDefault()
    if (!renameObject || !bucket || renaming) return
    if (renameInvalid) { notifyError(t('objects.renameNameHint')); return }
    const sourceKey = renameObject.key
    const destinationKey = sourceKey.slice(0, sourceKey.lastIndexOf('/') + 1) + renameName
    if (new TextEncoder().encode(destinationKey).length > 1024) { notifyError(t('objects.renameKeyTooLong')); return }
    setRenaming(true)
    let copied = false
    try {
      const existing = await api.listObjects(bucket, destinationKey, '', '', 1)
      if (existing.items.some(item => item.key === destinationKey)) {
        notifyError(t('objects.renameTargetExists'))
        return
      }
      await copyObjectKey(sourceKey, bucket, destinationKey)
      copied = true
      await deleteObjectKey(sourceKey)
      setRenameObject(null)
      setSelectedObjectKeys(current => new Set([...current].filter(key => key !== sourceKey)))
      if (detail?.key === sourceKey) closeDetail()
      showToast(t('objects.renamedObject', { name: renameName }))
      await load(true)
    } catch (reason) {
      notifyError(copied
        ? t('objects.renameDeleteFailed', { name: renameName, error: (reason as Error).message })
        : (reason as Error).message)
      if (copied) await load(true)
    } finally {
      setRenaming(false)
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

  function openDetail(object: ObjectSummary) {
    setDetail(object)
    setDetailVersionId(null)
  }

  function openVersionTagDetail(version: ObjectVersion) {
    setDetail({ ...version, etag: '' })
    setDetailVersionId(version.version_id)
  }

  function closeDetail() {
    setDetail(null)
    setDetailVersionId(null)
  }

  async function forceCleanupFolder(object: ObjectSummary) {
    if (!bucket || !isDirectoryKey(object.key) || deletingKey) return
    const folderPrefix = object.key.endsWith('/') ? object.key : `${object.key}/`
    if (!await confirm({
      title: t('objects.forceCleanupFolder'),
      message: t('objects.forceCleanupFolderDescription'),
      details: `${bucket}/${folderPrefix}`,
      confirmLabel: t('objects.forceCleanupFolder'),
    })) return
    const stopLoading = startLoading(t('objects.cleaningUpFolder'))
    try {
      setDeletingKey(object.key)
      await api.forceCleanupDirectory(bucket, folderPrefix)
      showToast(t('objects.folderCleanupComplete', { name: displayDirectoryKey(object.key) }))
    } catch (reason) {
      notifyError(t('objects.folderCleanupFailed', { error: (reason as Error).message }))
    } finally {
      setDeletingKey('')
      stopLoading()
      await load(true)
    }
  }

  async function removeDirectory(object: ObjectSummary) {
    if (!bucket || !isDirectoryKey(object.key) || deletingKey) return
    let allVersions = false
    if (!await confirm({
      title: t('common.warning'),
      message: t('objects.deleteFolderConfirmation'),
      details: object.key,
      checkbox: { label: t('objects.deleteAllVersions'), onCheckedChange: checked => { allVersions = checked } },
      confirmLabel: t('common.confirm'),
    })) return
    const stopLoading = startLoading(t('objects.deletingDirectory'))
    try {
      setDeletingKey(object.key)
      await trackDeletion(object.key, true, () => api.deleteDirectory(bucket, object.key, allVersions))
      showToast(t('objects.deletedDirectoryValue', { '0': displayDirectoryKey(object.key) }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setDeletingKey('')
      stopLoading()
      await load(true)
    }
  }

  async function removeObject(object: ObjectSummary) {
    if (!bucket) return
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
      await trackDeletion(object.key, false, () => deleteObjectKey(object.key))
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
    if (!bucket) return
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
      await trackDeletion(version.key, false, () => deleteObjectKey(version.key, version.version_id))
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
    if (!bucket || !version.is_delete_marker || !version.is_latest) return
    if (!await confirm({
      title: t('objects.restoreDeletedObjects'),
      message: t('objects.removeTheLatestDeleteMarkerAndRestoreValue', { '0': version.key }),
      confirmLabel: t('objects.restoreObjects'),
    })) return
    const stopLoading = startLoading(t('objects.restoringObjects'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      const presigned = await api.presignObject('', bucket, version.key, 'DELETE', 900, { versionId: version.version_id })
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
    if (!bucket || version.is_delete_marker || version.is_latest) return
    if (!await confirm({
      title: t('objects.rewindObjectVersion'),
      message: t('objects.rewindValueToVersionValueZigfsWillCreateA', { '0': version.key, '1': shortVersionId(version.version_id) }),
      confirmLabel: t('objects.rewindVersion'),
    })) return
    const stopLoading = startLoading(t('objects.rewindingObjectVersion'))
    const identity = `${version.key}\u0000${version.version_id}`
    try {
      setRestoringVersion(identity)
      const presigned = await api.presignObject('', bucket, version.key, 'PUT', 900, {
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
    if (!bucket || version.is_delete_marker || version.is_latest) return
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
      const presigned = await api.presignObject('', bucket, version.key, 'PUT', 900, {
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

  const visibleObjectCount = viewMode === 'current' ? (showDeleted ? filteredDeletedObjects.length + (onlyDeleted ? 0 : filteredObjects.length) : filteredObjects.length) : filteredVersions.length
  const selected = selectedItems()
  const selectedDeleted = selected.filter((item): item is Extract<SelectedObject, { kind: 'version' }> => item.kind === 'version' && item.version.is_delete_marker)
  const selectedData = selected.filter((item) => item.kind === 'current' || !item.version.is_delete_marker)
  const selectedFiles = selectedData.filter((item) => !isDirectoryKey(item.kind === 'current' ? item.object.key : item.version.key))
  const selectedCount = selected.length
  const selectableVersionCount = filteredVersions.length
  const allCurrentSelected = (onlyDeleted && showDeleted ? filteredDeletedObjects.length > 0 : filteredObjects.length + (showDeleted ? filteredDeletedObjects.length : 0) > 0) && (onlyDeleted && showDeleted || filteredObjects.every(object => selectedObjectKeys.has(object.key))) && (!showDeleted || filteredDeletedObjects.every(version => selectedDeletedIds.has(versionIdentity(version))))
  const allVersionsSelected = selectableVersionCount > 0 && filteredVersions.every((version) => selectedVersionIds.has(versionIdentity(version)))
  const hasDeleteMarkerSelection = selectedDeleted.length > 0
  const permanentDeleteOnly = viewMode === 'versions' || hasDeleteMarkerSelection
  const deletedObjectKeys = new Set(
    versions.filter((version) => version.is_delete_marker && version.is_latest).map((version) => version.key),
  )
  const deletedVersionSizes = latestObjectSizes(versions)
  const TransferIcon = transferDialog?.mode === 'copy' ? Copy : FolderInput
  const taskCounts = {
    pending: uploadTasks.filter(task => task.status === 'paused').length,
    processing: uploadTasks.filter(task => task.status === 'uploading' || task.status === 'completing').length + deleteTasks.filter(task => task.status === 'processing').length,
    completed: completedUploads.length + deleteTasks.filter(task => task.status === 'completed').length,
    failed: uploadTasks.filter(task => task.status === 'failed').length + deleteTasks.filter(task => task.status === 'failed').length,
    cancelled: cancelledUploads.length,
  }
  const activeTaskTab = taskTab ?? (taskCounts.processing ? 'processing' : taskCounts.failed ? 'failed' : taskCounts.pending ? 'pending' : taskCounts.completed ? 'completed' : 'cancelled')
  const totalUploadCount = uploadTasks.length + completedUploads.length + deleteTasks.length
  const overallUploadProgress = totalUploadCount === 0 ? 0 : 100 * (
    taskCounts.completed + uploadTasks.reduce((sum, task) => {
      const loaded = uploadControl.current?.uploadId === task.uploadId && uploadProgress
        ? uploadProgress.loaded : task.uploadedBytes
      // Only completed objects count as fully uploaded, including empty files.
      return sum + (task.fileSize > 0 ? Math.min(0.99, Math.max(0, loaded / task.fileSize)) : 0)
    }, 0)
  ) / totalUploadCount
  const filteredTasks = uploadTasks.filter(task => activeTaskTab === 'processing' ? task.status === 'uploading' || task.status === 'completing' : activeTaskTab === 'pending' ? task.status === 'paused' : activeTaskTab === 'failed' && task.status === 'failed')
  const visibleTasks = [
    ...filteredTasks.map(task => ({ kind: 'upload' as const, task })),
    ...deleteTasks.filter(task => task.status === activeTaskTab).map(task => ({ kind: 'delete' as const, task })),
    ...(activeTaskTab === 'completed' ? completedUploads.map(task => ({ kind: 'completed' as const, task })) : []),
    ...(activeTaskTab === 'cancelled' ? cancelledUploads.map(task => ({ kind: 'cancelled' as const, task })) : []),
  ].sort((left, right) => Date.parse(left.task.initiatedAt) - Date.parse(right.task.initiatedAt))
  function toggleSort(field: 'key' | 'size' | 'last_modified') { setSortDirection(sortField === field ? -sortDirection : 1); setSortField(field) }

  return (
    <section className="objects-page">

      <Dialog open={uploadDialogOpen} onOpenChange={open => { if (!startingUploads) setUploadDialogOpen(open) }}>
        <DialogContent className="objects-upload-dialog" onInteractOutside={event => event.preventDefault()}>
          <DialogHeader><DialogTitle>{t('objects.uploadFiles')}</DialogTitle></DialogHeader>
          <div className="objects-upload-destination">
            <span>{t('objects.uploadTargetBucket', { bucket })}</span>
            <div className="objects-upload-pickers"><Button size="sm" variant="outline" disabled={startingUploads} onClick={() => fileInput.current?.click()}><File />{t('objects.selectFilesToUpload')}</Button><Button size="sm" variant="outline" disabled={startingUploads} onClick={() => folderInput.current?.click()}><Folder />{t('objects.uploadFolder')}</Button></div>
          </div>
          <div className="objects-upload-prefix"><label htmlFor="upload-subdirectory">{t('objects.currentPrefix')}</label><Input id="upload-subdirectory" value={uploadSubdirectory} onChange={event => setUploadSubdirectory(event.target.value)} disabled={startingUploads} placeholder={t('objects.uploadSubdirectoryPlaceholder')} aria-describedby="upload-destination-hint" />
          <p id="upload-destination-hint" className="objects-upload-help">{t('objects.uploadDestinationPath', { path: `${bucket}/${uploadSubdirectory.trim().replace(/^\/+|\/+$/g, '')}` })}</p></div>
          <p className="objects-upload-warning">{t('objects.uploadOverwriteWarning')}</p>
          <div className="objects-upload-queue">
            <div className="objects-upload-queue-header"><span>{t('objects.pendingFileCount', { count: pendingFiles.length })}</span><Button size="sm" variant="outline" disabled={startingUploads || !pendingFiles.length} onClick={() => setPendingFiles([])}><Trash2 />{t('objects.clearUploadQueue')}</Button></div>
            <div className="objects-upload-table">{pendingFiles.length > 0 ? <Table><TableHeader><TableRow><TableHead>{t('objects.object')}</TableHead><TableHead>{t('objects.size')}</TableHead><TableHead>{t('objects.actions')}</TableHead></TableRow></TableHeader><TableBody>
              {pendingFiles.map(file => <TableRow key={file.webkitRelativePath || file.name}><TableCell>{file.webkitRelativePath || file.name}</TableCell><TableCell>{formatBytes(file.size)}</TableCell><TableCell><Button size="sm" variant="ghost" disabled={startingUploads} onClick={() => setPendingFiles(current => current.filter(item => item !== file))}><Trash2 />{t('objects.delete')}</Button></TableCell></TableRow>)}
            </TableBody></Table> : <Empty className="objects-upload-empty">
              <EmptyHeader>
                <EmptyMedia><CloudUpload aria-hidden="true" /></EmptyMedia>
                <EmptyTitle>{t('objects.noUploadSelection')}</EmptyTitle>
                <EmptyDescription>{t('objects.selectFilesBeforeUpload')}<br />{t('objects.uploadSelectionHelp')}</EmptyDescription>
              </EmptyHeader>
            </Empty>}</div>
          </div>
          <div className="ui-dialog-footer"><Button size="sm" disabled={startingUploads || uploading || !pendingFiles.length} onClick={() => void startPendingUploads()}><Upload />{t('objects.startUpload')}</Button></div>
        </DialogContent>
      </Dialog>
      {prefix.trim() && <div className="objects-directory-heading" aria-label={t('objects.currentObjectPath')}>
        <div className="object-location-main">
          <div className="object-location-path">
            <button className="object-location-link" type="button" onClick={() => onNavigatePath('')} disabled={!bucket}>{bucket || t('objects.noBucketSelected')}</button>
            {prefix.trim() && prefix.split('/').filter(Boolean).map((segment, index, segments) => {
              const target = `${segments.slice(0, index + 1).join('/')}/`
              return <span className="object-location-crumb" key={target}><b>/</b><button className="object-location-link" type="button" onClick={() => onNavigatePath(target)}>{segment}</button></span>
            })}
          </div>
          <button className="icon-button copy-path-button" type="button" onClick={() => void copyCurrentPath()} disabled={!bucket} title={t('objects.copyCurrentPath')} aria-label={t('objects.copyCurrentPath')}>
            <Copy aria-hidden="true" />
          </button>
        </div>
      </div>}
      <div className="objects-topbar">
        <ToolbarSearch label={t('objects.filterLoadedObjects')} placeholder={t('objects.filterLoadedObjects')} value={localFilter} onChange={event => setLocalFilter(event.target.value)} />
        <div className="objects-top-actions">
          {selectedCount > 0 && <div className="selection-toolbar-actions">
            {selectedFiles.length > 0 && <>
              <button className="secondary-button" type="button" onClick={() => void downloadSelected()}><Download className="button-icon" aria-hidden="true" />{t('objects.download')}</button>
              <button className="secondary-button" type="button" onClick={() => openTransfer('copy')}><Copy className="button-icon" aria-hidden="true" />{t('objects.copy')}</button>
            </>}
            {selectedData.length > 0 && <button className="secondary-button" type="button" onClick={() => openTransfer('move')}><FolderInput className="button-icon" aria-hidden="true" />{t('objects.move')}</button>}
            {selectedDeleted.length > 0 && <button className="secondary-button" type="button" onClick={() => void restoreSelected()}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restore')}</button>}
            <button className="danger-button" type="button" onClick={() => void removeSelected()}><Trash2 className="button-icon" aria-hidden="true" />{permanentDeleteOnly ? t('objects.permanentlyDelete') : t('objects.delete')}</button>
          </div>}
          <input ref={fileInput} className="hidden-file-input" type="file" multiple onChange={selectFile} disabled={uploading} />
          <input ref={folderInput} className="hidden-file-input" type="file" multiple {...{ webkitdirectory: '' }} onChange={selectFile} disabled={uploading} />
          {(uploadTasks.length > 0 || completedUploads.length > 0 || cancelledUploads.length > 0 || deleteTasks.length > 0 || startingUploads) && <Button variant="outline" size="sm" onClick={() => { setTaskTab(null); setUploadsPanelOpen(true) }} aria-haspopup="dialog" aria-expanded={uploadsPanelOpen}>
            {uploadTasks.length === 0 && taskCounts.processing === 0 && taskCounts.failed === 0 && taskCounts.completed > 0 ? <CheckCircle2 /> : <List />}
            {uploadTasks.length === 0 && taskCounts.processing === 0 && taskCounts.failed === 0 && taskCounts.completed > 0 ? t('objects.taskCompleted') : t('objects.taskManagement')}
          </Button>}
          <Button variant="outline" size="sm" disabled={!bucket || uploading || startingUploads} onClick={() => { setUploadSubdirectory(prefix); setUploadDialogOpen(true) }}><Upload />{t('objects.uploadFileFolder')}</Button>
          <DropdownMenu><DropdownMenuTrigger asChild><Button variant="outline" size="icon-sm" aria-label={t('objects.actions')}><EllipsisVertical /></Button></DropdownMenuTrigger><DropdownMenuContent align="end"><DropdownMenuItem disabled={!bucket || loading} onSelect={() => void load(true)}><RefreshCw />{t('objects.refresh')}</DropdownMenuItem><DropdownMenuItem disabled={!bucket} onSelect={openRewind}><Undo2 />{viewMode === 'versions' ? t('objects.backToCurrentObjects') : t('objects.openVersionHistory')}</DropdownMenuItem></DropdownMenuContent></DropdownMenu>
        </div>
      </div>
      {viewMode === 'current' && <RadioGroup className="objects-deleted-filter" aria-label={t('objects.deletedFilter')} value={!showDeleted ? 'hide' : onlyDeleted ? 'only' : 'show'} onValueChange={value => { setSelectedObjectKeys(new Set()); setSelectedDeletedIds(new Set()); setOnlyDeleted(value === 'only'); setShowDeleted(value !== 'hide') }}>
        <label><RadioGroupItem value="hide" />{t('objects.hideDeletedObjects')}</label><label><RadioGroupItem value="show" />{t('objects.showDeletedObjects')}</label><label><RadioGroupItem value="only" />{t('objects.onlyDeletedObjects')}</label>
      </RadioGroup>}
      <section className="panel table-panel">
        <div className="table-wrap">
          {viewMode === 'current' ? <table className={`object-table${showDeleted ? ' deleted-object-table' : ''}`}>
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allCurrentSelected} onChange={(event) => toggleAllCurrent(event.target.checked)} aria-label={t('objects.selectAllObjects')} /></th><th className="object-column-title"><Button variant="ghost" size="sm" onClick={() => toggleSort('key')}>{t('objects.object')}<span aria-hidden="true">{sortField === 'key' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th>{showDeleted && <th>{t('objects.status')}</th>}<th><Button variant="ghost" size="sm" onClick={() => toggleSort('size')}>{t('objects.size')}<span aria-hidden="true">{sortField === 'size' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th><th><Button variant="ghost" size="sm" onClick={() => toggleSort('last_modified')}>{t('objects.lastModified')}<span aria-hidden="true">{sortField === 'last_modified' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th><th className="sticky-actions-column">{t('objects.actions')}</th></tr></thead>
            <tbody>{(!showDeleted || !onlyDeleted) && filteredObjects.map((object) => (
                <tr key={object.key}>
                  <td className="selection-column"><input type="checkbox" checked={selectedObjectKeys.has(object.key)} onChange={(event) => toggleObjectSelection(object.key, event.target.checked)} aria-label={t('objects.selectValue', { '0': object.key })} /></td>
                  <td className="object-key"><div className="file-cell object-tree-cell object-key-trigger" role="button" tabIndex={0} onClick={() => openObject(object)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openObject(object) } }} title={isDirectoryKey(object.key) ? t('objects.openDirectory') : t('objects.viewObjectDetails')}><ObjectTreeIndent depth={objectTreeDepth(object.key, prefix)} />{isDirectoryKey(object.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(object.key, prefix)}</span>{object.legal_hold && <span className="status-badge locked">{t('objects.legalHold')}</span>}{object.retention_until_unix_seconds && <span className="status-badge locked">{object.retention_mode ?? t('objects.retention')} {t('objects.until')} {formatDate(object.retention_until_unix_seconds * 1000)}</span>}</div></td>
                  {showDeleted && <td>—</td>}
                  <td>{isDirectoryKey(object.key) ? (() => {
                    const summary = directorySizeSummaries.get(object.key)
                    const calculating = directorySizeLoading.has(object.key)
                    return <div className="directory-size-cell" title={summary ? t('objects.generatedAtValue', { '0': formatDateTime(summary.generatedAt) }) : t('objects.calculateFileSizesInThisDirectoryAndItsSubdirectories')}>
                      <span>{summary ? formatBytes(summary.bytes) : t('objects.notCalculated')}</span>
                      {!summary && <button className="icon-button directory-size-refresh" type="button" onClick={() => void refreshDirectorySize(object.key)} disabled={calculating} aria-label={t('objects.refreshSizeOfDirectoryValue', { '0': displayObjectKey(object.key, prefix) })} title={t('objects.refreshDirectorySize')}><RefreshCw className={calculating ? 'spinning' : ''} aria-hidden="true" /></button>}
                    </div>
                  })() : formatBytes(object.size)}</td>
                  <td>{object.last_modified ? formatDateTime(object.last_modified) : '-'}</td>
                  <td className="table-actions sticky-actions-column">
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild><Button variant="outline" size="icon-sm" aria-label={`${t('objects.manage')} ${displayKeyForMessage(object.key)}`}><Ellipsis /></Button></DropdownMenuTrigger>
                      <DropdownMenuContent align="end" className="object-actions-menu"><DropdownMenuGroup>
                        {!isDirectoryKey(object.key) && <DropdownMenuItem onSelect={() => void download(object)}><Download />{t('objects.download')}</DropdownMenuItem>}
                        {!isDirectoryKey(object.key) && <DropdownMenuItem onSelect={() => openTransfer('copy', { kind: 'current', object })}><Copy />{t('objects.copy')}</DropdownMenuItem>}
                        {!isDirectoryKey(object.key) && <DropdownMenuItem onSelect={() => { setRenameObject(object); setRenameName(object.key.slice(object.key.lastIndexOf('/') + 1)) }}><Pencil />{t('objects.rename')}</DropdownMenuItem>}
                        {!isDirectoryKey(object.key) && <DropdownMenuItem onSelect={() => openTransfer('move', { kind: 'current', object })}><FolderInput />{t('objects.move')}</DropdownMenuItem>}
                        <DropdownMenuItem variant="destructive" onSelect={() => void removeObject(object)} disabled={!!deletingKey}><Trash2 />{t('objects.delete')}</DropdownMenuItem>
                        {isDirectoryKey(object.key) && <DropdownMenuItem variant="destructive" onSelect={() => void forceCleanupFolder(object)} disabled={!!deletingKey}><Trash2 />{t('objects.forceCleanupFolder')}</DropdownMenuItem>}
                      </DropdownMenuGroup></DropdownMenuContent>
                    </DropdownMenu>
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
                  <td>{formatDateTime(version.last_modified)}</td>
                  <td className="table-actions sticky-actions-column">
                    <ActionMenu label={t('objects.manageDeletedObjectValue', { '0': version.key })}>
                      <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restoreObjects')}</button>
                      <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={deletingVersion === identity}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>
                    </ActionMenu>
                  </td>
                </tr>
              })}</tbody>
          </table> : <table className="object-table version-table">
            <thead><tr><th className="selection-column"><input type="checkbox" checked={allVersionsSelected} onChange={(event) => toggleAllVersions(event.target.checked)} aria-label={t('objects.selectAllObjectVersions')} /></th><th className="object-column-title"><Button variant="ghost" size="sm" onClick={() => toggleSort('key')}>{t('objects.object')}<span aria-hidden="true">{sortField === 'key' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th><th>{t('objects.state')}</th><th><Button variant="ghost" size="sm" onClick={() => toggleSort('size')}>{t('objects.size')}<span aria-hidden="true">{sortField === 'size' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th><th><Button variant="ghost" size="sm" onClick={() => toggleSort('last_modified')}>{t('objects.lastModified')}<span aria-hidden="true">{sortField === 'last_modified' ? sortDirection === 1 ? '↑' : '↓' : '↕'}</span></Button></th><th className="sticky-actions-column">{t('objects.actions')}</th></tr></thead>
            <tbody>{filteredVersions.map((version) => {
              const identity = `${version.key}\u0000${version.version_id}`
              const restoring = restoringVersion === identity
              const objectDeleted = deletedObjectKeys.has(version.key)
              return <tr key={identity} className={version.is_delete_marker ? 'delete-marker-row' : ''}>
                <td className="selection-column"><input type="checkbox" checked={selectedVersionIds.has(identity)} onChange={(event) => toggleVersionSelection(version, event.target.checked)} aria-label={t('objects.selectVersionOfValue', { '0': version.key })} /></td>
                <td className="object-key"><div className="file-cell object-tree-cell"><ObjectTreeIndent depth={objectTreeDepth(version.key, prefix)} />{version.is_delete_marker ? <Trash2 className="file-symbol" aria-hidden="true" /> : isDirectoryKey(version.key) ? <Folder className="file-symbol" aria-hidden="true" /> : <File className="file-symbol" aria-hidden="true" />}<span>{displayObjectKey(version.key, prefix)}</span></div></td>
                <td><div className="version-badges">{version.is_latest && <span className="status-badge latest">{t('objects.latest')}</span>}{version.is_delete_marker && <span className="status-badge delete-marker">{t('objects.deletemarker')}</span>}{!version.is_latest && !version.is_delete_marker && <span className="status-badge">{t('objects.previous')}</span>}{version.legal_hold && <span className="status-badge locked">{t('objects.legalHold')}</span>}{version.retention_until_unix_seconds && <span className="status-badge locked">{version.retention_mode ?? t('objects.retention')} {t('objects.until')} {formatDate(version.retention_until_unix_seconds * 1000)}</span>}</div></td>
                <td>{version.is_delete_marker
                  ? (deletedVersionSizes.has(version.key) ? formatBytes(deletedVersionSizes.get(version.key)!) : '-')
                  : isDirectoryKey(version.key) ? '-' : formatBytes(version.size)}</td>
                <td>{formatDateTime(version.last_modified)}</td>
                <td className="table-actions sticky-actions-column">
                  <ActionMenu label={t('objects.manageVersionValueOfValue', { '0': version.key, '1': shortVersionId(version.version_id) })}>
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => void openVersionTagDetail(version)}>{t('objects.editObjectTags')}</button>}
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => void downloadVersion(version)}><Download className="button-icon" aria-hidden="true" />{t('objects.download')}</button>}
                    {!version.is_delete_marker && !isDirectoryKey(version.key) && <button type="button" role="menuitem" onClick={() => openTransfer('copy', { kind: 'version', version })}><Copy className="button-icon" aria-hidden="true" />{t('objects.copy')}</button>}
                    {!version.is_delete_marker && <button type="button" role="menuitem" onClick={() => openTransfer('move', { kind: 'version', version })}><FolderInput className="button-icon" aria-hidden="true" />{t('objects.move')}</button>}
                    {version.is_delete_marker && version.is_latest && <button type="button" role="menuitem" onClick={() => void restoreDeletedObject(version)} disabled={restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restoreObjects')}</button>}
                    {!version.is_delete_marker && !version.is_latest && <button type="button" role="menuitem" onClick={() => void rewindVersion(version)} disabled={restoring}><History className="button-icon" aria-hidden="true" />{t('objects.rewindToThisVersion')}</button>}
                    {!version.is_delete_marker && !version.is_latest && objectDeleted && <button type="button" role="menuitem" onClick={() => void restoreVersion(version)} disabled={restoring}><RotateCcw className="button-icon" aria-hidden="true" />{t('objects.restore')}</button>}
                    {version.is_delete_marker
                      ? <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeDeletedObject(version)} disabled={deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>
                      : <button className="danger-menu-item" type="button" role="menuitem" onClick={() => void removeVersion(version)} disabled={deletingVersion === identity || (isDirectoryKey(version.key) && versions.some((item) => item.key !== version.key && item.key.startsWith(version.key)))}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.permanentlyDelete')}</button>}
                  </ActionMenu>
                </td>
              </tr>
            })}</tbody>
          </table>}
        </div>
        {viewMode === 'current' && (visibleObjectCount === 0) && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? t('objects.noMatchingObjects') : showDeleted ? t('objects.noDeletedObjects') : t('objects.thisBucketIsEmpty')}</strong><span>{normalizedSearchQuery ? t('objects.noObjectKeysMatchYourSearch') : showDeleted ? t('objects.noDeleteMarkersInThisPath') : t('objects.uploadFilesToSeeObjectsHere')}</span></div>}
        {viewMode === 'versions' && filteredVersions.length === 0 && !loading && <div className="empty-state empty-panel"><strong>{normalizedSearchQuery ? t('objects.noMatchingVersions') : showDeleted ? t('objects.noDeleteMarkers') : t('objects.noObjectVersions')}</strong><span>{normalizedSearchQuery ? t('objects.noObjectKeysMatchYourSearch') : showDeleted ? t('objects.noDeleteMarkersAreAvailable') : t('objects.enableVersioningToTrackNewWritesAndDeletesHere')}</span></div>}
      </section>
      <div className="objects-list-footer"><span>{t('objects.loadedObjects', { count: viewMode === 'versions' ? versions.length : objects.length + (showDeleted ? deletedObjects.length : 0) })}</span><span>{t('objects.loadedFilterHint')}</span></div>
      {viewMode === 'current' && !showDeleted && nextToken && <div ref={loadMoreSentinel} className="list-load-sentinel" aria-live="polite">{loading ? t('objects.loadingMore') : t('objects.scrollDownToLoadMore')}</div>}

      <Sheet open={uploadsPanelOpen} onOpenChange={setUploadsPanelOpen}>
        <SheetContent side="right" className="upload-tasks-sheet">
          <SheetHeader><SheetTitle>{t('objects.taskManagement')}</SheetTitle><SheetDescription>{t('objects.taskSessionHelp')}</SheetDescription></SheetHeader>
          <div className="upload-tasks-summary">
            <div className="upload-tasks-summary-header"><span>{taskCounts.completed} / {totalUploadCount}</span><Button variant="ghost" size="sm" disabled={!completedUploads.length && !cancelledUploads.length && !deleteTasks.some(task => task.status !== 'processing')} onClick={() => { setCompletedUploads([]); setCancelledUploads([]); setDeleteTasks(current => current.filter(task => task.status === 'processing')) }}>{t('objects.clearTaskRecords')}</Button></div>
            <Progress className="h-1" value={overallUploadProgress} aria-label={t('objects.overallUploadProgress')} />
          </div>
          <Tabs className="upload-task-tabs" value={activeTaskTab} onValueChange={setTaskTab}>
            <TabsList aria-label={t('objects.taskManagement')}>
              <TabsTrigger value="pending">{t('objects.tasksPending')} ({taskCounts.pending})</TabsTrigger>
              <TabsTrigger value="processing">{t('objects.tasksProcessing')} ({taskCounts.processing})</TabsTrigger>
              <TabsTrigger value="completed">{t('objects.completed')} ({taskCounts.completed})</TabsTrigger>
              <TabsTrigger value="failed">{t('objects.failed')} ({taskCounts.failed})</TabsTrigger>
              <TabsTrigger value="cancelled">{t('objects.tasksCancelled')} ({taskCounts.cancelled})</TabsTrigger>
            </TabsList>
            <TabsContent value={activeTaskTab} className="upload-task-tab-content">
          <div className="uploads-drawer-body" aria-live="polite">
            {uploadsLoading && <p className="uploads-drawer-status">{t('objects.syncingMultipartUploads')}</p>}
            {!uploadsLoading && taskCounts[activeTaskTab as keyof typeof taskCounts] === 0 && <p className="uploads-drawer-status">{t('objects.noActiveUploads')}</p>}
            {visibleTasks.map(record => {
              if (record.kind === 'upload') {
              const task = record.task
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
                    <span>{task.fileName} · {task.fileSize > 0 ? formatUploadProgress(taskProgress.loaded, task.fileSize) : formatBytes(task.uploadedBytes)} · {task.completedParts} {t('objects.parts')}{task.status === 'uploading' && uploadControl.current?.uploadId === task.uploadId && <> · {t('objects.uploadSpeed', { speed: formatBytes(uploadSpeed) })}</>}</span>
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
                      <button className="secondary-button" type="button" disabled={uploading} onClick={() => void runUpload(task, task.file!)}>
                        {task.status === 'failed' ? <RotateCcw className="button-icon" aria-hidden="true" /> : <Play className="button-icon" aria-hidden="true" />}
                        {task.status === 'failed' ? t('objects.retry') : t('objects.resume')}
                      </button>
                    ) : (
                      <label className="secondary-button file-picker-button">
                        <Upload className="button-icon" aria-hidden="true" />{t('objects.selectOriginalFile')}<input type="file" onChange={(event) => attachResumeFile(task, event)} />
                      </label>
                    )}
                    <button className="danger-button" type="button" disabled={task.status === 'completing'} onClick={() => void abortUpload(task)}><Trash2 className="button-icon" aria-hidden="true" />{t('objects.cancel')}</button>
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
              }
              if (record.kind === 'delete') {
                const task = record.task
                return (
              <article className="upload-task upload-task-completed" key={task.id}>
                <div className="upload-task-record-heading">
                  <strong title={task.key}>{task.directory ? displayDirectoryKey(task.key) : displayFileName(task.key)}</strong>
                  {task.status !== 'processing' && <Button variant="ghost" size="icon-xs" className="upload-task-remove" aria-label={t('objects.removeTaskRecord', { name: task.key })} onClick={() => setDeleteTasks(current => current.filter(record => record.id !== task.id))}><Trash2 /></Button>}
                </div>
                <Progress className="h-1" value={task.status === 'processing' ? null : task.status === 'completed' ? 100 : 0} aria-label={t('objects.deletionProgress')} />
                <div className="upload-task-record-footer"><span>{task.directory ? t('objects.recursiveDelete') : ''}</span><span>{t(task.directory ? 'objects.deleteFolderTaskStatus' : 'objects.deleteTaskStatus', { status: t(task.status === 'completed' ? 'objects.taskSuccess' : task.status === 'failed' ? 'objects.failed' : 'objects.tasksProcessing') })}</span></div>
                {task.error && <span className="upload-task-error">{task.error}</span>}
              </article>
                )
              }
              if (record.kind === 'completed') {
                const item = record.task
                return (
              <article className="upload-task upload-task-completed" key={item.uploadId}>
                <div className="upload-task-record-heading">
                  <strong title={item.key}>{displayFileName(item.key)}</strong>
                  <Button variant="ghost" size="icon-xs" className="upload-task-remove" aria-label={t('objects.removeUploadRecord', { name: item.fileName })} onClick={() => setCompletedUploads(current => current.filter(record => record.uploadId !== item.uploadId))}><Trash2 /></Button>
                </div>
                <Progress className="h-1" value={100} aria-label={t('objects.uploadProgressForValue', { '0': item.fileName })} />
                <div className="upload-task-record-footer"><span>{formatBytes(item.fileSize)}</span><span>{t('objects.uploadSucceeded')}</span></div>
              </article>
                )
              }
              const item = record.task
              return <article className="upload-task" key={item.uploadId}><div className="upload-task-main"><div className="upload-task-title"><strong>{displayFileName(item.key)}</strong><span className="upload-status">{t('objects.tasksCancelled')}</span></div><span>{formatBytes(item.fileSize)}</span></div></article>
            })}
          </div>
            </TabsContent>
          </Tabs>
        </SheetContent>
      </Sheet>

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

      <Dialog open={renameObject !== null} onOpenChange={(open) => { if (!open && !renaming) setRenameObject(null) }}>
        <DialogContent className="object-rename-dialog" showCloseButton={!renaming} onInteractOutside={event => event.preventDefault()}>
          <DialogHeader><DialogTitle>{t('objects.renameObject')}</DialogTitle></DialogHeader>
          <DialogDescription className="break-all">{renameSourceName}</DialogDescription>
          <form onSubmit={submitRename} className="flex flex-col gap-6">
            <FieldGroup><Field>
              <FieldLabel htmlFor="rename-object-name" className="sr-only">{t('objects.newObjectName')}</FieldLabel>
              <Input id="rename-object-name" value={renameName} onChange={event => setRenameName(event.target.value)} disabled={renaming} aria-describedby="rename-object-hint" autoFocus onFocus={event => event.target.select()} />
              <FieldDescription id="rename-object-hint">{t('objects.renameNameHint')}</FieldDescription>
            </Field></FieldGroup>
            <div className="flex justify-end gap-2">
              <Button variant="outline" type="button" onClick={() => setRenameObject(null)} disabled={renaming}>{t('objects.cancel')}</Button>
              <Button type="submit" disabled={renaming || renameInvalid}>{renaming ? t('objects.renaming') : t('objects.rename')}</Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {transferDialog && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => { if (!transferring) setTransferDialog(null) }}>
          <section className="lifecycle-modal credential-modal transfer-modal" role="dialog" aria-modal="true" aria-labelledby="transfer-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><TransferIcon aria-hidden="true" /><h3 id="transfer-dialog-title">{transferDialog.mode === 'copy' ? t('objects.copyObjects') : t('objects.moveObjects')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('objects.close')} onClick={() => { if (!transferring) setTransferDialog(null) }}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={submitTransfer}>
              <div className="credential-modal-description">
                <p id="transfer-source-path-label">{t('objects.sourcePath')}</p>
                <ul className="transfer-source-paths" aria-labelledby="transfer-source-path-label" tabIndex={0}>
                  {transferDialog.items.map(item => {
                    const key = item.kind === 'current' ? item.object.key : item.version.key
                    return <li key={item.kind === 'version' ? `${key}\u0000${item.version.version_id}` : key}>
                      <code>{`${bucket}/${key}`}</code>
                    </li>
                  })}
                </ul>
              </div>
              <div className="credential-modal-fields transfer-fields">
                <label>{t('objects.destinationBucket')}<OptionSelect value={transferBucket} onValueChange={(value) => { setTransferBucket(value); setTransferPath(''); setTransferTreeOpen(false) }} required disabled={transferring} aria-label={t('objects.destinationBucket')} placeholder={t('objects.selectBucket')} options={buckets.map(item => ({ value: item.name, label: item.name }))} />
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

      {detail && bucket && <ObjectDetailsSheet
        key={`${bucket}/${detail.key}/${detailVersionId ?? ''}`}
        api={api} bucket={bucket} object={detail} versionId={detailVersionId} initialTagsOpen={detailVersionId !== null}
        onClose={closeDetail} onChanged={() => load(true)}
      />}

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
  const prefixWithSlash = normalizedPrefix.endsWith('/') ? normalizedPrefix : `${normalizedPrefix}/`
  const relativeKey = normalizedPrefix && key.startsWith(prefixWithSlash) ? key.slice(prefixWithSlash.length) : key
  return isDirectoryKey(key) ? `${relativeKey.replace(/\/+$/, '')}/` : relativeKey
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
