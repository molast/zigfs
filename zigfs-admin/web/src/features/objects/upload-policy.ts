// Client upload policy v1; boundary cases are shared with CLI validation.
export const MIB = 1024 * 1024
export const MULTIPART_THRESHOLD = 16 * MIB
export const MAX_PARTS = 10_000
export const MAX_OBJECT_SIZE = 5 * 1024 * 1024 * MIB

export function chooseUploadPlan(fileSize: number, maxParts = MAX_PARTS) {
  if (!Number.isSafeInteger(fileSize) || fileSize < 0 || fileSize > MAX_OBJECT_SIZE
    || !Number.isInteger(maxParts) || maxParts < 1 || maxParts > MAX_PARTS) {
    throw new Error('Invalid upload size or part count')
  }
  let preferred = 128 * MIB
  if (fileSize < 128 * MIB) preferred = 8 * MIB
  else if (fileSize < 1024 * MIB) preferred = 16 * MIB
  else if (fileSize < 10 * 1024 * MIB) preferred = 32 * MIB
  else if (fileSize < 100 * 1024 * MIB) preferred = 64 * MIB
  const partSize = Math.ceil(Math.max(preferred, Math.ceil(fileSize / maxParts)) / MIB) * MIB
  if (partSize > 5 * 1024 * MIB) throw new Error('Part size exceeds 5 GiB')
  const concurrency = fileSize < MULTIPART_THRESHOLD ? 1 : fileSize < 128 * MIB ? 2 : 4
  return { multipart: fileSize >= MULTIPART_THRESHOLD, partSize, concurrency }
}
