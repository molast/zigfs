import { Database, FileText, Globe, Home, Info, RefreshCw, Settings as SettingsIcon, ShieldCheck, CircleCheck, Box } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { Badge } from '../../components/ui/Badge'
import { Button } from '../../components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Field, FieldDescription, FieldGroup, FieldLabel, FieldLegend, FieldSet } from '../../components/ui/field'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { Separator } from '../../components/ui/separator'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { SettingsPanels } from './SettingsPanels'
import type { ManagementHealth, StorageInfo, StorageScannerStatus, Settings, SystemInfo } from '../../types/api'

const categories = [
  { id: 'general', label: '常规设置', subtitle: '实例基本信息', description: '查看实例的基本信息和运行参数', icon: Home },
  { id: 'network', label: '网络设置', subtitle: '网络与访问', description: '查看 API 监听地址、公开访问入口和 S3 寻址配置', icon: Globe },
  { id: 'security', label: '安全设置', subtitle: '安全策略配置', description: '查看管理会话与请求签名校验参数', icon: ShieldCheck },
  { id: 'storage', label: '存储设置', subtitle: '存储策略与参数', description: '查看存储缓冲、分片上传保留期和生命周期扫描参数', icon: Database },
  { id: 'logs', label: '日志设置', subtitle: '日志与可观测性', description: '查看实例的监控指标配置和日志配置范围', icon: FileText },
  { id: 'about', label: '关于 ZigFS', subtitle: '版本与信息', description: '查看当前服务版本与实例运行信息', icon: Info },
] as const

type Category = typeof categories[number]['id']
interface SettingItem { id: string; label: string; value: string; help?: string; multiline?: boolean }
interface SettingGroup { title: string; items: SettingItem[] }

export function SettingsView({ api }: { api: ApiClient }) {
  const [category, setCategory] = useState<Category>('general')
  const [settings, setSettings] = useState<Settings | null>(null)
  const [system, setSystem] = useState<SystemInfo | null>(null)
  const [storage, setStorage] = useState<StorageInfo | null>(null)
  const [scanner, setScanner] = useState<StorageScannerStatus | null>(null)
  const [health, setHealth] = useState<ManagementHealth | null>(null)
  const [observedAt, setObservedAt] = useState<Date | null>(null)
  const [busy, setBusy] = useState(false)
  const mounted = useRef(false)
  const pending = useRef(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    if (pending.current) return
    pending.current = true
    setBusy(true)
    try {
      const results = await Promise.allSettled([api.settings(), api.system(), api.storage(), api.storageScanner(), api.managementHealth()])
      const [configuration, runtime, capacity, scan, readiness] = results
      if (!mounted.current) return
      setSettings(configuration.status === 'fulfilled' ? configuration.value : null)
      setSystem(runtime.status === 'fulfilled' ? runtime.value : null)
      setStorage(capacity.status === 'fulfilled' ? capacity.value : null)
      setScanner(scan.status === 'fulfilled' ? scan.value : null)
      setHealth(readiness.status === 'fulfilled' ? readiness.value : null)
      setObservedAt(new Date())
      if (results.some(result => result.status === 'rejected')) notifyError('部分系统信息加载失败，请点击刷新配置重试。')
    } finally {
      pending.current = false
      if (mounted.current) setBusy(false)
    }
  }, [api, notifyError])

  useEffect(() => {
    mounted.current = true
    void refresh()
    return () => { mounted.current = false }
  }, [refresh])

  const startup = system && observedAt ? new Date(observedAt.getTime() - system.uptime * 1000).toLocaleString() : '—'
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const groups: Partial<Record<Category, SettingGroup[]>> = {
    general: [
      { title: '实例信息', items: [
        { id: 'service', label: '服务名称', value: 'ZigFS', help: '当前对象存储服务' },
        { id: 'description', label: '实例描述', value: '未上报', multiline: true, help: '当前服务未提供自定义实例描述' },
        { id: 'instance-id', label: '实例 ID', value: '未上报', help: '当前服务未提供独立的实例标识' },
        { id: 'startup', label: '启动时间', value: startup, help: '根据最近一次上报的运行时长估算，按浏览器时区显示' },
        { id: 'uptime', label: '运行时长', value: system ? duration(system.uptime) : '—', help: '截至最近一次刷新' },
      ] },
      { title: '基本配置', items: [
        { id: 'region', label: '默认区域', value: settings?.s3_region ?? '—', help: 'S3 服务区域与签名校验区域' },
        { id: 'timezone', label: '显示时区', value: timezone, help: '当前浏览器时区；服务端时间使用 UTC' },
        { id: 'date-format', label: '日期时间格式', value: '跟随浏览器区域设置', help: '时间按本地日期与时间格式显示' },
      ] },
    ],
    security: [
      { title: '会话安全', items: [
        { id: 'session-ttl', label: '管理会话有效期', value: settings ? duration(settings.admin_session_ttl_seconds) : '—', help: '管理控制台会话的最长有效时间' },
      ] },
      { title: '请求校验', items: [
        { id: 'clock-skew', label: '签名时钟偏差', value: settings ? duration(settings.request_time_skew_seconds) : '—', help: 'S3 签名允许的客户端与服务端时间偏差' },
      ] },
    ],

  }

  return <section className="system-settings-page" aria-busy={busy}>
    <header className="system-settings-heading"><SettingsIcon aria-hidden="true" /><div><h2>系统设置</h2><p>查看 ZigFS 实例的全局参数</p></div></header>
    <Tabs value={category} onValueChange={value => setCategory(value as Category)} orientation="vertical" className="system-settings-layout">
      <Card className="system-settings-navigation"><TabsList aria-label="系统设置分类" className="system-settings-nav">
        {categories.map(item => <TabsTrigger key={item.id} value={item.id}><item.icon aria-hidden="true" /><span><strong>{item.label}</strong><small>{item.subtitle}</small></span></TabsTrigger>)}
      </TabsList></Card>
      <div className="system-settings-main">
        <Card className="system-settings-editor">
          {categories.map(item => <TabsContent key={item.id} value={item.id} className="system-settings-tab">
            <CardHeader><div className="system-settings-section-heading"><item.icon aria-hidden="true" /><div><CardTitle>{item.label}</CardTitle><CardDescription>{item.description}</CardDescription></div><Badge>{busy ? '加载中' : settings ? '当前生效 · 只读' : '配置未获取'}</Badge></div></CardHeader>
            <CardContent className="system-settings-scroll">{groups[item.id] ? <Card className="system-settings-form"><CardContent>
              {groups[item.id]?.map((group, index) => <div key={group.title}>{index > 0 && <Separator />}<FieldSet><FieldLegend>{group.title}</FieldLegend><FieldGroup>
                {group.items.map(setting => <Field key={setting.id} className="system-settings-field"><FieldLabel htmlFor={`system-${setting.id}`}>{setting.label}</FieldLabel>{setting.multiline ? <Textarea id={`system-${setting.id}`} readOnly value={setting.value} rows={2} aria-describedby={setting.help ? `system-${setting.id}-help` : undefined} /> : <Input id={`system-${setting.id}`} readOnly value={setting.value} aria-describedby={setting.help ? `system-${setting.id}-help` : undefined} />}{setting.help && <FieldDescription id={`system-${setting.id}-help`}>{setting.help}</FieldDescription>}</Field>)}
              </FieldGroup></FieldSet></div>)}
            </CardContent></Card> : <SettingsPanels category={item.id} settings={settings} system={system} storage={storage} scanner={scanner} health={health} />}</CardContent>
          </TabsContent>)}
          <footer className="system-settings-actions"><span>当前配置仅供查看；修改服务配置后需重启 ZigFS。</span><Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{busy ? '加载中…' : '刷新配置'}</Button></footer>
        </Card>
        <div className="system-settings-notes">
          <Card><CardHeader><CircleCheck aria-hidden="true" /><div><CardTitle>当前配置</CardTitle><CardDescription>展示运行中的实际生效值</CardDescription></div></CardHeader></Card>
          <Card><CardHeader><Info aria-hidden="true" /><div><CardTitle>重启提示</CardTitle><CardDescription>服务配置修改后需重启生效</CardDescription></div></CardHeader></Card>
          <Card><CardHeader><Box aria-hidden="true" /><div><CardTitle>实例信息</CardTitle><CardDescription>版本：{system?.version ?? '—'} · 最近读取：{observedAt?.toLocaleTimeString() ?? '—'}</CardDescription></div></CardHeader></Card>
        </div>
      </div>
    </Tabs>
  </section>
}

function duration(seconds: number) {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor(seconds % 86400 / 3600)
  const minutes = Math.floor(seconds % 3600 / 60)
  const rest = Math.floor(seconds % 60)
  return [days && `${days} 天`, hours && `${hours} 小时`, minutes && `${minutes} 分钟`, rest && `${rest} 秒`].filter(Boolean).join(' ') || '0 秒'
}
