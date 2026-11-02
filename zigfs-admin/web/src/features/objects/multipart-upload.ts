import { t } from '@/locales'
import type { MultipartUpload } from '../../types/api'

export const DEFAULT_PART_SIZE = 8 * 1024 * 1024
export const MAX_PARTS = 10_000
const STORAGE_KEY = 'zigfs.multipart-uploads.v1'

export type UploadTaskStatus = 'paused' | 'uploading' | 'completing' | 'failed'

export interface UploadTask {
  uploadId: string
  bucket: string
  key: string
  fileName: string
  fileSize: number
  lastModified: number
  contentType: string
  partSize: number
  initiatedAt: string
  uploadedBytes: number
  completedParts: number
  status: UploadTaskStatus
  error?: string
  file?: File
}

export interface PartProgress {
  loaded: number
  total: number
}

type PersistedUploadTask = Omit<UploadTask, 'file' | 'status' | 'error'>

export function choosePartSize(fileSize: number) {
  const required = Math.ceil(fileSize / MAX_PARTS)
  const oneMiB = 1024 * 1024
  return Math.max(DEFAULT_PART_SIZE, Math.ceil(required / oneMiB) * oneMiB)
}

export function inferPartSize(upload: MultipartUpload, fileSize: number, persistedPartSize = 0) {
  if (persistedPartSize > 0) return persistedPartSize
  const nonFinalPart = upload.parts.find((part) => part.size >= 5 * 1024 * 1024)
  return nonFinalPart?.size ?? choosePartSize(fileSize)
}

export function validateResumeFile(task: UploadTask, upload: MultipartUpload, file: File, partSize: number) {
  if (task.fileSize > 0 && task.fileSize !== file.size) {
    throw new Error(t('objects.fileSizeDoesNotMatchSelectTheOriginalFile', { '0': formatBytes(task.fileSize) }))
  }
  if (task.lastModified > 0 && task.lastModified !== file.lastModified) {
    throw new Error(t('objects.modificationTimeDoesNotMatchSelectTheOriginalFile'))
  }
  const partCount = Math.max(1, Math.ceil(file.size / partSize))
  if (partCount > MAX_PARTS) throw new Error(t('objects.fileIsTooLargeMoreThan10000Parts'))
  for (const part of upload.parts) {
    if (part.part_number < 1 || part.part_number > partCount) {
      throw new Error(t('objects.serverPartValueIsOutsideTheCurrentFileRange', { '0': part.part_number }))
    }
    const start = (part.part_number - 1) * partSize
    const expectedSize = Math.min(partSize, file.size - start)
    if (part.size !== expectedSize) {
      throw new Error(t('objects.fileDoesNotMatchUploadedPartValue', { '0': part.part_number }))
    }
  }
}

export function putPart(
  url: string,
  body: Blob,
  contentType: string,
  onProgress: (progress: PartProgress) => void,
  onRequest: (request: XMLHttpRequest) => void,
) {
  return new Promise<string>((resolve, reject) => {
    const request = new XMLHttpRequest()
    request.open('PUT', url)
    request.setRequestHeader('Content-Type', contentType || 'application/octet-stream')
    request.upload.addEventListener('progress', (event) => {
      const total = event.lengthComputable && event.total > 0 ? event.total : body.size
      onProgress({ loaded: Math.min(event.loaded, total), total })
    })
    request.addEventListener('load', () => {
      if (request.status < 200 || request.status >= 300) {
        reject(new Error(t('objects.partUploadFailedValue', { '0': request.status })))
        return
      }
      const etag = normalizeEtag(request.getResponseHeader('ETag') ?? '')
      if (!etag) {
        reject(new Error(t('objects.partUploadResponseHasNoValidEtag')))
        return
      }
      onProgress({ loaded: body.size, total: body.size })
      resolve(etag)
    })
    request.addEventListener('error', () => reject(new Error(t('objects.partUploadFailedDueToANetworkError'))))
    request.addEventListener('abort', () => {
      const error = new Error(t('objects.uploadPaused'))
      error.name = 'AbortError'
      reject(error)
    })
    onRequest(request)
    request.send(body)
  })
}

export function loadPersistedTasks() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return new Map<string, PersistedUploadTask>()
    const parsed = JSON.parse(raw) as PersistedUploadTask[]
    return new Map(parsed.map((task) => [task.uploadId, task]))
  } catch {
    return new Map<string, PersistedUploadTask>()
  }
}

export function persistTasks(tasks: UploadTask[], bucket?: string) {
  try {
    const persisted: PersistedUploadTask[] = tasks.map(({ file: _file, status: _status, error: _error, ...task }) => task)
    const retained = bucket
      ? [...loadPersistedTasks().values()].filter((task) => task.bucket !== bucket)
      : []
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify([...retained, ...persisted]))
  } catch {
    // The FS remains the source of truth when browser storage is unavailable.
  }
}

export function formatBytes(bytes: number) {
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

function normalizeEtag(value: string) {
  const trimmed = value.trim()
  const unquoted = trimmed.startsWith('"') && trimmed.endsWith('"') ? trimmed.slice(1, -1) : trimmed
  return /^[a-f\d]{32}$/i.test(unquoted) ? unquoted.toLowerCase() : ''
}
