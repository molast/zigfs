import type { ManagementHealth } from '@/types/api'

export function serviceHealth(health: ManagementHealth | null | undefined, failures: number, scannerSucceeded?: boolean | null): 'healthy' | 'attention' | 'unknown' {
  if (!health) return 'unknown'
  const diagnostics = health.diagnostics
  if (health.status !== 'ready' || health.recovery !== 'ready' || scannerSucceeded === false || diagnostics?.storage.state === 'offline' || diagnostics?.storage.read_only === true || diagnostics?.metadata.ready === false) return 'attention'
  if (failures || !diagnostics || diagnostics.storage.state === 'unknown' || diagnostics.storage.read_only == null) return 'unknown'
  return 'healthy'
}
