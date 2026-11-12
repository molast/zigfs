import { useState } from 'react'
import { ArrowLeft, RefreshCw, ShieldCheck } from 'lucide-react'
import { t } from '@/locales'
import { formatDateTime } from '@/lib/dateTime'
import type { ApiClient } from '../../api/client'
import type { AdminSession } from '../../types/api'
import { useErrorToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Badge } from '../../components/ui/Badge'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../../components/ui/Card'
import { Alert, AlertDescription } from '../../components/ui/alert'
import { Separator } from '../../components/ui/separator'

export function AccountView({ session, security, api, onSession, onNavigate }: {
  session: AdminSession
  security: boolean
  api: ApiClient
  onSession: (session: AdminSession) => void
  onNavigate: (view: 'profile' | 'account-security') => void
}) {
  const [busy, setBusy] = useState(false)
  const notifyError = useErrorToast()
  const source = session.auth_source ?? (session.is_root ? 'deployment' : session.federated ? 'oidc' : 'local')
  const explanation = source === 'deployment' ? (security ? 'account.deploymentPasswordHelp' : 'account.deploymentHelp') : source === 'oidc' ? 'account.oidcHelp' : source === 'sts' ? 'account.stsHelp' : 'account.localHelp'
  async function refresh() {
    if (busy) return
    setBusy(true)
    try { onSession(await api.session()) }
    catch { notifyError(t('account.refreshFailed')) }
    finally { setBusy(false) }
  }
  return <section className="flex flex-col gap-6">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div><h2>{t(security ? 'account.security' : 'account.profile')}</h2><p className="text-muted-foreground">{t(security ? 'account.securityDescription' : 'account.profileDescription')}</p></div>
      <div className="flex gap-2">
        {security && <Button variant="outline" onClick={() => onNavigate('profile')}><ArrowLeft data-icon="inline-start" />{t('account.profile')}</Button>}
        <Button variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{t('account.refresh')}</Button>
        {!security && <Button variant="outline" onClick={() => onNavigate('account-security')}><ShieldCheck data-icon="inline-start" />{t('account.security')}</Button>}
      </div>
    </div>
    {security ? <Card>
      <CardHeader><CardTitle>{t(source === 'sts' ? 'account.credentials' : 'account.password')}</CardTitle><CardDescription>{t('account.managedOutside')}</CardDescription></CardHeader>
      <CardContent className="flex flex-col gap-4"><Alert><AlertDescription>{t(explanation)}</AlertDescription></Alert>
        {source === 'deployment' && <><Separator /><p className="text-sm leading-relaxed text-muted-foreground">{t('account.rootKeysHelp')}</p><dl className="grid grid-cols-1 gap-3 sm:grid-cols-[240px_1fr]"><dt className="text-muted-foreground">{t('account.rootAccessKey')}</dt><dd className="break-all font-mono">{session.root_access_key || t('account.notConfigured')}</dd></dl></>}
      </CardContent>
    </Card> : <Card>
      <CardHeader><CardTitle>{t('account.identity')}</CardTitle><CardDescription>{t('account.identityDescription')}</CardDescription></CardHeader>
      <CardContent className="flex flex-col gap-6">
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-[240px_1fr]">
          <dt className="text-muted-foreground">{t('account.username')}</dt><dd>{session.username}</dd>
          <dt className="text-muted-foreground">{t('account.role')}</dt><dd className="flex flex-wrap gap-2">{t(session.is_root || session.capabilities?.admin ? 'account.administrator' : 'account.user')}<Badge>{t('account.temporarySession')}</Badge></dd>
          <dt className="text-muted-foreground">{t('account.status')}</dt><dd>{t('account.enabled')}</dd>
          <dt className="text-muted-foreground">{t('account.source')}</dt><dd>{t(source === 'deployment' ? 'account.deployment' : source === 'oidc' ? 'account.oidc' : source === 'sts' ? 'account.sts' : 'account.local')}</dd>
          <dt className="text-muted-foreground">{t('account.expires')}</dt><dd>{formatDateTime(session.expires_at * 1000)}</dd>
          {session.is_root && <><dt className="text-muted-foreground">{t('account.rootAccessKey')}</dt><dd className="break-all font-mono">{session.root_access_key || t('account.notConfigured')}</dd></>}
          {session.session_access_key && <><dt className="text-muted-foreground">{t('account.sessionAccessKey')}</dt><dd className="break-all font-mono">{session.session_access_key}</dd></>}
        </dl>
        <Alert><AlertDescription>{t(explanation)}</AlertDescription></Alert>
      </CardContent>
    </Card>}
  </section>
}
