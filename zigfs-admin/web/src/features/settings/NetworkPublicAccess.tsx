import { useEffect, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient } from '../../api/client'
import type { Settings } from '../../types/api'
import { Button } from '../../components/ui/Button'
import { Textarea } from '../../components/ui/Textarea'
import { Input } from '../../components/ui/Input'
import { Checkbox } from '../../components/ui/checkbox'
import { Field, FieldLabel, FieldDescription, FieldGroup } from '../../components/ui/field'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../../components/ui/Card'
import { useToast } from '../../components/ToastProvider'

export function NetworkPublicAccess({ api, settings, onSaved }: { api: ApiClient; settings: Settings | null; onSaved: () => Promise<void> }) {
  const [endpoint, setEndpoint] = useState('')
  const [virtualHost, setVirtualHost] = useState(false)
  const [proxies, setProxies] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [errorCode, setErrorCode] = useState('')
  const toast = useToast()
  useEffect(() => {
    setEndpoint(settings?.s3_public_endpoint ?? '')
    setVirtualHost(settings?.s3_virtual_hosted_style ?? false)
    setProxies((settings?.trusted_proxies ?? []).join('\n'))
  }, [settings?.s3_public_endpoint, settings?.s3_virtual_hosted_style, settings?.trusted_proxies])
  const changed = endpoint !== settings?.s3_public_endpoint || virtualHost !== settings?.s3_virtual_hosted_style || proxies !== (settings?.trusted_proxies ?? []).join('\n')
  return <Card className="settings-detail-card">
    <CardHeader><CardTitle>{t('settings.publicAccess')}</CardTitle><CardDescription>{t('settings.networkSaveHelp')}</CardDescription></CardHeader>
    <CardContent><form onSubmit={async event => {
      event.preventDefault()
      setError('')
      setErrorCode('')
      setBusy(true)
      try {
        await api.saveNetworkSettings({ s3_public_endpoint: endpoint.trim(), s3_virtual_hosted_style: virtualHost, trusted_proxies: proxies.split('\n').map(value => value.trim()).filter(Boolean) })
        toast(t('settings.networkSaved'))
        await onSaved()
      } catch (reason) {
        setErrorCode(reason instanceof ApiError ? reason.body.code : '')
        setError(reason instanceof ApiError && reason.body.code === 'InvalidPublicEndpoint' ? t('settings.invalidPublicEndpoint') : reason instanceof ApiError && reason.body.code === 'InvalidVirtualHostedEndpoint' ? t('settings.invalidVirtualHostedEndpoint') : reason instanceof ApiError && reason.body.code === 'InvalidTrustedProxy' ? t('settings.invalidTrustedProxy') : t('settings.networkSaveFailed'))
      } finally { setBusy(false) }
    }}><FieldGroup>
      <Field><FieldLabel htmlFor="network-public-endpoint">{t('settings.publicUrl')}</FieldLabel><Input id="network-public-endpoint" value={endpoint} onChange={event => { setEndpoint(event.target.value); setError('') }} disabled={busy || !settings} aria-invalid={!!error && errorCode === 'InvalidPublicEndpoint'} aria-describedby={error ? 'network-error' : undefined} placeholder="https://s3.example.com" /><FieldDescription>{t('settings.publicS3EndpointForAReverseProxyOrDomain')}</FieldDescription></Field>
      <Field orientation="horizontal"><Checkbox id="network-virtual-host" checked={virtualHost} onCheckedChange={value => { setVirtualHost(value === true); setError('') }} disabled={busy || !settings} /><FieldLabel htmlFor="network-virtual-host">{t('settings.virtualHostedAddressing')}</FieldLabel></Field>
      <FieldDescription>{t('settings.virtualHostHelp')}</FieldDescription>
      <Field><FieldLabel htmlFor="network-trusted-proxies">{t('settings.trustedProxies')}</FieldLabel><Textarea id="network-trusted-proxies" aria-invalid={!!error && errorCode === 'InvalidTrustedProxy'} aria-describedby={error ? 'network-error' : undefined} rows={4} value={proxies} onChange={event => { setProxies(event.target.value); setError('') }} disabled={busy || !settings} placeholder={'127.0.0.1\n10.0.0.0/24\n::1'} /><FieldDescription>{t('settings.trustedProxiesHelp')}</FieldDescription></Field>
      {error && <p id="network-error" role="alert" className="text-destructive">{error}</p>}
      <Button type="submit" disabled={busy || !settings || !changed}>{t('settings.saveNetwork')}</Button>
    </FieldGroup></form></CardContent>
  </Card>
}
