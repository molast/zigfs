import type { SystemInfo } from '@/types/api'

// 100% equals one fully occupied CPU core; multi-core use can exceed 100%.
export function processCPUPercent(previous: SystemInfo | null, next: SystemInfo): number | null {
  if (!previous?.process || !next.process || next.uptime < previous.uptime) return null
  const elapsed = next.process.sampled_at_seconds - previous.process.sampled_at_seconds
  const used = next.process.cpu_seconds - previous.process.cpu_seconds
  if (!Number.isFinite(elapsed) || !Number.isFinite(used) || elapsed <= 0 || used < 0) return null
  return used / elapsed * 100
}
