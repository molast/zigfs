import type { AdminSession } from '@/types/api'

export function accountStatusKey(session: AdminSession) {
  const source = session.auth_source ?? (session.is_root ? 'deployment' : session.federated ? 'oidc' : 'local')
  if (source === 'deployment') return 'account.deploymentManagedStatus'
  if (source === 'oidc') return 'account.externalManagedStatus'
  if (source === 'sts') return 'account.credentialManagedStatus'
  if (session.account_enabled === true) return 'account.enabled'
  if (session.account_enabled === false) return 'account.disabledStatus'
  return 'account.statusUnknown'
}
