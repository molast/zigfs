import type { ApiClient } from '../../api/client'
import { UserAccessKeys } from '../identities/UserAccessKeys'

export function AccessKeysView({ api }: { api: ApiClient }) {
  return <UserAccessKeys api={api} />
}
