import { AnonymousAccess } from './AnonymousAccess'
import { formatDateTime } from '@/lib/dateTime'
import { Textarea } from '../../components/ui/Textarea'
import { Alert, AlertTitle, AlertDescription } from '../../components/ui/alert'
import { OptionSelect } from '../../components/ui/OptionSelect'
import { t, getFormatLocale, displayValue } from '@/locales'
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import {
  Archive,
  ArrowLeft,
  Gauge,
  KeyRound,
  LockKeyhole,
  Pencil,
  Plus,
  Shield,
  Tags,
  Trash2,
  X,
} from 'lucide-react'
import { type ApiClient, type KmsKey } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import type { Bucket, BucketConfiguration } from '../../types/api'
import { Button } from '../../components/ui/Button'
import { Badge } from '../../components/ui/Badge'
import { Switch } from '../../components/ui/switch'
import { RadioGroup, RadioGroupItem } from '../../components/ui/radio-group'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '../../components/ui/field'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { BucketEvents } from './BucketEvents'
import { LifecycleRulesEditor } from './LifecycleRulesEditor'
import { parseLifecycleConfiguration, serializeLifecycleConfiguration, type LifecycleRule } from './lifecycle'

interface BucketDetailViewProps {
  api: ApiClient
  bucketName: string
  onBack: () => void
}

interface BucketUsage {
  bytes: number
  objects: number
}

const sections = ['Summary', 'Events', 'Lifecycle', 'Anonymous'] as const

export function BucketDetailView({ api, bucketName, onBack }: BucketDetailViewProps) {
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [bucket, setBucket] = useState<Bucket | null>(null)
  const [configuration, setConfiguration] = useState<BucketConfiguration | null>(null)
  const [activeSection, setActiveSection] = useState<(typeof sections)[number]>('Summary')
  const [lifecycleRules, setLifecycleRules] = useState<LifecycleRule[]>([])
  const [tags, setTags] = useState<Record<string, string>>({})
  const [tagKey, setTagKey] = useState('')
  const [tagValue, setTagValue] = useState('')
  const [tagDialogOpen, setTagDialogOpen] = useState(false)
  const [policyDocument, setPolicyDocument] = useState('')
  const [policyDraft, setPolicyDraft] = useState('')
  const [policyReady, setPolicyReady] = useState(false)
  const [accessPolicyDialogOpen, setAccessPolicyDialogOpen] = useState(false)
  const [accessPolicyDraft, setAccessPolicyDraft] = useState<'Private' | 'Readonly' | 'Public' | 'Custom'>('Private')
  const [encryptionDialogOpen, setEncryptionDialogOpen] = useState(false)
  const [encryptionDraft, setEncryptionDraft] = useState<'Disabled' | 'Enabled' | 'KMS'>('Disabled')
  const [kmsKeyDraft, setKmsKeyDraft] = useState('')
  const [kmsKeys, setKmsKeys] = useState<KmsKey[]>([])
  const [kmsKeysLoading, setKmsKeysLoading] = useState(false)
  const [kmsKeysReady, setKmsKeysReady] = useState(false)
  const [kmsKeysFailed, setKmsKeysFailed] = useState(false)
  const [kmsKeysRefresh, setKmsKeysRefresh] = useState(0)
  const [retentionDialogOpen, setRetentionDialogOpen] = useState(false)
  const [retentionDraft, setRetentionDraft] = useState({ mode: 'GOVERNANCE' as 'GOVERNANCE' | 'COMPLIANCE', period: '1', unit: 'day' })
  const [quotaDialogOpen, setQuotaDialogOpen] = useState(false)
  const [quotaEnabled, setQuotaEnabled] = useState(false)
  const [quotaUnit, setQuotaUnit] = useState(1024 ** 3)
  const [quotaBytes, setQuotaBytes] = useState('')
  const [quotaObjects, setQuotaObjects] = useState('')
  const [usage, setUsage] = useState<BucketUsage>({ bytes: 0, objects: 0 })
  const [loading, setLoading] = useState(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    if (!bucketName) return
    const stopLoading = startLoading(t('buckets.loadingBucketConfiguration'))
    try {
      setLoading(true)
      const [buckets, bucketConfiguration, bucketUsage] = await Promise.all([
        api.listBuckets(),
        api.getBucketConfiguration(bucketName),
        api.getBucketUsage(bucketName),
      ])
      const current = buckets.find((item) => item.name === bucketName)
      if (!current) throw new Error(t('buckets.bucketValueDoesNotExist', { '0': bucketName }))
      setBucket(current)
      setConfiguration(bucketConfiguration)
      setQuotaBytes(bucketConfiguration.max_bytes == null ? '' : String(bucketConfiguration.max_bytes))
      setQuotaObjects(bucketConfiguration.max_objects == null ? '' : String(bucketConfiguration.max_objects))
      setTags(parseTags(bucketConfiguration.tags_json))
      setLifecycleRules(bucketConfiguration.lifecycle_configuration
        ? parseLifecycleConfiguration(bucketConfiguration.lifecycle_configuration)
        : [])

      setUsage(bucketUsage)
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }, [api, bucketName, startLoading])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function updateVersioning(versioning: 'Enabled' | 'Suspended') {
    if (!configuration || (configuration.object_locking && versioning !== 'Enabled')) return
    const stopLoading = startLoading(t('buckets.updatingVersioning'))
    try {
      setLoading(true)
      setConfiguration(await api.updateBucketConfiguration(bucketName, { versioning }))
      setBucket((current) => current ? { ...current, versioning } : current)
      showToast(t('buckets.versioningUpdatedToValue', { '0': versioning === 'Enabled' ? t('buckets.enabled') : t('buckets.suspended') }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  useEffect(() => {
    let active = true
    setPolicyReady(false)
    api.getBucketPolicy(bucketName).then(result => {
      if (active) { setPolicyDocument(result.document); setPolicyReady(true) }
    }).catch(reason => { if (active) notifyError((reason as Error).message) })
    return () => { active = false }
  }, [api, bucketName, activeSection])

  async function openAccessPolicyDialog() {
    setLoading(true)
    try {
      const result = await api.getBucketPolicy(bucketName)
      setPolicyDocument(result.document)
      setPolicyReady(true)
      setPolicyDraft(result.document || JSON.stringify({ Version: '2012-10-17', Statement: [] }, null, 2))
      setAccessPolicyDraft(result.document ? 'Custom' : configuration?.access_policy ?? 'Private')
      setAccessPolicyDialogOpen(true)
    } catch (reason) { notifyError((reason as Error).message) }
    finally { setLoading(false) }
  }

  async function saveAccessPolicyDialog() {
    if (accessPolicyDraft === 'Custom') {
      try {
        const parsed = JSON.parse(policyDraft)
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) || !Array.isArray(parsed.Statement)) throw new Error()
      } catch { notifyError(t('buckets.invalidPolicyJson')); return }
    }
    setLoading(true)
    let changed = false
    try {
      if (accessPolicyDraft === 'Custom') {
        const result = await api.putBucketPolicy(bucketName, policyDraft)
        setPolicyDocument(result.document)
        changed = true
        setConfiguration(await api.getBucketConfiguration(bucketName))
      } else {
        setConfiguration(await api.updateBucketConfiguration(bucketName, { access_policy: accessPolicyDraft }))
        changed = true
        if (policyDocument) { await api.deleteBucketPolicy(bucketName); setPolicyDocument('') }
      }
      setAccessPolicyDialogOpen(false)
      showToast(t('buckets.bucketPolicySaved'))
    } catch (reason) {
      notifyError(changed ? t('buckets.policyPartiallySaved', { error: (reason as Error).message }) : (reason as Error).message)
    } finally { setLoading(false) }
  }

  useEffect(() => {
    if (!encryptionDialogOpen || encryptionDraft !== 'KMS') return
    let cancelled = false
    setKmsKeysLoading(true)
    setKmsKeysReady(false)
    setKmsKeysFailed(false)
    api.kmsKeys().then(result => {
      if (cancelled) return
      setKmsKeys(result.items.filter(key => key.status === 'Enabled'))
      setKmsKeysReady(true)
    }).catch(reason => {
      if (!cancelled) {
        setKmsKeysFailed(true)
        notifyError((reason as Error).message)
      }
    }).finally(() => {
      if (!cancelled) setKmsKeysLoading(false)
    })
    return () => { cancelled = true }
  }, [api, encryptionDialogOpen, encryptionDraft, kmsKeysRefresh, notifyError])

  async function updateEncryption(encryption: 'Disabled' | 'Enabled' | 'KMS') {
    if (encryption === 'KMS' && (!kmsKeysReady || !kmsKeys.some(key => key.id === kmsKeyDraft))) {
      notifyError(t('buckets.selectKmsKey'))
      return
    }
    const stopLoading = startLoading(t('buckets.updatingEncryption'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, { encryption, kms_key_id: encryption === 'KMS' ? kmsKeyDraft : '' })
      setConfiguration(updated)
      setEncryptionDialogOpen(false)
      showToast(t('buckets.encryptionUpdatedToValue', { '0': encryption === 'KMS' ? 'SSE-KMS' : encryption === 'Enabled' ? t('buckets.sseS3') : t('buckets.disabled') }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  function openRetentionDialog() {
    const seconds = configuration?.retention_duration_seconds ?? 86400
    const unit = seconds % (365 * 86400) === 0 ? 'year' : seconds % 86400 === 0 ? 'day' : 'second'
    setRetentionDraft({ mode: configuration?.retention_mode ?? 'GOVERNANCE', period: String(seconds / (unit === 'year' ? 365 * 86400 : unit === 'day' ? 86400 : 1)), unit })
    setRetentionDialogOpen(true)
  }

  async function saveRetention() {
    const period = Number(retentionDraft.period)
    const duration = period * (retentionDraft.unit === 'year' ? 365 * 86400 : retentionDraft.unit === 'day' ? 86400 : 1)
    if (!Number.isSafeInteger(period) || period <= 0 || !Number.isSafeInteger(duration)) {
      notifyError(t('buckets.valueMustBeAnIntegerGreaterThanZero', { '0': t('buckets.retentionValidity') }))
      return
    }
    await updateRetention({ enabled: true, mode: retentionDraft.mode, duration })
  }

  function openQuotaDialog() {
    const bytes = configuration?.max_bytes
    const units = [1024 ** 5, 1024 ** 4, 1024 ** 3, 1024 ** 2]
    const unit = bytes ? units.find(value => bytes >= value && bytes % value === 0) ?? 1 : 1024 ** 3
    setQuotaEnabled(Boolean(bytes || configuration?.max_objects))
    setQuotaUnit(unit)
    setQuotaBytes(bytes ? String(bytes / unit) : '1')
    setQuotaObjects(configuration?.max_objects == null ? '' : String(configuration.max_objects))
    setQuotaDialogOpen(true)
  }

  async function saveQuota() {
    const parseLimit = (value: string, label: string): number | null | undefined => {
      const trimmed = value.trim()
      if (!trimmed) return null
      const parsed = Number(trimmed)
      if (!Number.isSafeInteger(parsed) || parsed <= 0) {
        notifyError(t('buckets.valueMustBeAnIntegerGreaterThanZero', { '0': label }))
        return undefined
      }
      return parsed
    }
    const maxBytes = quotaEnabled ? parseLimit(quotaBytes.trim() ? String(Number(quotaBytes) * quotaUnit) : '', t('buckets.byteQuota')) : null
    const maxObjects = quotaEnabled ? parseLimit(quotaObjects, t('buckets.objectCountQuota')) : null
    if (maxBytes === undefined || maxObjects === undefined) return
    if (quotaEnabled && maxBytes === null && maxObjects === null) {
      notifyError(t('buckets.quotaLimitRequired'))
      return
    }
    const stopLoading = startLoading(t('buckets.savingQuota'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, {
        max_bytes: maxBytes ?? 0,
        max_objects: maxObjects ?? 0,
      })
      setConfiguration(updated)
      setQuotaBytes(updated.max_bytes == null ? '' : String(updated.max_bytes))
      setQuotaObjects(updated.max_objects == null ? '' : String(updated.max_objects))
      setQuotaDialogOpen(false)
      showToast(t('buckets.quotaSaved'))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function updateRetention(patch: {
    enabled?: boolean
    duration?: number
    mode?: 'GOVERNANCE' | 'COMPLIANCE'
  }) {
    if (!configuration || !configuration.object_locking) return
    const currentEnabled = configuration.retention_enabled
    const currentDuration = configuration.retention_duration_seconds ?? 86400
    const currentMode = configuration.retention_mode ?? 'GOVERNANCE'
    const enabled = currentEnabled || (patch.enabled ?? false)
    const duration = patch.duration ?? currentDuration
    const mode = patch.mode ?? currentMode
    const isShortening = currentEnabled && enabled && duration < currentDuration
    const isEnabling = !currentEnabled && enabled
    const isModeSwitch = currentEnabled && enabled && mode !== currentMode
    if ((isEnabling || isShortening || isModeSwitch) && !await confirm({
      title: t('buckets.confirmRetentionUpdate'),
      message: isEnabling
        ? t('buckets.newObjectsWillBeRetainedForValueSecondsContinue', { '0': duration })
        : isShortening
          ? t('buckets.retentionWillDecreaseFromValueToValueSecondsWhich', { '0': currentDuration, '1': duration })
          : t('buckets.retentionModeWillChangeFromValueToValueContinue', { '0': currentMode, '1': mode }),
      confirmLabel: t('buckets.continueUpdate'),
      danger: isShortening || mode === 'COMPLIANCE',
    })) return

    const stopLoading = startLoading(t('buckets.updatingRetention'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, {
        retention_enabled: enabled,
        retention_duration_seconds: duration,
        retention_mode: mode,
      })
      setConfiguration(updated)
      setRetentionDialogOpen(false)
      showToast(t('buckets.retentionUpdatedToValue', { '0': enabled ? `${duration}s / ${mode}` : t('buckets.disabled') }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function addTag() {
    const key = tagKey.trim()
    if (!key) return
    const next = { ...tags, [key]: tagValue.trim() }
    setTags(next)
    await persistTags(next)
    setTagKey('')
    setTagValue('')
    setTagDialogOpen(false)
  }

  async function persistTags(next: Record<string, string>) {
    const stopLoading = startLoading(t('buckets.savingTags'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, { tags_json: JSON.stringify(next) })
      setConfiguration(updated)
      setTags(parseTags(updated.tags_json))
      showToast(t('buckets.tagsSaved'))
    } catch (reason) { notifyError((reason as Error).message) } finally { setLoading(false); stopLoading() }
  }

  async function saveTags() {
    // Include an entry that is still being edited when the user saves
    // directly, without pressing “添加” first.
    const pendingKey = tagKey.trim()
    const pendingValue = tagValue.trim()
    const tagsToSave = pendingKey ? { ...tags, [pendingKey]: pendingValue } : tags
    const stopLoading = startLoading(t('buckets.savingTags'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, Object.keys(tagsToSave).length > 0
        ? { tags_json: JSON.stringify(tagsToSave) }
        : { clear_tags: true })
      setConfiguration(updated)
      setTags(parseTags(updated.tags_json))
      if (pendingKey) {
        setTagKey('')
        setTagValue('')
      }
      showToast(t('buckets.tagsSaved'))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function saveLifecycle(rules: LifecycleRule[]) {
    const stopLoading = startLoading(t('buckets.savingLifecycleRules'))
    try {
      setLoading(true)
      const updated = rules.length > 0
        ? await api.updateBucketConfiguration(bucketName, {
            lifecycle_configuration: serializeLifecycleConfiguration(rules),
          })
        : await api.updateBucketConfiguration(bucketName, { clear_lifecycle: true })
      setConfiguration(updated)
      setLifecycleRules(rules)
      setBucket((current) => current ? { ...current, lifecycle_enabled: rules.length > 0 } : current)
      showToast(rules.length > 0 ? t('buckets.lifecycleRulesSaved') : t('buckets.lifecycleRulesCleared'))
    } catch (reason) {
      notifyError((reason as Error).message)
      throw reason
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  return (
    <section className="bucket-detail-page">
      <header className="bucket-detail-header">
        <div>
          <div className="bucket-identity">
            <span className="bucket-identity-icon" aria-hidden="true"><Archive /></span>
            <div>
              <h2>{bucket?.name ?? bucketName}</h2>
              <p>{t('buckets.ownerLabel')} <strong>{bucket?.owner ?? '-'}</strong><span>{t('buckets.access')} <strong>{displayValue(configuration?.access_policy ?? 'Private')}</strong></span></p>
            </div>
          </div>
        </div>
        <div className="bucket-detail-actions">
          <Button variant="outline" type="button" onClick={onBack}>
            <ArrowLeft data-icon="inline-start" aria-hidden="true" />{t('common.buckets')}
          </Button>
        </div>
      </header>

      <section className="panel bucket-settings-panel">
        <nav className="bucket-settings-nav" aria-label={t('buckets.bucketConfiguration')}>
          {sections.map((section) => (
            <button key={section} className={activeSection === section ? 'active' : ''} type="button" onClick={() => setActiveSection(section)}>
              {displayValue(section)}
            </button>
          ))}
        </nav>

        <div className="bucket-settings-content">
          {activeSection === 'Summary' && <div className="bucket-settings-title">
            <div><p className="eyebrow">{t('buckets.bucketConfiguration')}</p>{activeSection !== 'Summary' && <h3>{displayValue(activeSection)}</h3>}</div>
            <span>{t('buckets.createdOn')} {bucket ? formatDateTime(bucket.created_at) : '-'}</span>
          </div>}

          {activeSection === 'Summary' ? <>
          <SettingsSection>
            <div className="bucket-setting-item bucket-access-policy-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><Shield aria-hidden="true" /><span>{t('buckets.accessPolicy')}</span><Badge>{!policyReady ? '—' : configuration?.access_policy === 'Custom' || policyDocument ? t('buckets.customPolicy') : configuration?.access_policy === 'Public' ? t('buckets.public') : configuration?.access_policy === 'Readonly' ? t('buckets.readonly') : t('buckets.private')}</Badge></div><p className="bucket-setting-description">{t('buckets.accessPolicyDescription')}</p></div>
              <Button variant="outline" size="sm" disabled={loading || !configuration} onClick={() => void openAccessPolicyDialog()}><Pencil aria-hidden="true" />{t('buckets.editQuota')}</Button>
            </div>
            <div className="bucket-setting-item bucket-encryption-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>{t('buckets.encryption')}</span><Badge>{configuration?.encryption === 'KMS' ? 'aws:kms' : configuration?.encryption === 'Enabled' ? t('buckets.encryptionAlgorithmAes256') : t('buckets.notConfigured')}</Badge></div><p className="bucket-setting-description">{t('buckets.encryptionDescription')}</p></div>
              <Button variant="outline" size="sm" disabled={loading || !configuration} onClick={() => { setEncryptionDraft(configuration?.encryption ?? 'Disabled'); setKmsKeyDraft(configuration?.kms_key_id ?? ''); setKmsKeysReady(false); setEncryptionDialogOpen(true) }}><Pencil aria-hidden="true" />{t('buckets.editQuota')}</Button>
            </div>
            <div className="bucket-setting-item bucket-versioning-control">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><Archive aria-hidden="true" /><span>{t('buckets.versioning')}</span><Badge>{configuration?.versioning === 'Enabled' ? t('buckets.enabled') : configuration?.versioning === 'Suspended' ? t('buckets.suspended') : t('buckets.disabled')}</Badge></div><p className="bucket-setting-description">{t('buckets.versioningDescription')}</p></div>
              <Switch
                aria-label={t('buckets.bucketVersioning')}
                checked={configuration?.versioning === 'Enabled'}
                onCheckedChange={(enabled) => void updateVersioning(enabled ? 'Enabled' : 'Suspended')}
                disabled={loading || !configuration || configuration.object_locking}
              />
            </div>
            <div className="bucket-setting-item bucket-object-locking-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>{t('buckets.objectLocking')}</span><Badge>{configuration?.object_locking ? t('buckets.enabled') : t('buckets.disabled')}</Badge></div><p className="bucket-setting-description">{t('buckets.objectLockingDescription')}</p></div>
            </div>
          </SettingsSection>
          <SettingsSection>
            <div className="bucket-setting-item bucket-retention-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><KeyRound aria-hidden="true" /><span>{t('buckets.retention')}</span><Badge>{configuration?.retention_enabled ? t('buckets.enabled') : t('buckets.notConfigured')}</Badge></div><p className="bucket-setting-description">{t('buckets.retentionDescription')}</p></div>
              <Button className="bucket-retention-edit" variant="outline" size="sm" onClick={openRetentionDialog} disabled={loading || !configuration?.object_locking}><Pencil aria-hidden="true" />{t('buckets.editQuota')}</Button>
              {configuration?.retention_enabled && <dl className="bucket-retention-details">
                <div><dt>{t('buckets.mode')}</dt><dd>{configuration.retention_mode}</dd></div>
                <div><dt>{t('buckets.retentionValidity')}</dt><dd>{((configuration.retention_duration_seconds ?? 86400) / ((configuration.retention_duration_seconds ?? 86400) % 86400 === 0 ? 86400 : 1)).toLocaleString(getFormatLocale())}</dd></div>
                <div><dt>{t('buckets.retentionValidityUnit')}</dt><dd>{(configuration.retention_duration_seconds ?? 86400) % 86400 === 0 ? t('buckets.validityDay') : t('buckets.s')}</dd></div>
              </dl>}
            </div>
            <div className="bucket-setting-item bucket-quota-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><Gauge aria-hidden="true" /><span>{t('buckets.quota')}</span><Badge>{configuration?.max_bytes || configuration?.max_objects ? t('buckets.enabled') : t('buckets.disabled')}</Badge></div><p className="bucket-setting-description">{t('buckets.quotaDescription')}</p></div>
              {(Boolean(configuration?.max_bytes) || Boolean(configuration?.max_objects)) && <dl className="bucket-quota-details">
                {Boolean(configuration?.max_bytes) && <>
                  <div><dt>{t('buckets.quotaSize')}</dt><dd>{formatQuotaBytes(configuration!.max_bytes!)}</dd></div>
                  <div><dt>{t('buckets.quotaUsage')}</dt><dd>{formatQuotaBytes(usage.bytes)} ({formatQuotaPercent(usage.bytes, configuration!.max_bytes!)})</dd></div>
                </>}
                {Boolean(configuration?.max_objects) && <>
                  <div><dt>{t('buckets.maximumObjects')}</dt><dd>{configuration!.max_objects!.toLocaleString(getFormatLocale())}</dd></div>
                  <div><dt>{t('buckets.objectQuotaUsage')}</dt><dd>{usage.objects.toLocaleString(getFormatLocale())} ({formatQuotaPercent(usage.objects, configuration!.max_objects!)})</dd></div>
                </>}
              </dl>}
              <Button className="bucket-quota-edit" variant="outline" size="sm" onClick={openQuotaDialog} disabled={loading || !configuration}><Pencil aria-hidden="true" />{t('buckets.editQuota')}</Button>

            </div>
            <div className="bucket-setting-item bucket-tags-setting">
              <div className="bucket-setting-copy"><div className="bucket-setting-label"><Tags aria-hidden="true" /><span>{t('buckets.tags')}</span><Badge>{Object.keys(tags).length ? t('buckets.configured') : t('buckets.notConfigured')}</Badge></div><p className="bucket-setting-description">{t('buckets.bucketTagsDescription')}</p></div>
              <Button className="bucket-tags-add-action" variant="outline" size="sm" type="button" onClick={() => setTagDialogOpen(true)} disabled={loading}><Plus aria-hidden="true" />{t('buckets.addTag')}</Button>
              <div className="bucket-tags-list">
                {Object.entries(tags).map(([key, value]) => <Badge className="bucket-tag-chip" key={key}>
                  <span>{key}:{value}</span>
                  <button type="button" aria-label={t('buckets.deleteTagAction', { '0': key })} title={t('buckets.deleteTag')} onClick={() => void (async () => {
                    if (!await confirm({ title: t('common.warning'), message: t('buckets.deleteTagConfirmation', { '0': `${key}:${value}` }), confirmLabel: t('buckets.deleteTag'), danger: true })) return
                    const next = { ...tags }
                    delete next[key]
                    setTags(() => {
                      return next
                    })
                    void persistTags(next)
                  })()} disabled={loading}><X aria-hidden="true" /></button>
                </Badge>)}
                {Object.keys(tags).length === 0 && <span className="bucket-tags-empty">{t('buckets.noTags')}</span>}
              </div>
            </div>
          </SettingsSection>
          </> : activeSection === 'Events' ? <BucketEvents key={bucketName} api={api} bucketName={bucketName} /> : activeSection === 'Lifecycle' ? <LifecycleRulesEditor
            rules={lifecycleRules}
            bucketName={bucketName}
            versioned={configuration?.versioning === 'Enabled' || configuration?.versioning === 'Suspended'}
            onRefresh={refresh}
            loading={loading}
            onSave={saveLifecycle}
          /> : <AnonymousAccess key={bucketName} api={api} bucketName={bucketName} />}
        </div>
        <Dialog open={accessPolicyDialogOpen} onOpenChange={(open) => { if (!loading) setAccessPolicyDialogOpen(open) }}>
          <DialogContent className="bucket-access-policy-dialog" onInteractOutside={(event) => event.preventDefault()}>
            <DialogHeader><DialogTitle>{t('buckets.setAccessPolicy')}</DialogTitle></DialogHeader>
            <form onSubmit={(event) => { event.preventDefault(); void saveAccessPolicyDialog() }}>
              <label htmlFor="bucket-access-policy-draft">{t('buckets.accessPolicy')}</label>
              <OptionSelect id="bucket-access-policy-draft" aria-label={t('buckets.bucketAccessPolicy')} aria-describedby="access-policy-help" value={accessPolicyDraft === 'Readonly' ? '' : accessPolicyDraft} placeholder={accessPolicyDraft === 'Readonly' ? t('buckets.readonly') : undefined} onValueChange={(value) => setAccessPolicyDraft(value as 'Private' | 'Readonly' | 'Public' | 'Custom')} disabled={loading} options={[{ value: 'Private', label: t('buckets.private') }, { value: 'Public', label: t('buckets.public') }, { value: 'Custom', label: t('buckets.customPolicy') }]} />
              <p id="access-policy-help" className="access-policy-help">{accessPolicyDraft === 'Custom' ? t('buckets.customPolicyHelp') : accessPolicyDraft === 'Public' ? t('buckets.publicPolicyHelp') : accessPolicyDraft === 'Readonly' ? t('buckets.readonlyPolicyHelp') : t('buckets.privatePolicyHelp')}</p>
              {accessPolicyDraft === 'Public' && <Alert variant="destructive"><AlertTitle>{t('buckets.public')}</AlertTitle><AlertDescription>{t('buckets.publicPolicyHelp')}</AlertDescription></Alert>}
              {accessPolicyDraft === 'Custom' && <div className="access-policy-json"><label htmlFor="access-policy-document">{t('buckets.bucketPolicy')}</label><Textarea id="access-policy-document" value={policyDraft} onChange={event => setPolicyDraft(event.target.value)} rows={10} spellCheck={false} disabled={loading} /></div>}
              <div className="ui-dialog-footer"><Button size="sm" type="button" variant="outline" disabled={loading} onClick={() => setAccessPolicyDialogOpen(false)}>{t('common.cancel')}</Button><Button size="sm" type="submit" disabled={loading}>{t('buckets.savePolicy')}</Button></div>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog open={encryptionDialogOpen} onOpenChange={(open) => { if (!loading) setEncryptionDialogOpen(open) }}>
          <DialogContent className="bucket-encryption-dialog" onInteractOutside={(event) => event.preventDefault()}>
            <DialogHeader><DialogTitle>{t('buckets.setEncryption')}</DialogTitle></DialogHeader>
            <form onSubmit={(event) => { event.preventDefault(); void updateEncryption(encryptionDraft) }}>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="bucket-encryption-type">{t('buckets.encryptionType')}</FieldLabel>
                  <OptionSelect id="bucket-encryption-type" aria-describedby="bucket-encryption-description" value={encryptionDraft} onValueChange={value => setEncryptionDraft(value as 'Disabled' | 'Enabled' | 'KMS')} disabled={loading} options={[
                    { value: 'Disabled', label: t('buckets.disabled') },
                    { value: 'Enabled', label: t('buckets.sseS3') },
                    { value: 'KMS', label: 'SSE-KMS' },
                  ]} />
                  <FieldDescription id="bucket-encryption-description">{encryptionDraft === 'KMS' ? t('settings.kmsBucketDescription') : encryptionDraft === 'Enabled' ? t('buckets.sseS3Description') : t('buckets.disabledEncryptionDescription')}</FieldDescription>
                </Field>
                {encryptionDraft === 'KMS' && <Field>
                  <FieldLabel htmlFor="bucket-encryption-key">{t('buckets.kmsKeyId')}</FieldLabel>
                  <OptionSelect id="bucket-encryption-key" value={kmsKeyDraft} onValueChange={setKmsKeyDraft} disabled={loading || kmsKeysLoading || !kmsKeysReady || kmsKeys.length === 0} placeholder={t('buckets.selectKmsKey')} options={[
                    ...kmsKeys.map(key => ({ value: key.id, label: key.name || key.description || key.id })),
                    ...(kmsKeyDraft && !kmsKeys.some(key => key.id === kmsKeyDraft) ? [{ value: kmsKeyDraft, label: kmsKeyDraft, disabled: true }] : []),
                  ]} />
                  {!kmsKeysLoading && (kmsKeysFailed || (kmsKeysReady && kmsKeys.length === 0)) && <Alert variant="destructive">
                    <AlertTitle>{t('buckets.kmsKeyListUnavailable')}</AlertTitle>
                    <AlertDescription className="gap-3">
                      <p>{t('buckets.kmsKeyListRetry')}</p>
                      <Button type="button" variant="outline" className="w-full" disabled={loading} onClick={() => setKmsKeysRefresh(value => value + 1)}>{t('settings.kmsRefresh')}</Button>
                    </AlertDescription>
                  </Alert>}
                </Field>}
                {encryptionDraft === 'Disabled' && <Alert variant="destructive">
                  <AlertTitle>{t('buckets.disabled')}</AlertTitle>
                  <AlertDescription>{t('buckets.disabledEncryptionDescription')}</AlertDescription>
                </Alert>}
              </FieldGroup>
              <div className="ui-dialog-footer"><Button size="sm" type="button" variant="outline" disabled={loading} onClick={() => setEncryptionDialogOpen(false)}>{t('common.cancel')}</Button><Button size="sm" type="submit" disabled={loading || (encryptionDraft === 'KMS' && (kmsKeysLoading || !kmsKeysReady || !kmsKeys.some(key => key.id === kmsKeyDraft)))}>{t('buckets.saveEncryption')}</Button></div>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog open={retentionDialogOpen} onOpenChange={(open) => { if (!loading) setRetentionDialogOpen(open) }}>
          <DialogContent className="bucket-retention-dialog" onInteractOutside={(event) => event.preventDefault()}>
            <DialogHeader><DialogTitle>{t('buckets.setRetention')}</DialogTitle></DialogHeader>
            <form onSubmit={(event) => { event.preventDefault(); void saveRetention() }}>
              <fieldset disabled={loading} className="bucket-retention-form">
                  <span>{t('buckets.mode')}</span>
                  <RadioGroup className="bucket-create-options retention-mode-options" aria-label={t('buckets.retentionMode')} value={retentionDraft.mode} onValueChange={(mode) => setRetentionDraft(current => ({ ...current, mode: mode as 'GOVERNANCE' | 'COMPLIANCE' }))}>
                    {(['COMPLIANCE', 'GOVERNANCE'] as const).map(mode => <label key={mode}><RadioGroupItem value={mode} /><span>{mode}<small>{mode === 'COMPLIANCE' ? t('buckets.complianceModeHelp') : t('buckets.governanceModeHelp')}</small></span></label>)}
                  </RadioGroup>
                  <span>{t('buckets.retentionValidityUnit')}</span>
                  <RadioGroup className="bucket-create-options" aria-label={t('buckets.retentionValidityUnit')} value={retentionDraft.unit} onValueChange={(unit) => setRetentionDraft(current => ({ ...current, unit }))}>
                    <label><RadioGroupItem value="day" />{t('buckets.validityDay')}</label><label><RadioGroupItem value="year" />{t('buckets.validityYear')}</label>
                    {retentionDraft.unit === 'second' && <label><RadioGroupItem value="second" />{t('buckets.s')}</label>}
                  </RadioGroup>
                  <label htmlFor="retention-period">{t('buckets.retentionValidity')}</label>
                  <Input id="retention-period" type="number" min="1" step="1" required value={retentionDraft.period} onChange={(event) => setRetentionDraft(current => ({ ...current, period: event.target.value }))} />

              </fieldset>
              <div className="ui-dialog-footer"><Button size="sm" type="button" variant="outline" disabled={loading} onClick={() => setRetentionDialogOpen(false)}>{t('common.cancel')}</Button><Button size="sm" type="submit" disabled={loading}>{t('buckets.save')}</Button></div>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog open={quotaDialogOpen} onOpenChange={(open) => { if (!loading) setQuotaDialogOpen(open) }}>
          <DialogContent className="bucket-quota-dialog" onInteractOutside={(event) => event.preventDefault()}>
            <DialogHeader><DialogTitle>{t('buckets.setBucketQuota')}</DialogTitle></DialogHeader>
            <form onSubmit={(event) => { event.preventDefault(); void saveQuota() }}>
              <label className="bucket-quota-toggle" htmlFor="bucket-quota-enabled">
                <span>{t('buckets.bucketQuota')}</span>
                <Switch id="bucket-quota-enabled" checked={quotaEnabled} onCheckedChange={setQuotaEnabled} disabled={loading} />
              </label>
              {quotaEnabled && <div className="bucket-quota-fields">
                <label htmlFor="bucket-quota-size">{t('buckets.quotaSize')}</label>
                <div className="bucket-quota-size">
                  <Input id="bucket-quota-size" type="number" min="0" step="any" value={quotaBytes} onChange={(event) => setQuotaBytes(event.target.value)} disabled={!quotaEnabled || loading} placeholder={t('buckets.unlimited')} />
                  <OptionSelect aria-label={t('buckets.quotaUnit')} value={String(quotaUnit)} onValueChange={(value) => setQuotaUnit(Number(value))} disabled={!quotaEnabled || loading} options={['B', 'MiB', 'GiB', 'TiB', 'PiB'].map((label, index) => ({ label, value: String(index === 0 ? 1 : 1024 ** (index + 1)) }))} />
                </div>
                <label htmlFor="bucket-quota-objects">{t('buckets.maximumObjects')}</label>
                <Input id="bucket-quota-objects" type="number" min="1" step="1" value={quotaObjects} onChange={(event) => setQuotaObjects(event.target.value)} disabled={!quotaEnabled || loading} placeholder={t('buckets.unlimited')} />
              </div>}
              <div className="ui-dialog-footer">
                <Button size="sm" type="button" variant="outline" onClick={() => setQuotaDialogOpen(false)} disabled={loading}>{t('common.cancel')}</Button>
                <Button size="sm" type="submit" disabled={loading}>{t('buckets.save')}</Button>
              </div>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog open={tagDialogOpen} onOpenChange={setTagDialogOpen}>
          <DialogContent>
            <DialogHeader><DialogTitle>{t('buckets.setTag')}</DialogTitle></DialogHeader>
            <div className="bucket-tag-dialog-fields">
              <label>{t('buckets.tagKey')}<input autoFocus placeholder={t('buckets.tagKeyPlaceholder')} value={tagKey} onChange={(event) => setTagKey(event.target.value)} /></label>
              <label>{t('buckets.tagValue')}<input placeholder={t('buckets.tagValuePlaceholder')} value={tagValue} onChange={(event) => setTagValue(event.target.value)} /></label>
            </div>
            <div className="ui-dialog-footer"><button type="button" className="secondary-button" onClick={() => setTagDialogOpen(false)}>{t('common.cancel')}</button><button type="button" className="primary-button" onClick={addTag} disabled={!tagKey.trim()}>{t('buckets.addTag')}</button></div>
          </DialogContent>
        </Dialog>
      </section>
    </section>
  )
}

function SettingsSection({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="bucket-settings-section" style={title ? undefined : { paddingTop: 0 }}>
      {title && <h3>{title}</h3>}
      <div className="bucket-settings-section-grid">{children}</div>
    </section>
  )
}

function formatQuotaPercent(used: number, limit: number) {
  return (used / limit).toLocaleString(getFormatLocale(), { style: 'percent', minimumFractionDigits: 1, maximumFractionDigits: 1 })
}

function formatQuotaBytes(bytes: number) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']
  const index = bytes > 0 ? Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1) : 0
  return `${(bytes / 1024 ** index).toLocaleString(getFormatLocale(), { minimumFractionDigits: index > 0 ? 1 : 0, maximumFractionDigits: 1 })} ${units[index]}`
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index += 1
  }
  return `${value.toFixed(1)} ${units[index]}`
}

function parseTags(value?: string): Record<string, string> {
  if (!value) return {}
  try {
    const parsed: unknown = JSON.parse(value)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    return Object.fromEntries(Object.entries(parsed).filter(([, item]) => typeof item === 'string'))
  } catch {
    return {}
  }
}
