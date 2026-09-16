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
      const [buckets, bucketConfiguration] = await Promise.all([
        api.listBuckets(),
        api.getBucketConfiguration(bucketName),
      ])
      const current = buckets.find((item) => item.name === bucketName)
      if (!current) throw new Error(`Bucket “${bucketName}” 不存在`)
      setBucket(current)
      setConfiguration(bucketConfiguration)
      setLifecycleRules(bucketConfiguration.lifecycle_configuration
        ? parseLifecycleConfiguration(bucketConfiguration.lifecycle_configuration)
        : [])

      let continuationToken = ''
      let bytes = 0
      let objects = 0
      let hasContent = false
      do {
        const page = await api.listObjects(bucketName, '', continuationToken, '', 1000, '/')
        objects += page.items.length
        bytes += page.items.reduce((total, item) => total + item.size, 0)
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
              <p>Owner: <strong>{bucket?.owner ?? '-'}</strong><span>Access: <strong>Private</strong></span></p>
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
            <SettingItem icon={Shield} label="Access Policy" value="Private" />
            <SettingItem icon={LockKeyhole} label="Encryption" value="Disabled" />
            <div className="bucket-usage">
              <ChartPie aria-hidden="true" />
              <div><span>Reported Usage</span><strong>{formatBytes(usage.bytes)}</strong><small>{usage.objects.toLocaleString()} 个对象</small></div>
            </div>
            <SettingItem icon={CircleX} label="Replication" value="Disabled" status="disabled" />
            <SettingItem icon={LockKeyhole} label="Object Locking" value="Disabled" status="disabled" />
            <div className="bucket-setting-item bucket-tags-setting">
              <div className="bucket-setting-label"><Tags aria-hidden="true" /><span>Tags</span></div>
              <button className="secondary-button" type="button" disabled title="后续版本开放"><Plus className="button-icon" aria-hidden="true" />添加标签</button>
              <small>尚未配置</small>
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
            <SettingItem icon={Gauge} label="Quota" value="Disabled" status="unavailable" />
          </SettingsSection>

          <SettingsSection title="Retention">
            <SettingItem icon={KeyRound} label="Retention" value="Disabled" status="unavailable" />
            <SettingItem icon={LockKeyhole} label="Mode" value="-" status="unavailable" />
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
