import { useCallback, useEffect, useState, type ReactNode } from 'react'
import {
  ArrowLeft,
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
import type { Bucket, BucketConfiguration } from '../../types/api'
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
  const [activeSection, setActiveSection] = useState<'Summary' | 'Lifecycle'>('Summary')
  const [lifecycleRules, setLifecycleRules] = useState<LifecycleRule[]>([])
  const [tags, setTags] = useState<Record<string, string>>({})
  const [tagKey, setTagKey] = useState('')
  const [tagValue, setTagValue] = useState('')
  const [usage, setUsage] = useState<BucketUsage>({ bytes: 0, objects: 0 })
  const [bucketContentKnown, setBucketContentKnown] = useState(false)
  const [bucketHasContent, setBucketHasContent] = useState(false)
  const [loading, setLoading] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState('')

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
    const stopLoading = startLoading('正在保存 Tags...')
    try {
      setLoading(true)
      setError('')
      const updated = await api.updateBucketConfiguration(bucketName, Object.keys(tags).length > 0
        ? { tags_json: JSON.stringify(tags) }
        : { clear_tags: true })
      setConfiguration(updated)
      setTags(parseTags(updated.tags_json))
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

      {error && <p className="error-banner">{error}</p>}

      <section className="panel bucket-settings-panel">
        <nav className="bucket-settings-nav" aria-label="Bucket 配置">
          {sections.map((section) => {
            const available = section === 'Summary' || section === 'Lifecycle'
            return <button key={section} className={activeSection === section ? 'active' : ''} type="button" disabled={!available} title={available ? undefined : '后续版本开放'} onClick={() => available && setActiveSection(section as 'Summary' | 'Lifecycle')}>
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
            <SettingItem icon={CircleX} label="Replication" value={configuration?.replication_status === 'UNAVAILABLE' ? 'Unavailable' : 'Disabled'} status="unavailable" />
            <SettingItem icon={LockKeyhole} label="Object Locking" value={configuration?.object_locking ? 'Enabled' : 'Disabled'} status={configuration?.object_locking ? 'enabled' : 'disabled'} />
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
                <button className="secondary-button" type="button" onClick={addTag} disabled={loading || !tagKey.trim()} title="添加标签"><Plus className="button-icon" aria-hidden="true" />添加</button>
              </div>
              <button className="primary-button bucket-tags-save" type="button" onClick={() => void saveTags()} disabled={loading}><span>保存 Tags</span></button>
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
            <SettingItem icon={Gauge} label="Quota" value={configuration?.max_bytes == null && configuration?.max_objects == null ? 'Disabled' : `${configuration?.max_bytes == null ? 'Unlimited' : formatBytes(configuration.max_bytes)} / ${configuration?.max_objects == null ? 'Unlimited' : `${configuration.max_objects.toLocaleString()} objects`}`} status={configuration?.max_bytes == null && configuration?.max_objects == null ? 'unavailable' : 'enabled'} />
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
          </> : <LifecycleRulesEditor
            rules={lifecycleRules}
            configured={Boolean(configuration?.lifecycle_configuration)}
            loading={loading}
            onSave={saveLifecycle}
          />}
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

function SettingItem({ icon: Icon, label, value, status = 'unavailable' }: {
  icon: LucideIcon
  label: string
  value: string
  status?: 'enabled' | 'disabled' | 'unavailable'
}) {
  return (
    <div className="bucket-setting-item">
      <div className="bucket-setting-label"><Icon aria-hidden="true" /><span>{label}</span></div>
      <div className="bucket-setting-value">
        <strong className={status}>{value}</strong>
        <button className="bucket-setting-edit" type="button" aria-label={`编辑 ${label}`} title="后续版本开放" disabled><Pencil aria-hidden="true" /></button>
      </div>
      <small>当前版本暂未开放配置</small>
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
