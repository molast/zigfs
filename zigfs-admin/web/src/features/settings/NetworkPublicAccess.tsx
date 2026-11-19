import { useEffect, useState, type FormEvent } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient } from '../../api/client'
import type { Settings } from '../../types/api'
import { Button } from '../../components/ui/Button'
import { Textarea } from '../../components/ui/Textarea'
import { Input } from '../../components/ui/Input'
import { Checkbox } from '../../components/ui/checkbox'
import { Field, FieldLabel, FieldDescription, FieldGroup } from '../../components/ui/field'
import { Card, CardHeader, CardTitle, CardContent } from '../../components/ui/Card'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import { EndpointCheck } from './EndpointCheck'

interface NetworkPublicAccessProps {
  api: ApiClient
  settings: Settings | null
  onSaved: () => Promise<void>
}

export function NetworkPublicAccess({ api, settings, onSaved }: NetworkPublicAccessProps) {
  const [endpoint, setEndpoint] = useState('')
  const [virtualHost, setVirtualHost] = useState(false)
  const [proxies, setProxies] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [errorCode, setErrorCode] = useState('')
  const toast = useToast()
  const errorToast = useErrorToast()

  useEffect(() => {
    setEndpoint(settings?.s3_public_endpoint ?? '')
    setVirtualHost(settings?.s3_virtual_hosted_style ?? false)
    setProxies((settings?.trusted_proxies ?? []).join('\n'))
  }, [settings?.s3_public_endpoint, settings?.s3_virtual_hosted_style, settings?.trusted_proxies])
  const changed = endpoint !== settings?.s3_public_endpoint
    || virtualHost !== settings?.s3_virtual_hosted_style
    || proxies !== (settings?.trusted_proxies ?? []).join('\n')

  async function save(event: FormEvent) {
    event.preventDefault()
    setError('')
    setErrorCode('')
    setBusy(true)
    try {
      await api.saveNetworkSettings({
        s3_public_endpoint: endpoint.trim(),
        s3_virtual_hosted_style: virtualHost,
        trusted_proxies: proxies.split('\n').map(value => value.trim()).filter(Boolean),
      })
      toast(t('settings.networkSaved'))
      await onSaved()
    } catch (reason) {
      const code = reason instanceof ApiError ? reason.body.code : ''
      let message = t('settings.networkSaveFailed')
      if (code === 'InvalidPublicEndpoint') {
        message = t('settings.invalidPublicEndpoint')
      } else if (code === 'InvalidVirtualHostedEndpoint') {
        message = t('settings.invalidVirtualHostedEndpoint')
      } else if (code === 'InvalidTrustedProxy') {
        message = t('settings.invalidTrustedProxy')
      }
      setErrorCode(code)
      setError(message)
      errorToast(message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card className="settings-detail-card">
      <CardHeader>
        <CardTitle>{t('settings.publicAccess')}</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={save}>
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="network-public-endpoint">{t('settings.publicUrl')}</FieldLabel>
              <div className="flex flex-wrap items-center gap-2">
                <Input
                  id="network-public-endpoint"
                  className="min-w-0 max-w-md flex-1 basis-64"
                  value={endpoint}
                  onChange={event => {
                    setEndpoint(event.target.value)
                    setError('')
                  }}
                  disabled={busy || !settings}
                  aria-invalid={!!error && errorCode === 'InvalidPublicEndpoint'}
                  aria-describedby="network-public-endpoint-help"
                  placeholder="https://s3.example.com"
                />
                <EndpointCheck endpoint={endpoint} disabled={busy || !settings} />
              </div>
              <FieldDescription id="network-public-endpoint-help">
                {t('settings.publicS3EndpointForAReverseProxyOrDomain')}
                {' '}{t('settings.endpointCheckHelp')}
              </FieldDescription>
            </Field>
            <Field orientation="horizontal">
              <Checkbox
                id="network-virtual-host"
                checked={virtualHost}
                onCheckedChange={value => {
                  setVirtualHost(value === true)
                  setError('')
                }}
                disabled={busy || !settings}
              />
              <FieldLabel htmlFor="network-virtual-host">
                {t('settings.virtualHostedAddressing')}
              </FieldLabel>
            </Field>
            <FieldDescription>{t('settings.virtualHostHelp')}</FieldDescription>
            <Field>
              <FieldLabel htmlFor="network-trusted-proxies">{t('settings.trustedProxies')}</FieldLabel>
              <Textarea
                id="network-trusted-proxies"
                aria-invalid={!!error && errorCode === 'InvalidTrustedProxy'}
                rows={4}
                value={proxies}
                onChange={event => {
                  setProxies(event.target.value)
                  setError('')
                }}
                disabled={busy || !settings}
                placeholder={'127.0.0.1\n10.0.0.0/24\n::1'}
              />
              <FieldDescription>{t('settings.trustedProxiesHelp')}</FieldDescription>
            </Field>
            <div className="flex flex-wrap items-center gap-3">
              <Button
                type="submit"
                disabled={busy || !settings || !changed}
                aria-describedby="network-save-help"
              >
                {t('settings.saveNetwork')}
              </Button>
              <FieldDescription id="network-save-help">
                {t('settings.networkSaveHelp')}
              </FieldDescription>
            </div>
          </FieldGroup>
        </form>
      </CardContent>
    </Card>
  )
}
