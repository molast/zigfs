import { useEffect, useState } from 'react'
import type { ApiClient } from '@/api/client'
import { t } from '@/locales'
import { formatDateTime } from '@/lib/dateTime'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Textarea } from '@/components/ui/Textarea'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/Card'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group'
import { Badge } from '@/components/ui/Badge'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { useConfirm } from '@/components/ConfirmProvider'
import { EndpointCheck } from './EndpointCheck'
import { verifyGatewayFromBrowser, type GatewayConfig, type GatewayStatus } from './gateway'

const defaults: GatewayConfig = {
  resolution_ip: '127.0.0.1',
  listen_address: ':8443',
  admin_domain: 'admin.zigfs.home.arpa',
  s3_domain: 's3.zigfs.home.arpa',
  external_port: 8443,
  certificate_mode: 'local',
}

export function NetworkGateway({ api, onSaved }: { api: ApiClient; onSaved: () => Promise<void> }) {
  const [status, setStatus] = useState<GatewayStatus | null>(null)
  const [draft, setDraft] = useState(defaults)
  const [certificate, setCertificate] = useState('')
  const [privateKey, setPrivateKey] = useState('')
  const [fallback, setFallback] = useState('')
  const [busy, setBusy] = useState(false)
  const [verified, setVerified] = useState('')
  const toast = useToast()
  const errorToast = useErrorToast()
  const confirm = useConfirm()

  useEffect(() => {
    let disposed = false
    api.gatewayStatus().then(value => {
      if (disposed) return
      setStatus(value)
      setDraft({ ...defaults, ...(value.candidate?.config ?? value.active?.config) })
    }).catch(reason => {
      if (!disposed) errorToast((reason as Error).message)
    })
    return () => { disposed = true }
  }, [api, errorToast])

  async function perform(action: () => Promise<void>) {
    setBusy(true)
    try {
      await action()
    } catch (reason) {
      errorToast((reason as Error).message)
      // A failed apply may have persisted its journal before the upstream call.
      // Refresh revision and pending state rather than leaving stale controls.
      try { setStatus(await api.gatewayStatus()) } catch { /* Original error is already visible. */ }
    } finally {
      setBusy(false)
    }
  }

  async function prepare() {
    if (!status) return
    await perform(async () => {
      const next = await api.prepareGateway(status.revision, draft, certificate, privateKey)
      setStatus(next)
      setDraft({ ...defaults, ...next.candidate?.config })
      setVerified('')
      setCertificate('')
      setPrivateKey('')
      toast(t('gateway.prepared'))
    })
  }

  async function checkClient() {
    const deployment = status?.candidate ?? status?.active
    if (!deployment) return
    await perform(async () => {
      try {
        await verifyGatewayFromBrowser(deployment)
      } catch {
        throw new Error(t('gateway.clientCheckFailed'))
      }
      setVerified(deployment.id)
      toast(t('gateway.clientCheckPassed'))
    })
  }

  async function apply(disable = false) {
    if (!status) return
    if (!await confirm({
      title: t(disable ? 'gateway.disable' : 'gateway.apply'),
      message: t(disable ? 'gateway.disableConfirmation' : 'gateway.applyConfirmation'),
    })) return
    await perform(async () => {
      const next = await api.gatewayAction('apply', {
        revision: status.revision,
        client_verified: verified === status.candidate?.id || status.pending,
        disable,
        fallback_endpoint: fallback.trim(),
      })
      setStatus(next)
      await onSaved()
      toast(t('gateway.applied'))
    })
  }

  const windowsSetup = status?.local_dns?.platform === 'windows'
  const displayed = status?.candidate ?? status?.active
  const draftChanged = displayed != null
    && (JSON.stringify({ ...defaults, ...draft }) !== JSON.stringify({ ...defaults, ...displayed.config })
      || certificate.length > 0 || privateKey.length > 0)
  const expiresSoon = displayed != null
    && Date.parse(displayed.expires_at) - Date.now() < 30 * 24 * 60 * 60 * 1000
  let stepHelp = t('gateway.stepActive')
  if (draftChanged || !displayed) {
    stepHelp = t('gateway.stepPrepare')
  } else if (status?.candidate) {
    stepHelp = verified === status.candidate.id
      ? t('gateway.stepApply')
      : t('gateway.stepVerify')
  }

  return (
    <Card className="settings-detail-card">
      <CardHeader>
        <CardTitle>{t('gateway.title')}</CardTitle>
        <CardDescription>{t('gateway.description')}</CardDescription>
      </CardHeader>
      <CardContent>
        <FieldGroup>
          <div className="flex flex-wrap items-center gap-3">
            <Badge>
              {t(status?.pending ? 'gateway.pending' : status?.active ? 'gateway.enabled' : 'gateway.disabled')}
            </Badge>
            {status?.candidate && <Badge>{t('gateway.candidate')}</Badge>}
            {expiresSoon && <Badge variant="destructive">{t('gateway.expiresSoon')}</Badge>}
          </div>
          <FieldDescription>{stepHelp}</FieldDescription>
          {status?.active && status.candidate && (
            <FieldDescription>
              {t('gateway.activeAddress', { admin: status.active.admin_url, s3: status.active.s3_url })}
            </FieldDescription>
          )}
          {status?.error && <FieldDescription>{status.error}</FieldDescription>}
          <FieldDescription>{t('gateway.dnsHelp')}</FieldDescription>
          <Field>
            <FieldLabel htmlFor="gateway-listen">{t('gateway.listen')}</FieldLabel>
            <Input id="gateway-listen" value={draft.listen_address} disabled={busy || !status || status.pending}
              onChange={event => setDraft({ ...draft, listen_address: event.target.value })} />
            <FieldDescription>{t('gateway.portHelp')}</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="gateway-admin">{t('gateway.adminDomain')}</FieldLabel>
            <Input id="gateway-admin" value={draft.admin_domain} disabled={busy || !status || status.pending}
              onChange={event => setDraft({ ...draft, admin_domain: event.target.value })} />
          </Field>
          <Field>
            <FieldLabel htmlFor="gateway-s3">{t('gateway.s3Domain')}</FieldLabel>
            <Input id="gateway-s3" value={draft.s3_domain} disabled={busy || !status || status.pending}
              onChange={event => setDraft({ ...draft, s3_domain: event.target.value })} />
          </Field>
          <Field>
            <FieldLabel htmlFor="gateway-resolution-ip">{t('gateway.resolutionIP')}</FieldLabel>
            <Input
              id="gateway-resolution-ip"
              value={draft.resolution_ip ?? '127.0.0.1'}
              placeholder="192.168.1.20"
              disabled={busy || !status || status.pending}
              onChange={event => setDraft({ ...draft, resolution_ip: event.target.value })}
            />
            <FieldDescription>{t('gateway.resolutionIPHelp')}</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="gateway-port">{t('gateway.externalPort')}</FieldLabel>
            <Input id="gateway-port" type="number" min={1} max={65535} value={draft.external_port}
              disabled={busy || !status || status.pending}
              onChange={event => setDraft({ ...draft, external_port: Number(event.target.value) })} />
          </Field>
          <Field>
            <FieldLabel id="gateway-certificate-label">{t('gateway.certificateMode')}</FieldLabel>
            <RadioGroup value={draft.certificate_mode} aria-labelledby="gateway-certificate-label"
              disabled={busy || !status || status.pending}
              onValueChange={value => setDraft({ ...draft, certificate_mode: value as 'local' | 'import' })}>
              <Field orientation="horizontal">
                <RadioGroupItem id="gateway-local" value="local" />
                <FieldLabel htmlFor="gateway-local">{t('gateway.localCA')}</FieldLabel>
              </Field>
              <Field orientation="horizontal">
                <RadioGroupItem id="gateway-import" value="import" />
                <FieldLabel htmlFor="gateway-import">{t('gateway.importCertificate')}</FieldLabel>
              </Field>
            </RadioGroup>
          </Field>
          {draft.certificate_mode === 'import' && <>
            <Field>
              <FieldLabel htmlFor="gateway-chain">{t('gateway.certificatePEM')}</FieldLabel>
              <Textarea id="gateway-chain" value={certificate} rows={5} disabled={busy}
                onChange={event => setCertificate(event.target.value)} />
            </Field>
            <Field>
              <FieldLabel htmlFor="gateway-key">{t('gateway.privateKeyPEM')}</FieldLabel>
              <Textarea id="gateway-key" value={privateKey} rows={5} disabled={busy} autoComplete="off" spellCheck={false}
                onChange={event => setPrivateKey(event.target.value)} />
              <FieldDescription>{t('gateway.keyHelp')}</FieldDescription>
            </Field>
          </>}
          <Button disabled={busy || !status || status.pending} onClick={() => void prepare()}>
            {t('gateway.prepare')}
          </Button>
          {status?.ca_fingerprint && <>
            <FieldDescription>{t('gateway.trustHelp')}</FieldDescription>
            <FieldDescription className="break-all">
              {t('gateway.fingerprint', { value: status.ca_fingerprint })}
            </FieldDescription>
            {status.ca_expires_at && <FieldDescription>
              {t('gateway.caExpires', { value: formatDateTime(status.ca_expires_at) })}
            </FieldDescription>}
            <Button variant="outline" asChild>
              <a href="/api/v1/settings/gateway/ca.crt" download>{t('gateway.downloadCA')}</a>
            </Button>
          </>}
          {status?.local_dns?.supported && (
            <FieldGroup>
              <FieldLabel>{t(windowsSetup ? 'gateway.windowsSetupTitle' : 'gateway.localSetupTitle')}</FieldLabel>
              <div className="flex flex-wrap gap-2">
                {!windowsSetup && <Badge>{t(status.local_dns.running ? 'gateway.dnsRunning' : 'gateway.dnsStopped')}</Badge>}
                <Badge>{t(status.local_dns.resolver_installed ? 'gateway.resolverInstalled' : 'gateway.resolverMissing')}</Badge>
              </div>
              <FieldDescription>{t(windowsSetup ? 'gateway.windowsSetupHelp' : 'gateway.localSetupHelp')}</FieldDescription>
              {status.local_dns.error && <FieldDescription>{status.local_dns.error}</FieldDescription>}
              {displayed?.config.certificate_mode === 'local' && (
                <Button variant="outline" asChild>
                  <a href={windowsSetup ? '/api/v1/settings/gateway/local-setup.ps1' : '/api/v1/settings/gateway/local-setup.sh'} download>
                    {t(windowsSetup ? 'gateway.downloadWindowsSetup' : 'gateway.downloadSetup')}
                  </a>
                </Button>
              )}
              <FieldDescription>{t('gateway.installCommand')}</FieldDescription>
              <code className="break-all">{t(windowsSetup ? 'gateway.windowsInstallShell' : 'gateway.installShell')}</code>
              <FieldDescription>{t('gateway.uninstallCommand')}</FieldDescription>
              <code className="break-all">{t(windowsSetup ? 'gateway.windowsUninstallShell' : 'gateway.uninstallShell')}</code>
              <Button variant="outline" disabled={busy} onClick={() => void perform(async () => {
                setStatus(await api.gatewayStatus())
              })}>{t('gateway.refreshLocalStatus')}</Button>
            </FieldGroup>
          )}
          {displayed && <>
            <FieldDescription>{t('gateway.previewHelp')}</FieldDescription>
            <div className="flex flex-col gap-2">
              {[displayed.admin_url, displayed.s3_url].map(endpoint => (
                <div key={endpoint} className="flex flex-wrap items-center gap-2">
                  <a href={endpoint} target="_blank" rel="noreferrer" className="break-all">
                    {endpoint}
                  </a>
                  <EndpointCheck
                    endpoint={endpoint}
                    deploymentId={displayed.id}
                    disabled={busy}
                  />
                </div>
              ))}
              <FieldDescription>{t('gateway.expires', { value: formatDateTime(displayed.expires_at) })}</FieldDescription>
              {displayed.dns_names && (
                <FieldDescription>
                  {t('gateway.certificateDomains', { domains: displayed.dns_names.join(', ') })}
                </FieldDescription>
              )}
              <FieldDescription className="break-all">
                {t('gateway.serverFingerprint', { value: displayed.fingerprint })}
              </FieldDescription>
              <FieldDescription>
                {t(displayed.config.certificate_mode === 'local'
                  ? 'gateway.automaticRenewal'
                  : 'gateway.manualRenewal')}
              </FieldDescription>
            </div>
            <FieldDescription>{t('gateway.proxyHelp')}</FieldDescription>
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" disabled={busy} onClick={() => void perform(async () => {
                setStatus(await api.gatewayAction('check', { revision: status!.revision }))
                toast(t('gateway.serverCheckPassed'))
              })}>{t('gateway.serverCheck')}</Button>
              <Button variant="outline" disabled={busy || draftChanged} onClick={() => void checkClient()}>
                {t('gateway.clientCheck')}
              </Button>
            </div>
          </>}
          {(status?.candidate || status?.pending) && <div className="flex flex-wrap gap-2">
            <Button disabled={busy || (!status.pending && (draftChanged || verified !== status.candidate?.id))}
              onClick={() => void apply()}>{t(status.pending ? 'gateway.retryApply' : 'gateway.apply')}</Button>
            <Button variant="outline" disabled={busy} onClick={() => void perform(async () => {
              setStatus(await api.gatewayAction('rollback', { revision: status.revision }))
              setVerified('')
              await onSaved()
              toast(t('gateway.rolledBack'))
            })}>{t('gateway.rollback')}</Button>
          </div>}
          {status?.active && !status.pending && <Field>
            <FieldLabel htmlFor="gateway-fallback">{t('gateway.fallback')}</FieldLabel>
            <Input
              id="gateway-fallback"
              value={fallback}
              disabled={busy}
              onChange={event => setFallback(event.target.value)}
            />
            <FieldDescription>{t('gateway.fallbackHelp')}</FieldDescription>
            <Button variant="outline" disabled={busy || !fallback.trim()} onClick={() => void apply(true)}>
              {t('gateway.disable')}
            </Button>
          </Field>}
        </FieldGroup>
      </CardContent>
    </Card>
  )
}
