import { useCallback, useEffect, useState, type ReactNode } from 'react'
import {
  ArrowLeft,
  Archive,
  CircleX,
  Database,
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
import type { ApiClient } from '../../api/client'
import type { Bucket } from '../../types/api'

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
  const [bucket, setBucket] = useState<Bucket | null>(null)
  const [usage, setUsage] = useState<BucketUsage>({ bytes: 0, objects: 0 })
  const [loading, setLoading] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    if (!bucketName) return
    try {
      setLoading(true)
      setError('')
      const buckets = await api.listBuckets()
      const current = buckets.find((item) => item.name === bucketName)
      if (!current) throw new Error(`Bucket “${bucketName}” 不存在`)
      setBucket(current)

      let continuationToken = ''
      let bytes = 0
      let objects = 0
      do {
        const page = await api.listObjects(bucketName, '', continuationToken)
        objects += page.items.length
        bytes += page.items.reduce((total, item) => total + item.size, 0)
        const nextToken = page.continuation_token ?? ''
        if (!nextToken || nextToken === continuationToken) break
        continuationToken = nextToken
      } while (continuationToken)
      setUsage({ bytes, objects })
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setLoading(false)
    }
  }, [api, bucketName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function remove() {
    if (!window.confirm(`删除 Bucket “${bucketName}”？`)) return
    try {
      setDeleting(true)
      setError('')
      await api.deleteBucket(bucketName)
      onDeleted()
    } catch (reason) {
      setError((reason as Error).message)
    } finally {
      setDeleting(false)
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
          <button className="danger-button" type="button" onClick={() => void remove()} disabled={deleting || !bucket}>
            <Trash2 className="button-icon" aria-hidden="true" />{deleting ? '删除中...' : '删除 Bucket'}
          </button>
          <button className="secondary-button" type="button" onClick={() => void refresh()} disabled={loading}>
            <RefreshCw className={`button-icon${loading ? ' spinning' : ''}`} aria-hidden="true" />{loading ? '刷新中...' : '刷新'}
          </button>
        </div>
      </header>

      {error && <p className="error-banner">{error}</p>}

      <section className="panel bucket-settings-panel">
        <nav className="bucket-settings-nav" aria-label="Bucket 配置">
          {sections.map((section, index) => (
            <button key={section} className={index === 0 ? 'active' : ''} type="button" disabled={index !== 0} title={index === 0 ? undefined : '后续版本开放'}>
              {section}
            </button>
          ))}
        </nav>

        <div className="bucket-settings-content">
          <div className="bucket-settings-title">
            <div><p className="eyebrow">Bucket configuration</p><h3>Summary</h3></div>
            <span>创建于 {bucket ? new Date(bucket.created_at).toLocaleString() : '-'}</span>
          </div>

          <div className="bucket-summary-grid">
            <SettingItem icon={Shield} label="Access Policy" value="Private" />
            <SettingItem icon={LockKeyhole} label="Encryption" value="Disabled" />
            <div className="bucket-usage">
              <Database aria-hidden="true" />
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
            <SettingItem icon={Archive} label="Versioning" value="Unversioned" status="unavailable" />
            <SettingItem icon={Gauge} label="Quota" value="Disabled" status="unavailable" />
          </SettingsSection>

          <SettingsSection title="Retention">
            <SettingItem icon={KeyRound} label="Retention" value="Disabled" status="unavailable" />
            <SettingItem icon={LockKeyhole} label="Mode" value="-" status="unavailable" />
          </SettingsSection>
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
