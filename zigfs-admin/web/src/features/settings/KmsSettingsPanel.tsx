import { KmsKeysPanel } from './KmsKeysPanel'
import type { ApiClient, KmsStatus } from '@/api/client'
import { Play, RefreshCw } from 'lucide-react'
import { useEffect, useRef, useState, type Dispatch, type ReactNode, type SetStateAction } from 'react'
import { useToast, useErrorToast } from '@/components/ToastProvider'
import { t } from '@/locales'
import { useConfirm } from '@/components/ConfirmProvider'
import { DropdownMenu, DropdownMenuContent, DropdownMenuGroup, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Badge } from '@/components/ui/Badge'
import { Button } from '@/components/ui/Button'
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/Card'
import { Checkbox } from '@/components/ui/checkbox'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { Field, FieldDescription, FieldGroup, FieldLabel, FieldLegend, FieldSet } from '@/components/ui/field'
import { Input } from '@/components/ui/Input'
import { OptionSelect } from '@/components/ui/OptionSelect'
import { Separator } from '@/components/ui/separator'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'

export function createKmsDraft() {
  return {
    backend: 'vault', defaultKey: '', staticSecretKey: '',
    localKeyDirectory: '', filePermissions: '384', localCacheEnabled: false,
    address: '', token: '', namespace: '', mountPath: 'transit',
    kvMount: 'secret', keyPathPrefix: 'zigfs/kms/keys',
    skipTlsVerification: false, caCertificatePath: '', clientCertificatePath: '', clientKeyPath: '',
    timeoutSeconds: '30', retryCount: '3', cacheEnabled: true, cacheTtlSeconds: '3600', cacheCapacity: '1000',
  }
}
export type KmsDraft = ReturnType<typeof createKmsDraft>
type TextKey = { [K in keyof KmsDraft]: KmsDraft[K] extends string ? K : never }[keyof KmsDraft]

export function KmsSettingsPanel({ api, status, setStatus, draft, setDraft }: {
  api: ApiClient
  status: KmsStatus | null
  setStatus: (status: KmsStatus) => void
  draft: KmsDraft
  setDraft: Dispatch<SetStateAction<KmsDraft>>
}) {
  const [busy, setBusy] = useState(false)
  const notifyError = useErrorToast()
  const [attempted, setAttempted] = useState(false)
  const [tlsOpen, setTlsOpen] = useState(false)
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const [interacted, setInteracted] = useState(() => JSON.stringify(draft) !== JSON.stringify(status?.config ?? createKmsDraft()))
  const errorSummary = useRef<HTMLDivElement>(null)
  const toast = useToast()
  const confirm = useConfirm()
  const hasServiceError = status?.state === 'error'
  const running = status?.state === 'running'
  const backendName = status?.configured ? ({ local: 'Local', static: 'Static', vault: 'VaultTransit', 'vault-kv2': 'VaultKV2' }[status.config.backend] ?? status.config.backend) : t('settings.kmsNotConfigured')
  const stateLabel = hasServiceError ? t('settings.kmsStateError') : running ? t('settings.kmsStateRunning') : status?.configured ? t('settings.kmsConfigured') : t('settings.kmsNotConfigured')
  const startKms = async () => {
    if (busy || !status?.configured) return
    if (!await confirm({ title: running ? t('settings.kmsRestart') : t('settings.kmsStart'), message: t('settings.kmsStateChangeConfirmation') })) return
    setBusy(true)
    try {
      setStatus(await api.startKms())
      toast(t('settings.kmsStarted'))
    } catch (error) {
      notifyError(t(running ? 'settings.kmsRestartFailed' : 'settings.kmsStartFailed', { reason: error instanceof Error ? error.message : t('settings.kmsRequestFailed') }))
      try { setStatus(await api.kmsSettings()) } catch { /* Preserve the action error when status refresh also fails. */ }
    } finally { setBusy(false) }
  }
  const controlKms = async (action: 'stop' | 'clearCache') => {
    if (busy || !running) return
    if (action === 'stop' && !await confirm({ title: t('settings.kmsStop'), message: t('settings.kmsStateChangeConfirmation'), danger: true })) return
    setBusy(true)
    try {
      setStatus(await (action === 'stop' ? api.stopKms() : api.clearKmsCache()))
      toast(t(action === 'stop' ? 'settings.kmsStopped' : 'settings.kmsCacheCleared'))
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) }
    finally { setBusy(false) }
  }
  useEffect(() => setAttempted(false), [draft.backend])
  const validationDraft = {
    ...draft,
    token: draft.token || (status?.config.backend === draft.backend && status.tokenConfigured ? 'stored-token' : ''),
    staticSecretKey: draft.staticSecretKey || (status?.config.backend === draft.backend && status.staticSecretKeyConfigured ? btoa(String.fromCharCode(...new Uint8Array(32))) : ''),
  }
  const errors = attempted ? validateKmsDraft(validationDraft) : {}
  const errorEntries = Object.entries(errors)
  const firstErrorKey = errorEntries[0]?.[0]
  useEffect(() => {
    if (['caCertificatePath', 'clientCertificatePath', 'clientKeyPath'].includes(firstErrorKey)) setTlsOpen(true)
    if (['timeoutSeconds', 'retryCount', 'cacheCapacity', 'cacheTtlSeconds'].includes(firstErrorKey)) setAdvancedOpen(true)
  }, [firstErrorKey])
  const submit = async () => {
    if (!interacted || busy || !status) return
    setAttempted(true)
    const validationErrors = validateKmsDraft(validationDraft)
    if (Object.keys(validationErrors).length) {
      if (validationErrors.caCertificatePath || validationErrors.clientCertificatePath || validationErrors.clientKeyPath) setTlsOpen(true)
      if (validationErrors.timeoutSeconds || validationErrors.retryCount || validationErrors.cacheCapacity || validationErrors.cacheTtlSeconds) setAdvancedOpen(true)
      requestAnimationFrame(() => {
        errorSummary.current?.scrollIntoView({ block: 'nearest' })
        const firstInvalid = errorSummary.current?.closest('form')?.querySelector<HTMLInputElement>('input[aria-invalid="true"]')
        firstInvalid?.focus({ preventScroll: true })
        firstInvalid?.scrollIntoView({ block: 'nearest' })
      })
      return
    }
    setBusy(true)
    try {
      const saved = await api.saveKmsSettings(draft)
      setStatus(saved); setDraft(saved.config); setInteracted(false); setAttempted(false)
      toast(t('settings.kmsSaved'))
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) } finally { setBusy(false) }
  }
  const refreshStatus = async () => {
    setBusy(true)
    try { const loaded = await api.kmsSettings(); setStatus(loaded); if (!status || loaded.configured) { setDraft(loaded.config); setInteracted(false); setAttempted(false) } }
    catch (error) { notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) } finally { setBusy(false) }
  }
  const localBackend = draft.backend === 'local'
  const cacheEnabled = localBackend ? draft.localCacheEnabled : draft.cacheEnabled
  const update = <K extends keyof KmsDraft>(key: K, value: KmsDraft[K]) => {
    setInteracted(true)
    setDraft(current => ({ ...current, [key]: value }))
  }
  const textField = (key: TextKey, label: string, help?: string, placeholder?: string, type = 'text', max?: number) => (
    <Field key={key} data-invalid={Boolean(errors[key]) || undefined}>
      <FieldLabel htmlFor={`kms-${key}`}>{label}</FieldLabel>
      <Input id={`kms-${key}`} type={type} value={draft[key]} disabled={busy || !status} placeholder={type === 'password' && status?.config.backend === draft.backend && ((key === 'token' && status.tokenConfigured) || (key === 'staticSecretKey' && status.staticSecretKeyConfigured)) ? t('settings.kmsSecretUnchanged') : placeholder}
        autoComplete={type === 'password' ? 'new-password' : 'off'} spellCheck={false}
        min={type === 'number' ? key === 'retryCount' || key === 'filePermissions' ? 0 : 1 : undefined} max={max}
        aria-invalid={Boolean(errors[key]) || undefined}
        aria-describedby={[help && `kms-${key}-help`, errors[key] && `kms-error-${key}`].filter(Boolean).join(' ') || undefined}
        onChange={event => update(key, event.target.value)} />
      {help && <FieldDescription id={`kms-${key}-help`}>{help}</FieldDescription>}
    </Field>
  )

  return <div className="settings-detail-stack kms-settings">
    <div className="kms-heading">
      <h3>{t('settings.sseConfiguration')}</h3>
      <p>{t('settings.sseConfigurationDescription')}</p>
    </div>
    <Card>
      <CardHeader>
        <div className="kms-status-heading"><CardTitle>{t('settings.kmsStatusOverview')}</CardTitle><Badge variant={hasServiceError ? 'destructive' : 'default'}>{stateLabel.toLocaleUpperCase()}</Badge>
          {running && ['local', 'static'].includes(status?.config.backend ?? '') && <Badge variant="destructive">{t('settings.kmsDevelopmentBackend')}</Badge>}
        </div>
        <CardDescription>{hasServiceError ? t('settings.kmsServerError') : running ? t('settings.kmsServerRunning') : status?.configured ? t('settings.kmsServerStopped') : t('settings.kmsServerNotConfigured')}</CardDescription>
        {status?.configured && <CardDescription>{t('settings.kmsBackendSummary', { backend: backendName })}</CardDescription>}
      </CardHeader>
      <CardContent className="kms-status-grid">
        {[
          [t('settings.kmsBackendType'), backendName],
          [t('settings.kmsStatus'), stateLabel],
          [t('settings.kmsHealth'), status?.configured && status.healthChecked && !hasServiceError ? (status.healthy ? t('settings.kmsHealthy') : t('settings.kmsUnhealthy')) : t('settings.kmsUnknown')],
          [t('settings.kmsDefaultKey'), status?.config.defaultKey || t('settings.kmsNotSet')],
        ].map(([label, value]) => <Card key={label}><CardHeader><CardDescription>{label}</CardDescription><CardTitle>{value}</CardTitle></CardHeader></Card>)}
      </CardContent>
      {status?.configured && !running && !hasServiceError && <CardContent>
        <Alert><AlertTitle>{t('settings.kmsConfiguredNotStarted')}</AlertTitle><AlertDescription>{t('settings.kmsStartHelp')}</AlertDescription></Alert>
      </CardContent>}
      {hasServiceError && status.errorMessage && <CardContent>
        <Alert variant="destructive"><AlertTitle>{t('settings.kmsServiceError')}</AlertTitle><AlertDescription>{status.errorMessage}</AlertDescription></Alert>
      </CardContent>}
      <CardFooter className="kms-status-actions">
        <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void refreshStatus()}><RefreshCw data-icon="inline-start" />{t('settings.kmsRefresh')}</Button>
        <Button type="button" size="sm" disabled={busy || !status?.configured} onClick={() => void startKms()}>{running ? t('settings.kmsRestart') : t('settings.kmsStart')}</Button>
        <DropdownMenu><DropdownMenuTrigger asChild><Button type="button" variant="outline" size="sm" disabled={busy || !running}>{t('settings.kmsAdvancedActions')}</Button></DropdownMenuTrigger>
          <DropdownMenuContent align="end"><DropdownMenuGroup>
            <DropdownMenuItem onSelect={() => void controlKms('clearCache')}>{t('settings.kmsClearCache')}</DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" onSelect={() => void controlKms('stop')}>{t('settings.kmsStop')}</DropdownMenuItem>
          </DropdownMenuGroup></DropdownMenuContent>
        </DropdownMenu>
      </CardFooter>
    </Card>
    <Card>
      <CardHeader><CardTitle>{t('settings.kmsConfiguration')}</CardTitle><CardDescription>{t('settings.kmsConfigurationDescription')}</CardDescription></CardHeader>
      <CardContent>
        <form id="kms-configuration-form" className="kms-form" noValidate onClick={() => setInteracted(true)} onSubmit={event => { event.preventDefault(); void submit() }}>
          {errorEntries.length > 0 && <Alert ref={errorSummary} tabIndex={-1} variant="destructive" aria-labelledby="kms-form-errors-title">
            <AlertTitle id="kms-form-errors-title">{t('settings.kmsFormErrorsTitle')}</AlertTitle>
            <AlertDescription><ul className="kms-form-errors">{errorEntries.map(([key, message]) => <li key={key} id={`kms-error-${key}`}>{message}</li>)}</ul></AlertDescription>
          </Alert>}
          {localBackend && <Alert><AlertTitle>{t('settings.kmsLocalWarningTitle')}</AlertTitle><AlertDescription>{t('settings.kmsLocalWarning')}</AlertDescription></Alert>}
          <FieldSet>
            <FieldLegend className="kms-section-title">{t('settings.kmsBackendAndDefaultKey')}<Separator /></FieldLegend>
            <FieldGroup className="kms-field-grid">
              <Field>
                <FieldLabel htmlFor="kms-backend">{t('settings.kmsBackend')}</FieldLabel>
                <OptionSelect id="kms-backend" value={draft.backend} disabled={busy || !status} onValueChange={value => update('backend', value)}
                  aria-describedby="kms-backend-help" options={[
                    { value: 'local', label: t('settings.kmsLocalFilesystemOption') },
                    { value: 'vault-kv2', label: t('settings.kmsVaultKv2') },
                    { value: 'vault', label: t('settings.kmsVaultTransit') },
                    { value: 'static', label: t('settings.kmsStaticSingleKey') },
                  ]} />
                <FieldDescription id="kms-backend-help">{t('settings.kmsBackendHelp')}</FieldDescription>
              </Field>
              {textField('defaultKey', t('settings.kmsDefaultKey'), t('settings.kmsDefaultKeyHelp'), t('settings.kmsDefaultKeyPlaceholder'))}
            </FieldGroup>
          </FieldSet>
          {localBackend ? <FieldSet>
            <FieldLegend className="kms-section-title">{t('settings.kmsLocalFilesystem')}<Separator /></FieldLegend>
            <FieldGroup className="kms-field-grid">
              {textField('localKeyDirectory', t('settings.kmsLocalKeyDirectory'), t('settings.kmsLocalKeyDirectoryHelp'), t('settings.kmsLocalKeyDirectoryPlaceholder'))}
              {textField('filePermissions', t('settings.kmsFilePermissions'), t('settings.kmsFilePermissionsHelp'), undefined, 'number', 511)}
            </FieldGroup>
          </FieldSet> : draft.backend === 'static' ? <FieldSet>
            <FieldLegend className="kms-section-title">{t('settings.kmsStaticKeyConfiguration')}<Separator /></FieldLegend>
            <FieldGroup className="kms-field-grid">
              {textField('staticSecretKey', t('settings.kmsStaticSecretKey'), t('settings.kmsStaticSecretKeyHelp'), t('settings.kmsStaticSecretKeyPlaceholder'), 'password')}
            </FieldGroup>
          </FieldSet> : <>
            <FieldSet>
              <FieldLegend className="kms-section-title">{t('settings.kmsVaultConnection')}<Separator /></FieldLegend>
              <Alert><AlertTitle>{t('settings.kmsTokenOnly')}</AlertTitle><AlertDescription>{t('settings.kmsTokenOnlyHelp')}</AlertDescription></Alert>
              <FieldGroup className="kms-field-grid">
                {textField('address', t('settings.kmsVaultAddress'), undefined, 'http://127.0.0.1:8200', 'url')}
                {textField('token', t('settings.kmsVaultToken'), t('settings.kmsVaultTokenHelp'), t('settings.kmsVaultTokenPlaceholder'), 'password')}
                {textField('namespace', t('settings.kmsVaultNamespace'), undefined, t('settings.kmsVaultNamespacePlaceholder'))}
                {textField('mountPath', t('settings.kmsTransitMountPath'))}
                {draft.backend === 'vault-kv2' && <>
                  {textField('kvMount', t('settings.kmsKvMount'))}
                  {textField('keyPathPrefix', t('settings.kmsKeyPathPrefix'))}
              </>}
            </FieldGroup>
            <Field orientation="horizontal">
              <Checkbox id="kms-skip-tls" disabled={busy || !status} checked={draft.skipTlsVerification} onCheckedChange={value => update('skipTlsVerification', value === true)} />
              <FieldLabel htmlFor="kms-skip-tls">{t('settings.kmsSkipTlsVerification')}</FieldLabel>
            </Field>
          </FieldSet>
          <AdvancedSection open={tlsOpen} onOpenChange={setTlsOpen} title={t('settings.kmsAdvancedTls')} description={t('settings.kmsAdvancedTlsDescription')}>
            <FieldGroup>
              <FieldGroup className="kms-field-grid">
                {textField('caCertificatePath', t('settings.kmsCaCertificate'), t('settings.kmsCaCertificateHelp'), '/etc/zigfs/certs/vault-ca.pem')}
                {textField('clientCertificatePath', t('settings.kmsClientCertificate'), t('settings.kmsClientCertificateHelp'), '/etc/zigfs/certs/vault-client.pem')}
                {textField('clientKeyPath', t('settings.kmsClientKey'), t('settings.kmsClientKeyHelp'), '/etc/zigfs/certs/vault-client.key')}
              </FieldGroup>
              <FieldDescription>{t('settings.kmsTlsPathsHelp')}</FieldDescription>
            </FieldGroup>
          </AdvancedSection>
          </>}
          <Separator />
          <AdvancedSection open={advancedOpen} onOpenChange={setAdvancedOpen} title={t('settings.kmsAdvancedSettings')} description={t('settings.kmsAdvancedSettingsDescription')}>
            <FieldGroup>
              <FieldSet>
                <FieldLegend>{t('settings.kmsReliability')}</FieldLegend>
                <FieldGroup className="kms-field-grid kms-reliability-grid">
                  {textField('timeoutSeconds', t('settings.kmsTimeoutSeconds'), undefined, undefined, 'number', 300)}
                  {textField('retryCount', t('settings.kmsRetryCount'), undefined, undefined, 'number', 10)}
                </FieldGroup>
              </FieldSet>
              <FieldSet>
                <FieldLegend className="kms-section-title">{t('settings.kmsCache')}<Separator /></FieldLegend>
                <Field orientation="horizontal">
                  <Checkbox id="kms-cache-enabled" disabled={busy || !status} checked={cacheEnabled} onCheckedChange={value => update(localBackend ? 'localCacheEnabled' : 'cacheEnabled', value === true)} />
                  <FieldLabel htmlFor="kms-cache-enabled">{t('settings.kmsEnableCache')}</FieldLabel>
                </Field>
                {cacheEnabled && <FieldSet>
                  <FieldGroup className="kms-field-grid">
                    {textField('cacheCapacity', t('settings.kmsCacheCapacity'), undefined, undefined, 'number', 100000)}
                    {textField('cacheTtlSeconds', t('settings.kmsCacheTtlSeconds'), undefined, undefined, 'number', 86400)}
                  </FieldGroup>
                </FieldSet>}
              </FieldSet>
            </FieldGroup>
          </AdvancedSection>
        </form>
      </CardContent>
      <CardFooter className="kms-form-actions">
        <div>
          <Button type="button" variant="outline" disabled={!interacted || busy || !status} onClick={() => { setAttempted(false); setInteracted(false); setDraft(status?.config ?? createKmsDraft()) }}>{t('settings.kmsReset')}</Button>
          <Button type="submit" form="kms-configuration-form" disabled={!interacted || busy || !status}>{status?.configured ? t('settings.kmsReconfigure') : t('settings.kmsSave')}</Button>
        </div>
      </CardFooter>
    </Card>
    {running && <KmsKeysPanel api={api} onDefaultChanged={async () => {
      const saved = await api.kmsSettings()
      setStatus(saved)
      setDraft(current => ({ ...current, defaultKey: saved.config.defaultKey }))
    }} />}
  </div>
}

function AdvancedSection({ title, description, children, open, onOpenChange }: { title: string; description: string; children: ReactNode; open: boolean; onOpenChange: (open: boolean) => void }) {
  return <Collapsible className="kms-advanced" open={open} onOpenChange={onOpenChange}>
    <CollapsibleTrigger asChild><Button type="button" variant="ghost" className="kms-advanced-trigger"><Play data-icon="inline-start" aria-hidden="true" fill="currentColor" strokeWidth={0} /><span>{title}</span><span className="kms-advanced-description">{description}</span></Button></CollapsibleTrigger>
    <CollapsibleContent className="kms-advanced-content">{children}</CollapsibleContent>
  </Collapsible>
}


type KmsErrors = Partial<Record<TextKey, string>>

function validateKmsDraft(draft: KmsDraft): KmsErrors {
  const errors: KmsErrors = {}
  const absolutePath = (value: string) => /^(?:\/|[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)/.test(value.trim()) && !/[\x00-\x1f]/.test(value)
  const relativePath = (value: string) => value.trim().length > 0 && value.trim().split('/').every(part => part.length > 0 && part !== '.' && part !== '..' && !/[\s\\?#]/.test(part))
  const number = (key: TextKey, label: string, minimum: number, maximum: number) => {
    const value = draft[key].trim()
    if (!/^\d+$/.test(value) || Number(value) < minimum || Number(value) > maximum) {
      errors[key] = t('settings.kmsInvalidNumber', { field: label, min: minimum, max: maximum })
    }
  }
  if (draft.backend === 'local') {
    if (!absolutePath(draft.localKeyDirectory)) errors.localKeyDirectory = t('settings.kmsInvalidLocalDirectory')
    number('filePermissions', t('settings.kmsFilePermissions'), 0, 511)
  } else if (draft.backend === 'static') {
    const key = draft.staticSecretKey.trim()
    try {
      if (!/^[A-Za-z0-9+/]{43}=$/.test(key) || atob(key).length !== 32 || btoa(atob(key)) !== key) throw new Error()
    } catch {
      errors.staticSecretKey = t('settings.kmsInvalidStaticKey')
    }
  } else {
    try {
      const url = new URL(draft.address.trim())
      if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) throw new Error()
    } catch {
      errors.address = t('settings.kmsInvalidVaultAddress')
    }
    if (!draft.token.trim()) errors.token = t('settings.kmsMissingVaultToken')
    if (!relativePath(draft.mountPath)) errors.mountPath = t('settings.kmsInvalidMountPath')
    if (draft.backend === 'vault-kv2') {
      if (!relativePath(draft.kvMount)) errors.kvMount = t('settings.kmsInvalidKvMount')
      if (draft.keyPathPrefix.trim() && !relativePath(draft.keyPathPrefix)) errors.keyPathPrefix = t('settings.kmsInvalidKeyPrefix')
    }
    for (const [key, label] of [
      ['caCertificatePath', t('settings.kmsCaCertificate')],
      ['clientCertificatePath', t('settings.kmsClientCertificate')],
      ['clientKeyPath', t('settings.kmsClientKey')],
    ] as const) {
      if (draft[key].trim() && !absolutePath(draft[key])) errors[key] = t('settings.kmsInvalidTlsPath', { field: label })
    }
    if (Boolean(draft.clientCertificatePath.trim()) !== Boolean(draft.clientKeyPath.trim())) {
      errors[draft.clientCertificatePath.trim() ? 'clientKeyPath' : 'clientCertificatePath'] = t('settings.kmsClientIdentityPairRequired')
    }
  }
  number('timeoutSeconds', t('settings.kmsTimeoutSeconds'), 1, 300)
  number('retryCount', t('settings.kmsRetryCount'), 0, 10)
  if (draft.backend === 'local' ? draft.localCacheEnabled : draft.cacheEnabled) {
    number('cacheCapacity', t('settings.kmsCacheCapacity'), 1, 100000)
    number('cacheTtlSeconds', t('settings.kmsCacheTtlSeconds'), 1, 86400)
  }
  // Match field order, including errors added later by cross-field validation.
  const fieldOrder: TextKey[] = [
    'localKeyDirectory', 'filePermissions', 'staticSecretKey',
    'address', 'token', 'mountPath', 'kvMount', 'keyPathPrefix',
    'caCertificatePath', 'clientCertificatePath', 'clientKeyPath',
    'timeoutSeconds', 'retryCount', 'cacheCapacity', 'cacheTtlSeconds',
  ]
  const firstInvalid = fieldOrder.find(key => errors[key])
  return firstInvalid ? { [firstInvalid]: errors[firstInvalid] } : {}
}
