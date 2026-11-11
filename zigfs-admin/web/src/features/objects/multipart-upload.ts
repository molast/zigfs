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
  const preferred = fileSize >= 4 * 1024 * oneMiB ? 64 * oneMiB
    : fileSize >= 256 * oneMiB ? 32 * oneMiB : DEFAULT_PART_SIZE
  return Math.max(preferred, Math.ceil(required / oneMiB) * oneMiB)
}

export function chooseUploadConcurrency(
  partSize: number,
  logicalCores = typeof navigator === 'undefined' ? 8 : navigator.hardwareConcurrency,
) {
  // This is a client-side scheduling hint, not a measure of server capacity.
  // Keep the previously tested four-connection / 128 MiB ceilings and reduce
  // parallelism on smaller clients. Missing CPU information retains four lanes.
  const cores = Number.isFinite(logicalCores) && logicalCores >= 1 ? logicalCores : 8
  const cpuLimit = Math.max(1, Math.floor(cores / 2))
  return Math.max(1, Math.min(cpuLimit, 4, Math.floor(128 * 1024 * 1024 / partSize)))
}

export async function uploadPartsConcurrently(
  parts: number[],
  concurrency: number,
  upload: (partNumber: number) => Promise<void>,
  stop: () => void,
) {
  let next = 0
  let failed = false
  let failure: unknown
  async function worker() {
    while (!failed && next < parts.length) {
      const part = parts[next++]
      try {
        await upload(part)
      } catch (error) {
        if (!failed) {
          failed = true
          failure = error
          stop()
        }
      }
    }
  }
  // Drain active workers before allowing resume/completion, including pending
  // presign calls. Preserve the original error rather than a sibling's abort.
  await Promise.all(Array.from({ length: Math.min(parts.length, concurrency) }, worker))
  if (failed) throw failure
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
    let settled = false
    let idleTimer: number | undefined
    let lastLoaded = 0
    const finish = (error?: Error, etag = '') => {
      if (settled) return
      settled = true
      window.clearTimeout(idleTimer)
      if (error) reject(error)
      else resolve(etag)
    }
    const resetIdleTimer = () => {
      window.clearTimeout(idleTimer)
      idleTimer = window.setTimeout(() => {
        finish(new Error(t('objects.partUploadTimedOut')))
        request.abort()
      }, 60_000)
    }
    request.open('PUT', url)
    request.timeout = 15 * 60 * 1000
    request.setRequestHeader('Content-Type', contentType || 'application/octet-stream')
    request.upload.addEventListener('progress', (event) => {
      if (settled) return
      if (event.loaded > lastLoaded) {
        lastLoaded = event.loaded
        resetIdleTimer()
      }
      const total = event.lengthComputable && event.total > 0 ? event.total : body.size
      onProgress({ loaded: Math.min(event.loaded, total), total })
    })
    request.addEventListener('load', () => {
      if (settled) return
      if (request.status < 200 || request.status >= 300) {
        finish(new Error(t('objects.partUploadFailedValue', { '0': request.status })))
        return
      }
      const etag = normalizeEtag(request.getResponseHeader('ETag') ?? '')
      if (!etag) {
        finish(new Error(t('objects.partUploadResponseHasNoValidEtag')))
        return
      }
      onProgress({ loaded: body.size, total: body.size })
      finish(undefined, etag)
    })
    request.addEventListener('error', () => finish(new Error(t('objects.partUploadFailedDueToANetworkError'))))
    request.addEventListener('timeout', () => finish(new Error(t('objects.partUploadTimedOut'))))
    request.addEventListener('abort', () => {
      const error = new Error(t('objects.uploadPaused'))
      error.name = 'AbortError'
      finish(error)
    })
    try {
      onRequest(request)
      resetIdleTimer()
      request.send(body)
    } catch (error) {
      finish(error as Error)
    }
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

// Never round a partially uploaded file up to its total size.
export function formatUploadProgress(loaded: number, total: number) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const format = (bytes: number, maxUnit: number) => {
    let value = Math.max(0, Math.floor(bytes))
    let unit = 0
    while (value >= 1024 && unit < maxUnit) {
      value /= 1024
      unit += 1
    }
    const truncated = Math.floor(value * 100) / 100
    return `${truncated} ${units[unit]}`
  }
  let maxUnit = units.length - 1
  let uploaded = format(loaded, maxUnit)
  let size = format(total, maxUnit)
  while (loaded < total && uploaded === size && maxUnit > 0) {
    maxUnit -= 1
    uploaded = format(loaded, maxUnit)
    size = format(total, maxUnit)
  }
  return `${uploaded} / ${size}`
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
