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
  type LucideIcon,
} from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useToast } from '../../components/ToastProvider'
import type { AuditEvent, Bucket, BucketConfiguration } from '../../types/api'
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
  const [quotaBytes, setQuotaBytes] = useState('')
  const [quotaObjects, setQuotaObjects] = useState('')
  const [usage, setUsage] = useState<BucketUsage>({ bytes: 0, objects: 0 })
  const [bucketContentKnown, setBucketContentKnown] = useState(false)
  const [bucketHasContent, setBucketHasContent] = useState(false)
  const [loading, setLoading] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (error) showToast(error)
  }, [error, showToast])

  const refresh = useCallback(async () => {
    if (!bucketName) return
    const stopLoading = startLoading('正在加载 Bucket 配置...')
    try {
      setLoading(true)
      setBucketContentKnown(false)
      setError('')
      const [buckets, bucketConfiguration, bucketUsage] = await Promise.all([
        api.listBuckets(),
        api.getBucketConfiguration(bucketName),
        api.getBucketUsage(bucketName),
      ])
      const current = buckets.find((item) => item.name === bucketName)
      if (!current) throw new Error(`Bucket “${bucketName}” 不存在`)
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
      setError((reason as Error).message)
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
        title: '删除 Bucket',
        message: `Bucket “${bucketName}”必须为空才能删除。请先删除其中的所有对象和目录，Bucket 内的数据不会被自动删除。`,
        cancelLabel: '知道了',
        danger: true,
        hideConfirm: true,
      })
      return
    }
    if (!await confirm({
      title: '删除 Bucket',
      message: `删除 Bucket “${bucketName}”？此操作不可撤销。`,
      confirmLabel: '删除',
      danger: true,
    })) return
    const stopLoading = startLoading('正在删除 Bucket...')
    try {
      setDeleting(true)
      setError('')
      await api.deleteBucket(bucketName)
      showToast(`已删除 Bucket ${bucketName}`)
      onDeleted()
    } catch (reason) {
      if (reason instanceof ApiError && reason.body.code === 'BucketNotEmpty') {
        stopLoading()
        await confirm({
          title: '无法删除 Bucket',
          message: `Bucket “${bucketName}”必须为空才能删除。请先删除其中的所有对象和目录，Bucket 内的数据不会被自动删除。`,
          cancelLabel: '知道了',
          hideConfirm: true,
        })
      } else {
        setError((reason as Error).message)
      }
    } finally {
      setDeleting(false)
      stopLoading()
    }
  }

  async function updateVersioning(versioning: 'Enabled' | 'Suspended') {
    const stopLoading = startLoading('正在更新 Versioning...')
    try {
      setLoading(true)
      setError('')
      setConfiguration(await api.updateBucketConfiguration(bucketName, { versioning }))
      setBucket((current) => current ? { ...current, versioning } : current)
      showToast(`Versioning 已更新为 ${versioning}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function updateAccessPolicy(access_policy: 'Private' | 'Readonly' | 'Public') {
    const stopLoading = startLoading('正在更新 Access Policy...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, { access_policy })
      setConfiguration(updated)
      showToast(`Access Policy 已更新为 ${access_policy}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function updateEncryption(encryption: 'Disabled' | 'Enabled') {
    const stopLoading = startLoading('正在更新 Encryption...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, { encryption })
      setConfiguration(updated)
      showToast(`Encryption 已更新为 ${encryption}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function enableObjectLocking() {
    if (!configuration || configuration.object_locking) return
    if (configuration.versioning !== 'Enabled') {
      setError('启用 Object Locking 前必须先将 Versioning 设置为 Enabled')
      return
    }
    if (!await confirm({
      title: '启用 Object Locking',
      message: '启用后将无法关闭，并会对新写入对象应用 Retention 和 Legal Hold 保护。是否继续？',
      confirmLabel: '启用',
      danger: true,
    })) return
    const stopLoading = startLoading('正在启用 Object Locking...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, { object_locking: true })
      setConfiguration(updated)
      showToast('Object Locking 已启用')
    } catch (reason) {
      setError((reason as Error).message)
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
        setError(`${label} 必须是大于 0 的整数`)
        return undefined
      }
      return parsed
    }
    const maxBytes = parseLimit(quotaBytes, '字节配额')
    const maxObjects = parseLimit(quotaObjects, '对象数配额')
    if (maxBytes === undefined || maxObjects === undefined) return
    const stopLoading = startLoading('正在保存 Quota...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, {
        max_bytes: maxBytes ?? 0,
        max_objects: maxObjects ?? 0,
      })
      setConfiguration(updated)
      setQuotaBytes(updated.max_bytes == null ? '' : String(updated.max_bytes))
      setQuotaObjects(updated.max_objects == null ? '' : String(updated.max_objects))
      showToast('Quota 已保存')
    } catch (reason) {
      setError((reason as Error).message)
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
      title: '确认更新 Retention',
      message: isEnabling
        ? `启用 Retention 后，新写入对象将在 ${duration} 秒内受到保留限制。是否继续？`
        : isShortening
          ? `保留期限将从 ${currentDuration} 秒缩短为 ${duration} 秒，可能影响后续对象删除。是否继续？`
          : `Retention 模式将从 ${currentMode} 切换为 ${mode}。是否继续？`,
      confirmLabel: '继续更新',
      danger: isShortening || mode === 'COMPLIANCE',
    })) return

    const stopLoading = startLoading('正在更新 Retention...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, {
        retention_enabled: enabled,
        retention_duration_seconds: duration,
        retention_mode: mode,
      })
      setConfiguration(updated)
      showToast(`Retention 已更新为 ${enabled ? `${duration}s / ${mode}` : 'Disabled'}`)
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  function addTag() {
    const key = tagKey.trim()
    if (!key) return
    setTags((current) => ({ ...current, [key]: tagValue.trim() }))
    setTagKey('')
    setTagValue('')
  }

  async function saveTags() {
    // Include an entry that is still being edited when the user saves
    // directly, without pressing “添加” first.
    const pendingKey = tagKey.trim()
    const pendingValue = tagValue.trim()
    const tagsToSave = pendingKey ? { ...tags, [pendingKey]: pendingValue } : tags
    const stopLoading = startLoading('正在保存 Tags...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, Object.keys(tagsToSave).length > 0
        ? { tags_json: JSON.stringify(tagsToSave) }
        : { clear_tags: true })
      setConfiguration(updated)
      setTags(parseTags(updated.tags_json))
      if (pendingKey) {
        setTagKey('')
        setTagValue('')
      }
      showToast('Tags 已保存')
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
      stopLoading()
    }
  }

  async function saveLifecycle(rules: LifecycleRule[]) {
    const stopLoading = startLoading('正在保存 Lifecycle 规则...')
    try {
      setLoading(true)
      setError('')
      const updated = rules.length > 0
        ? await api.updateBucketConfiguration(bucketName, {
            lifecycle_configuration: serializeLifecycleConfiguration(rules),
          })
        : await api.updateBucketConfiguration(bucketName, { clear_lifecycle: true })
      setConfiguration(updated)
      setLifecycleRules(rules)
      setBucket((current) => current ? { ...current, lifecycle_enabled: rules.length > 0 } : current)
      showToast(rules.length > 0 ? 'Lifecycle 规则已保存' : 'Lifecycle 规则已清除')
    } catch (reason) {
      setError((reason as Error).message)
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
          <button className="back-button" type="button" onClick={onBack}><ArrowLeft className="button-icon" aria-hidden="true" />返回 Buckets</button>
          <div className="bucket-identity">
            <span className="bucket-identity-icon" aria-hidden="true"><Archive /></span>
            <div>
              <h2>{bucket?.name ?? bucketName}</h2>
              <p>Owner: <strong>{bucket?.owner ?? '-'}</strong><span>Access: <strong>{configuration?.access_policy ?? 'Private'}</strong></span></p>
            </div>
          </div>
        </div>
        <div className="bucket-detail-actions">
          <button className="icon-button bucket-objects-button" type="button" title="浏览 Bucket 对象" aria-label="浏览 Bucket 对象" onClick={onOpenObjects} disabled={!bucket}>
            <FolderOpen aria-hidden="true" />
          </button>
          <button className="danger-button" type="button" onClick={() => void remove()} disabled={deleting || !bucket || !bucketContentKnown}>
            <Trash2 className="button-icon" aria-hidden="true" />删除 Bucket
          </button>
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={loading} aria-busy={loading}>
            <RefreshCw className={`button-icon${loading ? ' spinning' : ''}`} aria-hidden="true" />刷新
          </button>
        </div>
      </header>

      <section className="panel bucket-settings-panel">
        <nav className="bucket-settings-nav" aria-label="Bucket 配置">
          {sections.map((section) => {
            const available = section === 'Summary' || section === 'Events' || section === 'Lifecycle' || section === 'Access' || section === 'Anonymous'
            return <button key={section} className={activeSection === section ? 'active' : ''} type="button" disabled={!available} title={available ? undefined : '后续版本开放'} onClick={() => available && setActiveSection(section as 'Summary' | 'Events' | 'Lifecycle' | 'Access' | 'Anonymous')}>
              {section}
            </button>
          })}
        </nav>

        <div className="bucket-settings-content">
          <div className="bucket-settings-title">
            <div><p className="eyebrow">Bucket configuration</p><h3>{activeSection}</h3></div>
            <span>创建于 {bucket ? new Date(bucket.created_at).toLocaleString() : '-'}</span>
          </div>

          {activeSection === 'Summary' ? <>
          <div className="bucket-summary-grid">
            <div className="bucket-setting-item bucket-access-policy-setting">
              <div className="bucket-setting-label"><Shield aria-hidden="true" /><span>Access Policy</span></div>
              <select
                aria-label="Bucket access policy"
                value={configuration?.access_policy ?? 'Private'}
                onChange={(event) => void updateAccessPolicy(event.target.value as 'Private' | 'Readonly' | 'Public')}
                disabled={loading || !configuration}
              >
                <option value="Private">Private</option>
                <option value="Readonly">Readonly</option>
                <option value="Public">Public</option>
              </select>
              <small>控制匿名读取和列举权限</small>
            </div>
            <div className="bucket-setting-item bucket-encryption-setting">
              <div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>Encryption</span></div>
              <select aria-label="Bucket encryption" value={configuration?.encryption ?? 'Disabled'} onChange={(event) => void updateEncryption(event.target.value as 'Disabled' | 'Enabled')} disabled={loading || !configuration}>
                <option value="Disabled">Disabled</option>
                <option value="Enabled">Enabled</option>
              </select>
              <small>新写入对象使用服务端 AES-256-GCM；历史明文对象保持兼容</small>
            </div>
            <div className="bucket-usage">
              <ChartPie aria-hidden="true" />
              <div><span>Reported Usage</span><strong>{formatBytes(usage.bytes)}</strong><small>{usage.objects.toLocaleString()} 个对象</small></div>
            </div>
            <SettingItem
              icon={CircleX}
              label="Replication"
              value={configuration?.replication_status === 'UNAVAILABLE' ? 'Unavailable' : 'Disabled'}
              status="unavailable"
              editable={false}
              description="当前部署模式未开放，需要第二存储站点"
            />
            <div className="bucket-setting-item bucket-object-locking-setting">
              <div className="bucket-setting-label"><LockKeyhole aria-hidden="true" /><span>Object Locking</span></div>
              <div className="bucket-setting-value">
                <strong className={configuration?.object_locking ? 'enabled' : 'disabled'}>{configuration?.object_locking ? 'Enabled' : 'Disabled'}</strong>
                {!configuration?.object_locking && <button className="bucket-setting-edit" type="button" aria-label="启用 Object Locking" title="启用 Object Locking" onClick={() => void enableObjectLocking()} disabled={loading || !configuration}><Pencil aria-hidden="true" /></button>}
              </div>
              <small>{configuration?.object_locking ? '启用后不可关闭；新对象遵守 Retention 和 Legal Hold' : '启用前需要 Versioning 为 Enabled'}</small>
            </div>
            <div className="bucket-setting-item bucket-tags-setting">
              <div className="bucket-setting-label"><Tags aria-hidden="true" /><span>Tags</span></div>
              <div className="bucket-tags-list">
                {Object.entries(tags).map(([key, value]) => <div className="bucket-tag-row" key={key}>
                  <span>{key}</span><b>{value}</b>
                  <button type="button" aria-label={`删除标签 ${key}`} title="删除标签" onClick={() => void (async () => {
                    if (!await confirm({ title: '删除标签', message: `确认删除标签 “${key}”？`, confirmLabel: '删除', danger: true })) return
                    setTags((current) => {
                      const next = { ...current }
                      delete next[key]
                      return next
                    })
                  })()} disabled={loading}><Trash2 aria-hidden="true" /></button>
                </div>)}
                {Object.keys(tags).length === 0 && <small>尚未配置</small>}
              </div>
              <div className="bucket-tags-editor">
                <input aria-label="标签 Key" placeholder="Key" value={tagKey} onChange={(event) => setTagKey(event.target.value)} disabled={loading} />
                <input aria-label="标签 Value" placeholder="Value" value={tagValue} onChange={(event) => setTagValue(event.target.value)} disabled={loading} />
                <button className="secondary-button bucket-tag-add" type="button" onClick={addTag} disabled={loading || !tagKey.trim()} title="添加标签" aria-label="添加标签"><Plus className="button-icon" aria-hidden="true" /></button>
              </div>
              <button className="primary-button bucket-tags-save" type="button" onClick={() => void saveTags()} disabled={loading}>保存 Tags</button>
            </div>
          </div>

          <SettingsSection title="Versioning">
            <div className="bucket-setting-item bucket-versioning-control">
              <div className="bucket-setting-label"><Archive aria-hidden="true" /><span>Versioning</span></div>
              <div className="segmented-control" aria-label="Bucket versioning">
                <button type="button" className={configuration?.versioning === 'Enabled' ? 'active' : ''} onClick={() => void updateVersioning('Enabled')} disabled={loading}>Enabled</button>
                <button type="button" className={configuration?.versioning === 'Suspended' ? 'active' : ''} onClick={() => void updateVersioning('Suspended')} disabled={loading || configuration?.versioning === 'Unversioned'}>Suspended</button>
              </div>
              <small>{configuration?.versioning === 'Unversioned' ? '启用后将为新写入生成版本 ID' : '版本历史由 ZigFS 持久化管理'}</small>
            </div>
            <div className="bucket-setting-item bucket-quota-setting">
              <div className="bucket-setting-label"><Gauge aria-hidden="true" /><span>Quota</span></div>
              <div className="bucket-quota-summary">
                <strong>{configuration?.max_bytes == null ? 'Unlimited' : formatBytes(configuration.max_bytes)}</strong>
                <span>/</span>
                <strong>{configuration?.max_objects == null ? 'Unlimited' : `${configuration.max_objects.toLocaleString()} objects`}</strong>
              </div>
              <div className="bucket-quota-editor">
                <input aria-label="最大字节数" type="number" min="1" step="1" placeholder="字节数上限" value={quotaBytes} onChange={(event) => setQuotaBytes(event.target.value)} disabled={loading || !configuration} />
                <input aria-label="最大对象数" type="number" min="1" step="1" placeholder="对象数上限" value={quotaObjects} onChange={(event) => setQuotaObjects(event.target.value)} disabled={loading || !configuration} />
                <button className="secondary-button" type="button" onClick={() => void saveQuota()} disabled={loading || !configuration}>保存</button>
              </div>
              <small>留空表示不限制；当前使用量 {formatBytes(usage.bytes)} / {usage.objects.toLocaleString()} objects</small>
            </div>
          </SettingsSection>

          <SettingsSection title="Retention">
            <div className="bucket-setting-item bucket-retention-setting">
              <div className="bucket-setting-label"><KeyRound aria-hidden="true" /><span>Retention</span></div>
              <label className="bucket-inline-toggle">
                <input
                  type="checkbox"
                  aria-label="启用 Retention"
                  checked={configuration?.retention_enabled ?? false}
                  onChange={(event) => void updateRetention({ enabled: event.target.checked })}
                  disabled={loading || !configuration}
                />
                <span>Enabled</span>
              </label>
              <div className="bucket-retention-controls">
                <label>
                  <span>Duration</span>
                  <input
                    type="number"
                    min={1}
                    aria-label="Retention duration seconds"
                    value={configuration?.retention_duration_seconds ?? 86400}
                    onChange={(event) => {
                      const value = Number(event.target.value)
                      if (Number.isSafeInteger(value) && value > 0) void updateRetention({ duration: value })
                    }}
                    disabled={loading || !configuration}
                  />
                  <span>s</span>
                </label>
                <label>
                  <span>Mode</span>
                  <select
                    aria-label="Retention mode"
                    value={configuration?.retention_mode ?? 'GOVERNANCE'}
                    onChange={(event) => void updateRetention({ mode: event.target.value as 'GOVERNANCE' | 'COMPLIANCE' })}
                    disabled={loading || !configuration}
                  >
                    <option value="GOVERNANCE">GOVERNANCE</option>
                    <option value="COMPLIANCE">COMPLIANCE</option>
                  </select>
                </label>
              </div>
              <small>{configuration?.retention_enabled ? '新写入对象继承默认保留期限' : '启用后新写入对象将继承保留期限'}</small>
            </div>
          </SettingsSection>
          </> : activeSection === 'Events' ? <EventsOverview api={api} bucket={bucket} configuration={configuration} /> : activeSection === 'Lifecycle' ? <LifecycleRulesEditor
            rules={lifecycleRules}
            configured={Boolean(configuration?.lifecycle_configuration)}
            loading={loading}
            onSave={saveLifecycle}
          /> : activeSection === 'Access' ? <AccessOverview bucket={bucket} configuration={configuration} loading={loading} onPolicyChange={updateAccessPolicy} /> : <AnonymousOverview configuration={configuration} />}
        </div>
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

function AccessOverview({ bucket, configuration, loading, onPolicyChange }: {
  bucket: Bucket | null
  configuration: BucketConfiguration | null
  loading: boolean
  onPolicyChange: (policy: 'Private' | 'Readonly' | 'Public') => void
}) {
  const policy = configuration?.access_policy ?? 'Private'
  const anonymousRead = policy === 'Readonly' || policy === 'Public'
  const anonymousList = policy === 'Public'
  return (
    <div className="bucket-access-overview">
      <div className="bucket-access-hero">
        <Shield aria-hidden="true" />
        <div><h4>Bucket Access</h4><p>访问权限由 ZigFS 持久化配置统一控制。</p></div>
      </div>
      <dl className="bucket-access-list">
        <div><dt>Owner</dt><dd>{bucket?.owner ?? '-'}</dd></div>
        <div><dt>Access Policy</dt><dd><select aria-label="Access 页面策略" value={policy} onChange={(event) => onPolicyChange(event.target.value as 'Private' | 'Readonly' | 'Public')} disabled={loading || !configuration}><option value="Private">Private</option><option value="Readonly">Readonly</option><option value="Public">Public</option></select></dd></div>
        <div><dt>Anonymous object read</dt><dd className={anonymousRead ? 'allowed' : 'denied'}>{anonymousRead ? 'Allowed' : 'Denied'}</dd></div>
        <div><dt>Anonymous bucket listing</dt><dd className={anonymousList ? 'allowed' : 'denied'}>{anonymousList ? 'Allowed' : 'Denied'}</dd></div>
        <div><dt>Anonymous write / delete</dt><dd className="denied">Denied</dd></div>
      </dl>
      <p className="bucket-access-note">Access Policy 可在 Summary 中修改。匿名策略只影响读取和列举，写入与删除仍需要授权凭证。</p>
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
        <div><h4>Anonymous Access</h4><p>匿名请求不携带 Access Key，权限由当前 Access Policy 决定。</p></div>
      </div>
      <div className="bucket-anonymous-policy"><span>Current policy</span><strong>{policy}</strong></div>
      <div className="bucket-anonymous-list">
        {permissions.map(([action, allowed]) => <div key={action}><span>{action}</span><b className={allowed ? 'allowed' : 'denied'}>{allowed ? 'Allowed' : 'Denied'}</b></div>)}
      </div>
      <p className="bucket-access-note">修改匿名权限请前往 Access 页面或 Summary 中的 Access Policy。匿名写入、删除和 Bucket 管理操作始终需要授权凭证。</p>
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
      showToast(reason instanceof Error ? reason.message : '加载审计事件失败')
    } finally {
      setLoading(false)
    }
  }, [action, api, bucket, from, outcome, showToast, to])
  useEffect(() => { void loadEvents() }, [loadEvents])
  const configurationEvents = [
    ['Bucket loaded', bucket ? `Owner ${bucket.owner}` : 'Loading'],
    ['Access Policy', configuration?.access_policy ?? 'Unknown'],
    ['Encryption', configuration?.encryption ?? 'Unknown'],
    ['Retention', configuration?.retention_enabled ? `${configuration.retention_duration_seconds ?? 0}s / ${configuration.retention_mode ?? 'GOVERNANCE'}` : 'Disabled'],
    ['Object Locking', configuration?.object_locking ? 'Enabled' : 'Disabled'],
    ['Replication', configuration?.replication_status ?? 'Unknown'],
  ] as const
  return (
    <div className="bucket-events-overview">
      <div className="bucket-access-hero">
        <Activity aria-hidden="true" />
        <div><h4>Configuration Events</h4><p>当前配置状态来自 ZigFS；审计时间线支持持久化查询和时间范围筛选。</p></div>
      </div>
      <div className="bucket-events-list">
        {configurationEvents.map(([event, value]) => <div key={event}><span>{event}</span><b>{value}</b></div>)}
      </div>
      <h4>Audit timeline</h4>
      <div className="bucket-events-filters">
        <label>From <input type="datetime-local" value={from} onChange={(event) => setFrom(event.target.value)} /></label>
        <label>To <input type="datetime-local" value={to} onChange={(event) => setTo(event.target.value)} /></label>
        <label>Action <input value={action} placeholder="update_retention" onChange={(event) => setAction(event.target.value)} /></label>
        <label>Outcome <input value={outcome} placeholder="updated" onChange={(event) => setOutcome(event.target.value)} /></label>
        <button type="button" className="secondary-button" onClick={() => void loadEvents()} disabled={loading}>Apply</button>
      </div>
      <div className="bucket-events-list">
        {events.map((event) => <div key={`${event.request_id}-${event.timestamp_unix_seconds}`}><span>{new Date(event.timestamp_unix_seconds * 1000).toLocaleString()}</span><b>{event.action} · {event.outcome}</b></div>)}
      </div>
      {loaded && events.length === 0 && <p className="bucket-access-note">当前筛选范围暂无审计事件。</p>}
      <div className="bucket-events-actions">
        <button type="button" className="secondary-button" onClick={() => void loadEvents()} disabled={loading}>{loading ? '加载中…' : '刷新事件'}</button>
        {nextCursor && <button type="button" className="secondary-button" onClick={() => void loadEvents(nextCursor, true)} disabled={loading}>加载更多</button>}
      </div>
      <p className="bucket-access-note">当前配置快照与审计时间线分开展示；历史事件会自动从归档文件合并查询。</p>
    </div>
  )
}

function SettingItem({ icon: Icon, label, value, status = 'unavailable', editable = true, description = '当前版本暂未开放配置' }: {
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
        {editable && <button className="bucket-setting-edit" type="button" aria-label={`编辑 ${label}`} title="后续版本开放" disabled><Pencil aria-hidden="true" /></button>}
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
