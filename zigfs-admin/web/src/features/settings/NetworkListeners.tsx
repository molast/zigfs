import { useEffect, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient } from '../../api/client'
import type { Settings } from '../../types/api'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '../../components/ui/field'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../../components/ui/Card'
import { Alert, AlertDescription } from '../../components/ui/alert'
import { useToast } from '../../components/ToastProvider'

function split(value = ''): [string, string] {
  const match = value.match(/^(\[.*\]|[^:]*):(\d+)$/)
  return match ? [match[1].replace(/^\[|\]$/g, ''), match[2]] : ['', '']
}
function address(host: string, port: string) {
  return `${host.includes(':') ? `[${host}]` : host}:${port}`
}
export function NetworkListeners({ api, settings, onSaved }: { api: ApiClient; settings: Settings | null; onSaved: () => Promise<void> }) {
  const [s3Host, setS3Host] = useState('')
  const [s3Port, setS3Port] = useState('')
  const [adminHost, setAdminHost] = useState('')
  const [adminPort, setAdminPort] = useState('')
  const [upstream, setUpstream] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const toast = useToast()
  const s3Saved = settings?.pending_api_address || settings?.api_address || ''
  const adminSaved = settings?.pending_admin_listen_address || settings?.admin_listen_address || ''
  const upstreamSaved = settings?.pending_upstream_endpoint || settings?.upstream_endpoint || ''
  useEffect(() => {
    const [s3h, s3p] = split(s3Saved), [adminh, adminp] = split(adminSaved)
    setS3Host(s3h); setS3Port(s3p); setAdminHost(adminh); setAdminPort(adminp); setUpstream(upstreamSaved)
    setError('')
  }, [s3Saved, adminSaved, upstreamSaved])
  const changed = address(s3Host, s3Port) !== address(...split(s3Saved)) || address(adminHost, adminPort) !== address(...split(adminSaved)) || upstream !== upstreamSaved
  function updateS3(host: string, port: string) {
    setS3Host(host); setS3Port(port); setError('')
    try {
      const next = new URL(upstream)
      next.port = port
      if (host && host !== '0.0.0.0' && host !== '::') next.hostname = host.includes(':') ? `[${host}]` : host
      setUpstream(next.origin)
    } catch { /* Keep the explicit upstream value editable. */ }
  }
  return <Card className="settings-detail-card">
    <CardHeader><CardTitle>{t('settings.listenerConfiguration')}</CardTitle><CardDescription>{t('settings.listenerRestartHelp')}</CardDescription></CardHeader>
    <CardContent><form onSubmit={async event => {
      event.preventDefault(); setBusy(true); setError('')
      try {
        await api.saveListeners({ api_address: address(s3Host.trim(), s3Port), admin_listen_address: address(adminHost.trim(), adminPort), upstream_endpoint: upstream.trim() })
        toast(t('settings.listenersSaved'))
        await onSaved()
      } catch (reason) {
        const code = reason instanceof ApiError ? reason.body.code : ''
        setError(code === 'InvalidListenAddress' ? t('settings.invalidListenAddress') : code === 'InvalidUpstreamEndpoint' ? t('settings.invalidUpstreamEndpoint') : code === 'ListenAddressUnavailable' ? t('settings.s3PortUnavailable') : code === 'AdminListenAddressUnavailable' ? t('settings.adminPortUnavailable') : code === 'ListenerSettingsPartiallySaved' ? t('settings.listenersPartiallySaved') : t('settings.networkSaveFailed'))
      } finally { setBusy(false) }
    }}><FieldGroup>
      <FieldDescription>{t('settings.s3ApiService')}: {settings?.api_address || '—'}</FieldDescription>
      <FieldGroup className="settings-field-pair">
        <Field><FieldLabel htmlFor="listen-s3-host">{t('settings.listenAddress')}</FieldLabel><Input id="listen-s3-host" disabled={busy || !settings} value={s3Host} onChange={e => updateS3(e.target.value, s3Port)} /></Field>
        <Field><FieldLabel htmlFor="listen-s3-port">{t('settings.port')}</FieldLabel><Input id="listen-s3-port" inputMode="numeric" disabled={busy || !settings} value={s3Port} onChange={e => updateS3(s3Host, e.target.value)} /></Field>
      </FieldGroup>
      <FieldDescription>{t('settings.adminConsoleService')}: {settings?.admin_listen_address || '—'}</FieldDescription>
      <FieldGroup className="settings-field-pair">
        <Field><FieldLabel htmlFor="listen-admin-host">{t('settings.listenAddress')}</FieldLabel><Input id="listen-admin-host" disabled={busy || !settings} value={adminHost} onChange={e => { setAdminHost(e.target.value); setError('') }} /></Field>
        <Field><FieldLabel htmlFor="listen-admin-port">{t('settings.port')}</FieldLabel><Input id="listen-admin-port" inputMode="numeric" disabled={busy || !settings} value={adminPort} onChange={e => { setAdminPort(e.target.value); setError('') }} /></Field>
      </FieldGroup>
      <Field><FieldLabel htmlFor="listen-upstream">{t('settings.upstreamEndpoint')}</FieldLabel><Input id="listen-upstream" disabled={busy || !settings} value={upstream} onChange={e => { setUpstream(e.target.value); setError('') }} /><FieldDescription>{t('settings.upstreamEndpointHelp')}</FieldDescription></Field>
      <FieldDescription>{t('settings.currentAccessUrl')}: {window.location.origin}</FieldDescription>
      {(settings?.api_restart_required || settings?.admin_restart_required) && <Alert><AlertDescription>{settings?.api_restart_required && <p>{t('settings.s3RestartPending', { address: s3Saved })}</p>}{settings?.admin_restart_required && <p>{t('settings.adminRestartPending', { address: adminSaved })}</p>}</AlertDescription></Alert>}
      {error && <p role="alert" className="text-destructive">{error}</p>}
      <Button type="submit" disabled={busy || !settings || !changed}>{t('settings.saveNetwork')}</Button>
    </FieldGroup></form></CardContent>
  </Card>
}
