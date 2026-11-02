import { Clock, Database, FileText, Globe, HardDrive, Info, Link, List, Monitor, Scale, ShieldCheck } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'
import { Badge } from '../../components/ui/Badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Input } from '../../components/ui/Input'
import { Alert, AlertDescription } from '../../components/ui/alert'
import { Progress } from '../../components/ui/progress'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import type { ManagementHealth, Settings, StorageInfo, StorageScannerStatus, SystemInfo } from '../../types/api'

export interface SettingsPanelProps {
  category: string
  settings: Settings | null
  system: SystemInfo | null
  storage: StorageInfo | null
  scanner: StorageScannerStatus | null
  health: ManagementHealth | null
}

function Section({ icon: Icon, title, description, children }: { icon: LucideIcon; title: string; description?: string; children: ReactNode }) {
  return <Card className="settings-detail-card"><CardHeader><div className="system-settings-section-heading"><Icon aria-hidden="true" /><div><CardTitle>{title}</CardTitle>{description && <CardDescription>{description}</CardDescription>}</div></div></CardHeader><CardContent>{children}</CardContent></Card>
}

function ReadField({ id, label, value = '未上报', help }: { id: string; label: string; value?: string; help?: string }) {
  return <Field className="settings-detail-field"><FieldLabel htmlFor={`setting-detail-${id}`}>{label}</FieldLabel><div><Input id={`setting-detail-${id}`} value={value} readOnly aria-describedby={help ? `setting-help-${id}` : undefined} />{help && <FieldDescription id={`setting-help-${id}`}>{help}</FieldDescription>}</div></Field>
}

function Note({ children }: { children: ReactNode }) {
  return <Alert role="note" className="settings-detail-note"><Info aria-hidden="true" /><AlertDescription>{children}</AlertDescription></Alert>
}

function bytes(value: number | null | undefined) {
  if (value == null) return '未上报'
  if (value === 0) return '0 B'
  const index = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)))
  return `${(value / 1024 ** index).toLocaleString(undefined, { maximumFractionDigits: 2 })} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][index]}`
}

function addressParts(address?: string) {
  if (!address) return ['—', '—']
  const match = address.match(/^(\[.*\]|[^:]+):(\d+)$/)
  return match ? [match[1], match[2]] : [address, '未上报']
}

export function SettingsPanels({ category, settings, system, storage, scanner, health }: SettingsPanelProps) {
  const [host, port] = addressParts(settings?.api_address)
  const percentage = storage?.physical_used != null && storage.total != null && storage.total > 0 ? Math.min(100, Math.max(0, storage.physical_used / storage.total * 100)) : null
  const ready = health?.status === 'ready' && health.recovery === 'ready'
  const scanState = !scanner ? '未获取' : scanner.running ? '扫描中' : scanner.last_attempt_succeeded === false ? '最近扫描失败' : scanner.last_scan ? '扫描完成' : '尚未扫描'
  const capacity = <><dl className="settings-facts"><div><dt>已用空间</dt><dd>{bytes(storage?.physical_used)}</dd></div><div><dt>可用空间</dt><dd>{bytes(storage?.available)}</dd></div><div><dt>总容量</dt><dd>{bytes(storage?.total)}</dd></div></dl>{percentage != null && <Progress value={percentage} aria-label={`磁盘已使用 ${percentage.toFixed(1)}%`} />}</>

  if (category === 'network') return <div className="settings-detail-stack">
    <Section icon={Globe} title="S3 API 服务" description="S3 兼容 API 的监听地址与端口"><FieldGroup className="settings-field-pair"><ReadField id="s3-host" label="监听地址" value={host} /><ReadField id="s3-port" label="端口" value={port} /></FieldGroup><Note>S3 与 ZigFS 管理 API 共用监听地址：{settings?.api_address ?? '未获取'}。实际可访问范围由部署网络配置决定。</Note></Section>
    <Section icon={Monitor} title="管理控制台服务" description="Admin 控制台与 BFF 的访问入口"><FieldGroup className="settings-field-pair"><ReadField id="admin-origin" label="当前访问地址" value={window.location.origin} help="浏览器访问入口，不代表服务端监听地址" /><ReadField id="admin-bind" label="监听地址与端口" help="当前接口未提供 Admin 进程的监听配置" /></FieldGroup></Section>
    <Section icon={Globe} title="公网访问" description="对外访问的域名或地址"><FieldGroup><ReadField id="public-endpoint" label="外部地址" value={settings ? settings.s3_public_endpoint || '未配置' : '—'} help="反向代理或域名对应的 S3 公开服务入口" /><ReadField id="host-style" label="虚拟主机寻址" value={settings ? settings.s3_virtual_hosted_style ? '已启用' : '已禁用' : '—'} /></FieldGroup></Section>
    <Section icon={ShieldCheck} title="可信代理" description="代理服务器与访问边界"><FieldGroup><ReadField id="trusted-proxy" label="代理地址" help="当前接口未提供可信代理列表；此处不代表允许任意代理" /></FieldGroup></Section>
  </div>

  if (category === 'logs') return <Tabs defaultValue="configuration" className="settings-log-tabs"><TabsList aria-label="日志设置分类"><TabsTrigger value="configuration"><FileText aria-hidden="true" />日志配置</TabsTrigger><TabsTrigger value="audit"><ShieldCheck aria-hidden="true" />审计日志</TabsTrigger><TabsTrigger value="management"><List aria-hidden="true" />日志管理</TabsTrigger></TabsList>
    <TabsContent value="configuration"><div className="settings-detail-stack">
      <Section icon={FileText} title="日志配置" description="系统日志的级别、格式和输出方式"><FieldGroup><ReadField id="log-level" label="日志级别" /><ReadField id="log-format" label="日志格式" /><ReadField id="log-output" label="日志输出" /><ReadField id="log-directory" label="日志目录" help="日志配置尚未由当前管理接口上报" /></FieldGroup></Section>
      <Section icon={Clock} title="日志保留" description="日志文件的保留时间与大小限制"><FieldGroup className="settings-field-pair"><ReadField id="log-days" label="保留时间" value="由部署环境管理" /><ReadField id="log-size" label="最大文件大小" /><ReadField id="log-clean" label="自动清理" /></FieldGroup></Section>
      <Section icon={List} title="日志访问" description="日志查询与下载"><FieldGroup className="settings-field-pair"><ReadField id="log-download" label="日志下载" value="当前页面未提供" /><ReadField id="log-range" label="查询范围" value="当前页面未提供" /></FieldGroup></Section>
      <Note>请通过部署环境管理日志输出、轮转与保留策略；本页暂不支持保存日志配置。</Note>
    </div></TabsContent>
    <TabsContent value="audit"><Section icon={ShieldCheck} title="审计日志" description="操作记录与审计访问"><Note>Bucket 操作记录可在对应 Bucket 的事件页面查看。当前接口未提供全局审计日志配置，不能在此修改采集和保留策略。</Note></Section></TabsContent>
    <TabsContent value="management"><Section icon={List} title="日志管理" description="可观测性与日志文件管理"><FieldGroup><ReadField id="log-metrics" label="Metrics" value={settings ? settings.metrics_enabled ? '已启用' : '已禁用' : '—'} /><ReadField id="log-metrics-address" label="指标监听地址" value={settings ? settings.metrics_enabled ? settings.metrics_address : '已禁用' : '—'} /></FieldGroup><Note>日志文件的列举、下载与删除尚未接入管理接口。</Note></Section></TabsContent>
  </Tabs>

  if (category === 'storage') return <div className="settings-detail-stack">
    <Section icon={Database} title="存储概览" description="当前实例所在文件系统的真实容量"><div className="settings-storage-overview"><div className="settings-capacity-ring" role="img" aria-label={percentage == null ? '容量未上报' : `已使用 ${percentage.toFixed(1)}%`} style={{ background: percentage == null ? 'var(--border)' : `conic-gradient(var(--accent) ${percentage}%, var(--border) 0)` }}><div><strong>{percentage == null ? '—' : `${percentage.toFixed(1)}%`}</strong><span>已使用</span></div></div><div>{capacity}</div><div className="settings-storage-status"><span>存储就绪状态</span><Badge>{!health ? '未获取' : ready ? '已就绪' : '需要关注'}</Badge><span>扫描状态：{scanState}</span><span>最后成功扫描</span><strong>{scanner?.last_completed_at ? new Date(scanner.last_completed_at * 1000).toLocaleString() : '暂无记录'}</strong></div></div></Section>
    <Section icon={Database} title="存储配置" description="当前生效的存储与清理参数"><FieldGroup className="settings-field-pair"><ReadField id="storage-backend" label="存储后端" value="本地文件系统" /><ReadField id="storage-buffer" label="流式缓冲区" value={settings ? bytes(settings.stream_buffer_size) : '—'} /><ReadField id="scan-interval" label="生命周期扫描间隔" value={settings ? `${settings.lifecycle_scan_interval_seconds} 秒` : '—'} /><ReadField id="upload-expiry" label="未完成上传保留期" value={settings ? `${settings.multipart_expiry_seconds} 秒` : '—'} /></FieldGroup></Section>
    <Section icon={HardDrive} title="磁盘管理" description="当前接口仅提供实例文件系统容量，不提供逐盘清单"><Table><TableHeader><TableRow><TableHead>存储范围</TableHead><TableHead>总容量</TableHead><TableHead>已用空间</TableHead><TableHead>可用空间</TableHead><TableHead>状态</TableHead></TableRow></TableHeader><TableBody><TableRow><TableCell>实例文件系统</TableCell><TableCell>{bytes(storage?.total)}</TableCell><TableCell>{bytes(storage?.physical_used)}</TableCell><TableCell>{bytes(storage?.available)}</TableCell><TableCell>{storage ? '容量已读取' : '未获取'}</TableCell></TableRow></TableBody></Table><Note>当前为单节点存储；不提供磁盘添加、移除或多磁盘均衡操作。容量包含同一文件系统上的其他数据。</Note></Section>
  </div>

  if (category === 'about') return <div className="settings-detail-stack">
    <div className="settings-about-brand"><img src="/zigfs-logo.svg" alt="ZigFS" /><div><h3>ZigFS</h3><p>轻量级 S3 兼容对象存储服务</p><div><Badge>{system?.version ?? '版本未获取'}</Badge><Badge>S3 兼容</Badge><Badge>Apache 2.0</Badge></div></div></div>
    <div className="settings-about-grid">
      <Section icon={Info} title="版本信息"><dl className="settings-facts">{[['版本号', system?.version ?? '未获取'], ['构建时间', '未上报'], ['Git Commit', '未上报'], ['Zig 版本', '未上报'], ['操作系统', '未上报'], ['编译方式', '未上报']].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl></Section>
      <Section icon={Monitor} title="系统信息"><dl className="settings-facts"><div><dt>运行时长</dt><dd>{system ? `${Math.floor(system.uptime / 86400)} 天 ${Math.floor(system.uptime % 86400 / 3600)} 小时 ${Math.floor(system.uptime % 3600 / 60)} 分钟` : '未获取'}</dd></div><div><dt>内存使用</dt><dd>未上报</dd></div><div><dt>CPU 使用</dt><dd>未上报</dd></div></dl>{capacity}</Section>
      <Section icon={Scale} title="许可证"><p>ZigFS 基于 Apache License 2.0 发布。</p><p>完整条款见项目仓库中的 LICENSE 文件。</p><Badge>Apache License 2.0</Badge></Section>
      <Section icon={Link} title="相关链接"><dl className="settings-facts"><div><dt>项目仓库</dt><dd><a href="https://git.molast.com/chen/zigfs" target="_blank" rel="noreferrer">查看项目仓库 ↗</a></dd></div><div><dt>文档</dt><dd>仓库 README 与 docs/</dd></div><div><dt>版本更新</dt><dd>当前未提供更新检查接口</dd></div></dl></Section>
    </div><Note>ZigFS 致力于提供简单、可靠的对象存储服务，感谢所有用户的支持与贡献。</Note>
  </div>
  return null
}
