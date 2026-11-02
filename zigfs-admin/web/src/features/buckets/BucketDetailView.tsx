import { t, getFormatLocale, displayValue } from '@/locales'
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import {
  ArrowLeft,
  Activity,
  Archive,
  ChartPie,
  CircleX,
  FolderOpen,
  Gauge,
  KeyRound,
  LockKeyhole,
  Pencil,
  Plus,
  RefreshCw,
  Shield,
  Tags,
  Trash2,
  X,
  type LucideIcon,
} from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import type { AuditEvent, Bucket, BucketConfiguration } from '../../types/api'
import { BucketPolicyEditor } from './BucketPolicyEditor'
import { Button } from '../../components/ui/Button'
import { Badge } from '../../components/ui/Badge'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { LifecycleRulesEditor } from './LifecycleRulesEditor'
import { parseLifecycleConfiguration, serializeLifecycleConfiguration, type LifecycleRule } from './lifecycle'

interface BucketDetailViewProps {
  api: ApiClient
  bucketName: string
  onBack: () => void
  onOpenObjects: () => void
  onDeleted: () => void
}

interface BucketUsage {
  bytes: number
  objects: number
}

const sections = ['Summary', 'Events', 'Replication', 'Lifecycle', 'Access', 'Anonymous']

export function BucketDetailView({ api, bucketName, onBack, onOpenObjects, onDeleted }: BucketDetailViewProps) {
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [bucket, setBucket] = useState<Bucket | null>(null)
  const [configuration, setConfiguration] = useState<BucketConfiguration | null>(null)
  const [activeSection, setActiveSection] = useState<'Summary' | 'Events' | 'Lifecycle' | 'Access' | 'Anonymous'>('Summary')
  const [lifecycleRules, setLifecycleRules] = useState<LifecycleRule[]>([])
  const [tags, setTags] = useState<Record<string, string>>({})
  const [tagKey, setTagKey] = useState('')
  const [tagValue, setTagValue] = useState('')
  const [tagDialogOpen, setTagDialogOpen] = useState(false)
  const [quotaBytes, setQuotaBytes] = useState('')
  const [quotaObjects, setQuotaObjects] = useState('')
  const [usage, setUsage] = useState<BucketUsage>({ bytes: 0, objects: 0 })
  const [bucketContentKnown, setBucketContentKnown] = useState(false)
  const [bucketHasContent, setBucketHasContent] = useState(false)
  const [loading, setLoading] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    if (!bucketName) return
    const stopLoading = startLoading(t('buckets.loadingBucketConfiguration'))
    try {
      setLoading(true)
      setBucketContentKnown(false)
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

      let continuationToken = ''
      let bytes = bucketUsage.bytes
      let objects = bucketUsage.objects
      let hasContent = false
      do {
        const page = await api.listObjects(bucketName, '', continuationToken, '', 1000, '/')
        hasContent = hasContent || page.items.length > 0 || (page.common_prefixes?.length ?? 0) > 0 || (page.directories?.length ?? 0) > 0
        const nextToken = page.is_truncated ? (page.continuation_token ?? '') : ''
        if (!nextToken || nextToken === continuationToken) break
        continuationToken = nextToken
      } while (continuationToken)
      setUsage({ bytes, objects })
      if (!hasContent) hasContent = (await api.listObjectVersions(bucketName)).length > 0
      setBucketHasContent(hasContent)
      setBucketContentKnown(true)
    } catch (reason) {
      setBucketContentKnown(false)
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }, [api, bucketName, startLoading])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function remove() {
    if (!bucketContentKnown) return
    if (bucketHasContent) {
      await confirm({
        title: t('buckets.deleteBucket'),
        message: t('buckets.bucketValueMustBeEmptyBeforeDeletionDeleteIts', { '0': bucketName }),
        cancelLabel: t('buckets.gotIt'),
        danger: true,
        hideConfirm: true,
      })
      return
    }
    if (!await confirm({
      title: t('buckets.deleteBucket'),
      message: t('buckets.deleteBucketValueThisCannotBeUndone', { '0': bucketName }),
      confirmLabel: t('buckets.delete'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('buckets.deletingBucket'))
    try {
      setDeleting(true)
      await api.deleteBucket(bucketName)
      showToast(t('buckets.deletedBucketValue', { '0': bucketName }))
      onDeleted()
    } catch (reason) {
      if (reason instanceof ApiError && reason.body.code === 'BucketNotEmpty') {
        stopLoading()
        await confirm({
          title: t('buckets.unableToDeleteBucket'),
          message: t('buckets.bucketValueMustBeEmptyBeforeDeletionDeleteIts', { '0': bucketName }),
          cancelLabel: t('buckets.gotIt'),
          hideConfirm: true,
        })
      } else {
        notifyError((reason as Error).message)
      }
    } finally {
      setDeleting(false)
      stopLoading()
    }
  }

  async function updateVersioning(versioning: 'Enabled' | 'Suspended') {
    const stopLoading = startLoading(t('buckets.updatingVersioning'))
    try {
      setLoading(true)
      setConfiguration(await api.updateBucketConfiguration(bucketName, { versioning }))
      setBucket((current) => current ? { ...current, versioning } : current)
      showToast(t('buckets.versioningUpdatedToValue', { '0': versioning }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function updateAccessPolicy(access_policy: 'Private' | 'Readonly' | 'Public') {
    const stopLoading = startLoading(t('buckets.updatingAccessPolicy'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, { access_policy })
      setConfiguration(updated)
      showToast(t('buckets.accessPolicyUpdatedToValue', { '0': access_policy }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function updateEncryption(encryption: 'Disabled' | 'Enabled') {
    const stopLoading = startLoading(t('buckets.updatingEncryption'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, { encryption })
      setConfiguration(updated)
      showToast(t('buckets.encryptionUpdatedToValue', { '0': encryption }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function enableObjectLocking() {
    if (!configuration || configuration.object_locking) return
    if (configuration.versioning !== 'Enabled') {
      notifyError(t('buckets.enableVersioningBeforeEnablingObjectLocking'))
      return
    }
    if (!await confirm({
      title: t('buckets.enableObjectLocking'),
      message: t('buckets.objectLockingCannotBeDisabledOnceEnabledRetentionAnd'),
      confirmLabel: t('buckets.enable'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('buckets.enablingObjectLocking'))
    try {
      setLoading(true)
      const updated = await api.updateBucketConfiguration(bucketName, { object_locking: true })
      setConfiguration(updated)
      showToast(t('buckets.objectLockingEnabled'))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
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
    const maxBytes = parseLimit(quotaBytes, t('buckets.byteQuota'))
    const maxObjects = parseLimit(quotaObjects, t('buckets.objectCountQuota'))
    if (maxBytes === undefined || maxObjects === undefined) return
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
    if (!configuration) return
    const currentEnabled = configuration.retention_enabled
    const currentDuration = configuration.retention_duration_seconds ?? 86400
    const currentMode = configuration.retention_mode ?? 'GOVERNANCE'
    const enabled = patch.enabled ?? currentEnabled
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
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />{t('buckets.backToBuckets')}</button>
          <div className="bucket-identity">
            <span className="bucket-identity-icon" aria-hidden="true"><Archive /></span>
            <div>
              <h2>{bucket?.name ?? bucketName}</h2>
              <p>{t('buckets.ownerLabel')} <strong>{bucket?.owner ?? '-'}</strong><span>{t('buckets.access')} <strong>{displayValue(configuration?.access_policy ?? 'Private')}</strong></span></p>
            </div>
          </div>
        </div>
        <div className="bucket-detail-actions">
          <button className="icon-button bucket-objects-button" type="button" title={t('buckets.browseBucketObjects')} aria-label={t('buckets.browseBucketObjects')} onClick={onOpenObjects} disabled={!bucket}>
            <FolderOpen aria-hidden="true" />
          </button>
          <button className="danger-button" type="button" onClick={() => void remove()} disabled={deleting || !bucket || !bucketContentKnown}>
            <Trash2 className="button-icon" aria-hidden="true" />{t('buckets.deleteBucket')}</button>
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={loading} aria-busy={loading}>
            <RefreshCw className={`button-icon${loading ? ' spinning' : ''}`} aria-hidden="true" />{t('buckets.refresh')}</button>
        </div>
      </header>

      <section className="panel bucket-settings-panel">
        <nav className="bucket-settings-nav" aria-label={t('buckets.bucketConfiguration')}>
          {sections.map((section) => {
            const available = section === 'Summary' || section === 'Events' || section === 'Lifecycle' || section === 'Access' || section === 'Anonymous'
            return <button key={section} className={activeSection === section ? 'active' : ''} type="button" disabled={!available} title={available ? undefined : t('buckets.availableInAFutureRelease')} onClick={() => available && setActiveSection(section as 'Summary' | 'Events' | 'Lifecycle' | 'Access' | 'Anonymous')}>
              {displayValue(section)}
            </button>
          })}
        </nav>

        <div className="bucket-settings-content">
          <div className="bucket-settings-title">
            <div><p className="eyebrow">{t('buckets.bucketConfiguration')}</p><h3>{displayValue(activeSection)}</h3></div>
            <span>{t('buckets.createdOn')} {bucket ? new Date(bucket.created_at).toLocaleString(getFormatLocale()) : '-'}</span>
          </div>

          {activeSection === 'Summary' ? <>
          <div className="bucket-summary-grid">
            <div className="bucket-setting-item bucket-access-policy-setting">
              <div className="bucket-setting-label"><Shield aria-hidden="true" /><span>{t('buckets.accessPolicy')}</span></div>
              <select
                aria-label={t('buckets.bucketAccessPolicy')}
                value={configuration?.access_policy ?? 'Private'}
                onChange={(event) => void updateAccessPolicy(event.target.value as 'Private' | 'Readonly' | 'Public')}
                disabled={loading || !configuration}
              >
                <option value="Private">{t('buckets.private')}</option>
                <option value="Readonly">{t('buckets.readonly')}</option>
                <option value="Public">{t('buckets.public')}</option>
              </select>
              <small>{t('buckets.controlsAnonymousReadAndListPermissions')}</small>
            </div>
            <div className="bucket-setting-item bucket-encryption-setting">
              <div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>{t('buckets.encryption')}</span></div>
              <select aria-label={t('buckets.bucketEncryption')} value={configuration?.encryption ?? 'Disabled'} onChange={(event) => void updateEncryption(event.target.value as 'Disabled' | 'Enabled')} disabled={loading || !configuration}>
                <option value="Disabled">{t('buckets.disabled')}</option>
                <option value="Enabled">{t('buckets.enabled')}</option>
              </select>
              <small>{t('buckets.newObjectsUseServerSideAes256GcmEncryption')}</small>
            </div>
            <div className="bucket-usage">
              <ChartPie aria-hidden="true" />
              <div><span>{t('buckets.reportedUsage')}</span><strong>{formatBytes(usage.bytes)}</strong><small>{usage.objects.toLocaleString(getFormatLocale())} {t('buckets.objects')}</small></div>
            </div>
            <SettingItem
              icon={CircleX}
              label={t('buckets.replication')}
              value={configuration?.replication_status === 'UNAVAILABLE' ? t('common.unavailable') : t('common.disabled')}
              status="unavailable"
              editable={false}
              description={t('buckets.unavailableInThisDeploymentASecondStorageSiteIs')}
            />
            <div className="bucket-setting-item bucket-object-locking-setting">
              <div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>{t('buckets.objectLocking')}</span></div>
              <div className="bucket-setting-value">
                <strong className={configuration?.object_locking ? 'enabled' : 'disabled'}>{configuration?.object_locking ? t('buckets.enabled') : t('buckets.disabled')}</strong>
                {!configuration?.object_locking && <button className="bucket-setting-edit" type="button" aria-label={t('buckets.enableObjectLocking')} title={t('buckets.enableObjectLocking')} onClick={() => void enableObjectLocking()} disabled={loading || !configuration}><Pencil aria-hidden="true" /></button>}
              </div>
              <small>{configuration?.object_locking ? t('buckets.cannotBeDisabledOnceEnabledNewObjectsFollowRetention') : t('buckets.versioningMustBeEnabledFirst')}</small>
            </div>
            <div className="bucket-setting-item bucket-tags-setting">
              <div className="bucket-setting-label bucket-tags-heading"><span><Tags aria-hidden="true" /><span>{t('buckets.tags')}</span></span><button className="secondary-button bucket-tag-add" type="button" onClick={() => setTagDialogOpen(true)} disabled={loading} title={t('buckets.addTag')} aria-label={t('buckets.addTag')}><Plus className="button-icon" aria-hidden="true" /></button></div>
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
                {Object.keys(tags).length === 0 && <small>{t('buckets.notConfigured')}</small>}
              </div>
            </div>
          </div>

          <SettingsSection title={t('buckets.versioning')}>
            <div className="bucket-setting-item bucket-versioning-control">
              <div className="bucket-setting-label"><Archive aria-hidden="true" /><span>{t('buckets.versioning')}</span></div>
              <div className="segmented-control" aria-label={t('buckets.bucketVersioning')}>
                <button type="button" className={configuration?.versioning === 'Enabled' ? 'active' : ''} onClick={() => void updateVersioning('Enabled')} disabled={loading}>{t('buckets.enabled')}</button>
                <button type="button" className={configuration?.versioning === 'Suspended' ? 'active' : ''} onClick={() => void updateVersioning('Suspended')} disabled={loading || configuration?.versioning === 'Unversioned'}>{t('buckets.suspended')}</button>
              </div>
              <small>{configuration?.versioning === 'Unversioned' ? t('buckets.newWritesReceiveVersionIdsWhenEnabled') : t('buckets.versionHistoryIsPersistedByZigfs')}</small>
            </div>
            <div className="bucket-setting-item bucket-quota-setting">
              <div className="bucket-setting-label"><Gauge aria-hidden="true" /><span>{t('buckets.quota')}</span></div>
              <div className="bucket-quota-summary">
                <strong>{configuration?.max_bytes == null ? t('buckets.unlimited') : formatBytes(configuration.max_bytes)}</strong>
                <span>/</span>
                <strong>{configuration?.max_objects == null ? t('buckets.unlimited') : t('buckets.valueObjects', { '0': configuration.max_objects.toLocaleString(getFormatLocale()) })}</strong>
              </div>
              <div className="bucket-quota-editor">
                <input aria-label={t('buckets.maximumBytes')} type="number" min="1" step="1" placeholder={t('buckets.byteLimit')} value={quotaBytes} onChange={(event) => setQuotaBytes(event.target.value)} disabled={loading || !configuration} />
                <input aria-label={t('buckets.maximumObjects')} type="number" min="1" step="1" placeholder={t('buckets.objectCountLimit')} value={quotaObjects} onChange={(event) => setQuotaObjects(event.target.value)} disabled={loading || !configuration} />
                <button className="secondary-button" type="button" onClick={() => void saveQuota()} disabled={loading || !configuration}>{t('buckets.save')}</button>
              </div>
              <small>{t('buckets.leaveBlankForUnlimitedCurrentUsage')} {formatBytes(usage.bytes)} / {usage.objects.toLocaleString(getFormatLocale())} {t('buckets.objects')}</small>
            </div>
          </SettingsSection>

          <SettingsSection title={t('buckets.retention')}>
            <div className="bucket-setting-item bucket-retention-setting">
              <div className="bucket-setting-label"><KeyRound aria-hidden="true" /><span>{t('buckets.retention')}</span></div>
              <label className="bucket-inline-toggle">
                <input
                  type="checkbox"
                  aria-label={t('buckets.enableRetention')}
                  checked={configuration?.retention_enabled ?? false}
                  onChange={(event) => void updateRetention({ enabled: event.target.checked })}
                  disabled={loading || !configuration}
                />
                <span>{t('buckets.enabled')}</span>
              </label>
              <div className="bucket-retention-controls">
                <label>
                  <span>{t('buckets.duration')}</span>
                  <input
                    type="number"
                    min={1}
                    aria-label={t('buckets.retentionDurationSeconds')}
                    value={configuration?.retention_duration_seconds ?? 86400}
                    onChange={(event) => {
                      const value = Number(event.target.value)
                      if (Number.isSafeInteger(value) && value > 0) void updateRetention({ duration: value })
                    }}
                    disabled={loading || !configuration}
                  />
                  <span>{t('buckets.s')}</span>
                </label>
                <label>
                  <span>{t('buckets.mode')}</span>
                  <select
                    aria-label={t('buckets.retentionMode')}
                    value={configuration?.retention_mode ?? 'GOVERNANCE'}
                    onChange={(event) => void updateRetention({ mode: event.target.value as 'GOVERNANCE' | 'COMPLIANCE' })}
                    disabled={loading || !configuration}
                  >
                    <option value="GOVERNANCE">GOVERNANCE</option>
                    <option value="COMPLIANCE">COMPLIANCE</option>
                  </select>
                </label>
              </div>
              <small>{configuration?.retention_enabled ? t('buckets.newObjectsInheritTheDefaultRetentionPeriod') : t('buckets.newObjectsInheritRetentionWhenEnabled')}</small>
            </div>
          </SettingsSection>
          </> : activeSection === 'Events' ? <EventsOverview api={api} bucket={bucket} configuration={configuration} /> : activeSection === 'Lifecycle' ? <LifecycleRulesEditor
            rules={lifecycleRules}
            configured={Boolean(configuration?.lifecycle_configuration)}
            loading={loading}
            onSave={saveLifecycle}
          /> : activeSection === 'Access' ? <><BucketPolicyEditor api={api} bucketName={bucketName} /><AccessOverview api={api} bucketName={bucketName} bucket={bucket} configuration={configuration} loading={loading} onPolicyChange={updateAccessPolicy} /></> : <AnonymousOverview configuration={configuration} />}
        </div>
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

function SettingsSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="bucket-settings-section">
      <h3>{title}</h3>
      <div className="bucket-settings-section-grid">{children}</div>
    </section>
  )
}

function AccessOverview({ api, bucketName, bucket, configuration, loading, onPolicyChange }: {
  api: ApiClient
  bucketName: string
  bucket: Bucket | null
  configuration: BucketConfiguration | null
  loading: boolean
  onPolicyChange: (policy: 'Private' | 'Readonly' | 'Public') => void
}) {
  const policy = configuration?.access_policy ?? 'Private'
  const anonymousRead = policy === 'Readonly' || policy === 'Public'
  const anonymousList = policy === 'Public'
  const blockPublic = configuration?.block_public_access ?? true
  return (
    <div className="bucket-access-overview">
      <div className="bucket-access-hero">
        <Shield aria-hidden="true" />
        <div><h4>{t('buckets.bucketAccess')}</h4><p>{t('buckets.accessIsControlledByConfigurationPersistedInZigfs')}</p></div>
      </div>
      <dl className="bucket-access-list">
        <div><dt>{t('buckets.owner')}</dt><dd>{bucket?.owner ?? '-'}</dd></div>
        <div><dt>{t('buckets.accessPolicy')}</dt><dd><select aria-label={t('buckets.accessPagePolicy')} value={policy} onChange={(event) => onPolicyChange(event.target.value as 'Private' | 'Readonly' | 'Public')} disabled={loading || !configuration}><option value="Private">{t('buckets.private')}</option><option value="Readonly">{t('buckets.readonly')}</option><option value="Public">{t('buckets.public')}</option></select></dd></div>
        <div><dt>{t('buckets.anonymousObjectRead')}</dt><dd className={anonymousRead ? 'allowed' : 'denied'}>{anonymousRead ? t('buckets.allowed') : t('buckets.denied')}</dd></div>
        <div><dt>{t('buckets.anonymousBucketListing')}</dt><dd className={anonymousList ? 'allowed' : 'denied'}>{anonymousList ? t('buckets.allowed') : t('buckets.denied')}</dd></div>
        <div><dt>{t('buckets.anonymousWriteDelete')}</dt><dd className="denied">{t('buckets.denied')}</dd></div>
        <div><dt>{t('buckets.blockPublicAccess')}</dt><dd><Button size="sm" variant="outline" disabled={loading || !configuration} onClick={() => void api.updateBucketConfiguration(bucketName, { block_public_access: !blockPublic }).then(() => window.location.reload())}>{blockPublic ? t('buckets.blocked') : t('buckets.allowed')}</Button></dd></div>
        <div><dt>{t('buckets.objectOwnership')}</dt><dd>{t('buckets.bucketOwnerEnforced')}</dd></div>
      </dl>
      <p className="bucket-access-note">{t('buckets.theseAreLegacyAccessPolicyDefaultsRequestsAlsoEvaluate')}</p>
    </div>
  )
}

function AnonymousOverview({ configuration }: { configuration: BucketConfiguration | null }) {
  const policy = configuration?.access_policy ?? 'Private'
  const readObject = policy === 'Readonly' || policy === 'Public'
  const listBucket = policy === 'Public'
  const permissions = [
    ['GetObject / HeadObject', readObject],
    ['ListBucket', listBucket],
    ['GetObjectVersion', readObject],
    ['PutObject / CopyObject', false],
    ['DeleteObject / DeleteBucket', false],
  ] as const
  return (
    <div className="bucket-anonymous-overview">
      <div className="bucket-access-hero">
        <Shield aria-hidden="true" />
        <div><h4>{t('buckets.anonymousAccess')}</h4><p>{t('buckets.anonymousRequestsHaveNoAccessKeyLegacyAccessPolicy')}</p></div>
      </div>
      <div className="bucket-anonymous-policy"><span>{t('buckets.currentPolicy')}</span><strong>{policy}</strong></div>
      <div className="bucket-anonymous-list">
        {permissions.map(([action, allowed]) => <div key={action}><span>{action}</span><b className={allowed ? 'allowed' : 'denied'}>{allowed ? t('buckets.allowed') : t('buckets.denied')}</b></div>)}
      </div>
      <p className="bucket-access-note">{t('buckets.changeAnonymousPermissionsUnderAccessOrSummaryAccessPolicy')}</p>
    </div>
  )
}

function EventsOverview({ api, bucket, configuration }: { api: ApiClient; bucket: Bucket | null; configuration: BucketConfiguration | null }) {
  const showToast = useToast()
  const [events, setEvents] = useState<AuditEvent[]>([])
  const [nextCursor, setNextCursor] = useState('')
  const [loading, setLoading] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [action, setAction] = useState('')
  const [outcome, setOutcome] = useState('')
  const toUnix = (value: string) => value ? String(Math.floor(new Date(value).getTime() / 1000)) : ''
  const loadEvents = useCallback(async (cursor = '', append = false) => {
    if (!bucket) return
    setLoading(true)
    try {
      const page = await api.listBucketEvents(bucket.name, cursor, 50, toUnix(from), toUnix(to), action, outcome)
      setEvents((current) => append ? [...current, ...page.items] : page.items)
      setNextCursor(page.next_cursor ?? '')
      setLoaded(true)
    } catch (reason) {
      showToast(reason instanceof Error ? reason.message : t('buckets.failedToLoadAuditEvents'), 'error')
    } finally {
      setLoading(false)
    }
  }, [action, api, bucket, from, outcome, showToast, to])
  useEffect(() => { void loadEvents() }, [loadEvents])
  const configurationEvents = [
    [t('common.bucketLoaded'), bucket ? t('buckets.ownerValue', { '0': bucket.owner }) : t('buckets.loading')],
    [t('common.accessPolicy'), configuration?.access_policy ?? t('buckets.unknown')],
    [t('common.encryption'), configuration?.encryption ?? t('buckets.unknown')],
    [t('common.retention'), configuration?.retention_enabled ? t('buckets.valuesValue', { '0': configuration.retention_duration_seconds ?? 0, '1': configuration.retention_mode ?? 'GOVERNANCE' }) : t('buckets.disabled')],
    [t('common.objectLocking'), configuration?.object_locking ? t('buckets.enabled') : t('buckets.disabled')],
    [t('common.replication'), configuration?.replication_status ?? t('buckets.unknown')],
  ] as const
  return (
    <div className="bucket-events-overview">
      <div className="bucket-access-hero">
        <Activity aria-hidden="true" />
        <div><h4>{t('buckets.configurationEvents')}</h4><p>{t('buckets.configurationComesFromZigfsPersistedAuditEventsSupportTime')}</p></div>
      </div>
      <div className="bucket-events-list">
        {configurationEvents.map(([event, value]) => <div key={event}><span>{event}</span><b>{value}</b></div>)}
      </div>
      <h4>{t('buckets.auditTimeline')}</h4>
      <div className="bucket-events-filters">
        <label>{t('buckets.from')} <input type="datetime-local" value={from} onChange={(event) => setFrom(event.target.value)} /></label>
        <label>{t('buckets.to')} <input type="datetime-local" value={to} onChange={(event) => setTo(event.target.value)} /></label>
        <label>{t('buckets.action')} <input value={action} placeholder="update_retention" onChange={(event) => setAction(event.target.value)} /></label>
        <label>{t('buckets.outcome')} <input value={outcome} placeholder="updated" onChange={(event) => setOutcome(event.target.value)} /></label>
        <button type="button" className="secondary-button" onClick={() => void loadEvents()} disabled={loading}>{t('buckets.apply')}</button>
      </div>
      <div className="bucket-events-list">
        {events.map((event) => <div key={`${event.request_id}-${event.timestamp_unix_seconds}`}><span>{new Date(event.timestamp_unix_seconds * 1000).toLocaleString(getFormatLocale())}</span><b>{event.action} · {event.outcome}</b></div>)}
      </div>
      {loaded && events.length === 0 && <p className="bucket-access-note">{t('buckets.noAuditEventsMatchTheCurrentFilters')}</p>}
      <div className="bucket-events-actions">
        <button type="button" className="secondary-button" onClick={() => void loadEvents()} disabled={loading}>{loading ? t('buckets.loadingProgress') : t('buckets.refreshEvents')}</button>
        {nextCursor && <button type="button" className="secondary-button" onClick={() => void loadEvents(nextCursor, true)} disabled={loading}>{t('buckets.loadMore')}</button>}
      </div>
      <p className="bucket-access-note">{t('buckets.theConfigurationSnapshotIsSeparateFromTheAuditTimeline')}</p>
    </div>
  )
}

function SettingItem({ icon: Icon, label, value, status = 'unavailable', editable = true, description = t('buckets.configurationIsNotAvailableInThisVersion') }: {
  icon: LucideIcon
  label: string
  value: string
  status?: 'enabled' | 'disabled' | 'unavailable'
  editable?: boolean
  description?: string
}) {
  return (
    <div className="bucket-setting-item">
      <div className="bucket-setting-label"><Icon aria-hidden="true" /><span>{label}</span></div>
      <div className="bucket-setting-value">
        <strong className={status}>{value}</strong>
        {editable && <button className="bucket-setting-edit" type="button" aria-label={t('buckets.editValue', { '0': label })} title={t('buckets.availableInAFutureRelease')} disabled><Pencil aria-hidden="true" /></button>}
      </div>
      <small>{description}</small>
    </div>
  )
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
