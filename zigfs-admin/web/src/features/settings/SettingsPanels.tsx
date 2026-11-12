import { formatDateTime } from '@/lib/dateTime'
import { NetworkListeners } from './NetworkListeners'
import { NetworkPublicAccess } from './NetworkPublicAccess'
import type { ApiClient } from '../../api/client'
import { t, getFormatLocale } from '@/locales'
import { Database, Globe, HardDrive, Info, Link, Monitor, Scale, ShieldCheck } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'
import { Badge } from '../../components/ui/Badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Input } from '../../components/ui/Input'
import { Alert, AlertDescription } from '../../components/ui/alert'
import { Progress } from '../../components/ui/progress'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import type { ManagementHealth, Settings, StorageInfo, StorageScannerStatus, SystemInfo } from '../../types/api'

export interface SettingsPanelProps {
  api: ApiClient
  onSaved: () => Promise<void>
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

function ReadField({ id, label, value = t('settings.notReported'), help }: { id: string; label: string; value?: string; help?: string }) {
  return <Field className="settings-detail-field"><FieldLabel htmlFor={`setting-detail-${id}`}>{label}</FieldLabel><div><Input id={`setting-detail-${id}`} value={value} readOnly aria-describedby={help ? `setting-help-${id}` : undefined} />{help && <FieldDescription id={`setting-help-${id}`}>{help}</FieldDescription>}</div></Field>
}

function Note({ children }: { children: ReactNode }) {
  return <Alert role="note" className="settings-detail-note"><Info aria-hidden="true" /><AlertDescription>{children}</AlertDescription></Alert>
}

function bytes(value: number | null | undefined) {
  if (value == null) return t('settings.notReported')
  if (value === 0) return '0 B'
  const index = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)))
  return `${(value / 1024 ** index).toLocaleString(getFormatLocale(), { maximumFractionDigits: 2 })} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][index]}`
}


export function SettingsPanels({ api, onSaved, category, settings, system, storage, scanner, health }: SettingsPanelProps) {
  const percentage = storage?.physical_used != null && storage.total != null && storage.total > 0 ? Math.min(100, Math.max(0, storage.physical_used / storage.total * 100)) : null
  const ready = health?.status === 'ready' && health.recovery === 'ready'
  const scanState = !scanner ? t('settings.unavailable') : scanner.running ? t('settings.scanning') : scanner.last_attempt_succeeded === false ? t('settings.lastScanFailed') : scanner.last_scan ? t('settings.scanCompleted') : t('settings.notScannedYet')
  const capacity = <><dl className="settings-facts"><div><dt>{t('settings.usedSpace')}</dt><dd>{bytes(storage?.physical_used)}</dd></div><div><dt>{t('settings.availableSpace')}</dt><dd>{bytes(storage?.available)}</dd></div><div><dt>{t('settings.totalCapacity')}</dt><dd>{bytes(storage?.total)}</dd></div></dl>{percentage != null && <Progress value={percentage} aria-label={t('settings.diskUsageValue', { '0': percentage.toFixed(1) })} />}</>

  if (category === 'network') return <div className="settings-detail-stack">
    <NetworkListeners api={api} settings={settings} onSaved={onSaved} />
    <NetworkPublicAccess api={api} settings={settings} onSaved={onSaved} />
  </div>

  if (category === 'storage') return <div className="settings-detail-stack">
    <Section icon={Database} title={t('settings.storageOverview')} description={t('settings.actualCapacityOfTheInstanceFilesystem')}><div className="settings-storage-overview"><div className="settings-capacity-ring" role="img" aria-label={percentage == null ? t('settings.capacityNotReported') : t('settings.valueUsed', { '0': percentage.toFixed(1) })} style={{ background: percentage == null ? 'var(--border)' : `conic-gradient(var(--accent) ${percentage}%, var(--border) 0)` }}><div><strong>{percentage == null ? '—' : `${percentage.toFixed(1)}%`}</strong><span>{t('settings.used')}</span></div></div><div>{capacity}</div><div className="settings-storage-status"><span>{t('settings.storageReadiness')}</span><Badge>{!health ? t('settings.unavailable') : ready ? t('settings.ready') : t('settings.needsAttention')}</Badge><span>{t('settings.scanStatus')}{scanState}</span><span>{t('settings.lastSuccessfulScan')}</span><strong>{scanner?.last_completed_at ? formatDateTime(scanner.last_completed_at * 1000) : t('settings.noRecordsYet')}</strong></div></div></Section>
    <Section icon={Database} title={t('settings.storageConfiguration')} description={t('settings.effectiveStorageAndCleanupSettings')}><FieldGroup className="settings-field-pair"><ReadField id="storage-backend" label={t('settings.storageBackend')} value={t('common.localFilesystem')} /><ReadField id="storage-buffer" label={t('settings.streamBuffer')} value={settings ? bytes(settings.stream_buffer_size) : '—'} /><ReadField id="scan-interval" label={t('settings.lifecycleScanInterval')} value={settings ? t('common.seconds', { '0': settings.lifecycle_scan_interval_seconds }) : '—'} /><ReadField id="upload-expiry" label={t('settings.incompleteUploadRetention')} value={settings ? t('common.seconds', { '0': settings.multipart_expiry_seconds }) : '—'} /></FieldGroup></Section>
    <Section icon={HardDrive} title={t('settings.diskManagement')} description={t('settings.theApiReportsFilesystemCapacityNotIndividualDisks')}><Table><TableHeader><TableRow><TableHead>{t('settings.storageScope')}</TableHead><TableHead>{t('settings.totalCapacity')}</TableHead><TableHead>{t('settings.usedSpace')}</TableHead><TableHead>{t('settings.availableSpace')}</TableHead><TableHead>{t('settings.status')}</TableHead></TableRow></TableHeader><TableBody><TableRow><TableCell>{t('settings.instanceFilesystem')}</TableCell><TableCell>{bytes(storage?.total)}</TableCell><TableCell>{bytes(storage?.physical_used)}</TableCell><TableCell>{bytes(storage?.available)}</TableCell><TableCell>{storage ? t('settings.capacityReported') : t('settings.unavailable')}</TableCell></TableRow></TableBody></Table><Note>{t('settings.singleNodeStorageDoesNotProvideDiskAdditionRemoval')}</Note></Section>
  </div>

  if (category === 'about') return <div className="settings-detail-stack">
    <div className="settings-about-brand"><img src="/zigfs-logo.svg" alt="ZigFS" /><div><h3>ZigFS</h3><p>{t('settings.lightweightS3CompatibleObjectStorage')}</p><div><Badge>{system?.version ?? t('settings.versionUnavailable')}</Badge><Badge>{t('settings.s3Compatible')}</Badge><Badge>Apache 2.0</Badge></div></div></div>
    <div className="settings-about-grid">
      <Section icon={Info} title={t('settings.versionInformation')}><dl className="settings-facts">{[[t('settings.version'), system?.version ?? t('settings.unavailable')], [t('settings.buildDate'), t('settings.notReported')], [t('common.gitCommit'), t('settings.notReported')], [t('settings.zigVersion'), t('settings.notReported')], [t('settings.operatingSystem'), t('settings.notReported')], [t('settings.buildMode'), t('settings.notReported')]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl></Section>
      <Section icon={Monitor} title={t('settings.systemInformation')}><dl className="settings-facts"><div><dt>{t('settings.uptime')}</dt><dd>{system ? t('settings.valueDaysValueHoursValueMinutes', { '0': Math.floor(system.uptime / 86400), '1': Math.floor(system.uptime % 86400 / 3600), '2': Math.floor(system.uptime % 3600 / 60) }) : t('settings.unavailable')}</dd></div><div><dt>{t('settings.memoryUsage')}</dt><dd>{t('settings.notReported')}</dd></div><div><dt>{t('settings.cpuUsage')}</dt><dd>{t('settings.notReported')}</dd></div></dl>{capacity}</Section>
      <Section icon={Scale} title={t('settings.license')}><p>{t('settings.zigfsIsReleasedUnderTheApacheLicense20')}</p><p>{t('settings.seeTheLicenseFileInTheProjectRepositoryFor')}</p><Badge>Apache License 2.0</Badge></Section>
      <Section icon={Link} title={t('settings.relatedLinks')}><dl className="settings-facts"><div><dt>{t('settings.projectRepository')}</dt><dd><a href="https://git.molast.com/chen/zigfs" target="_blank" rel="noreferrer">{t('settings.viewRepository')}</a></dd></div><div><dt>{t('settings.documentation')}</dt><dd>{t('settings.repositoryReadmeAndDocs')}</dd></div><div><dt>{t('settings.updates')}</dt><dd>{t('settings.updateCheckingIsNotAvailable')}</dd></div></dl></Section>
    </div><Note>{t('settings.zigfsProvidesSimpleReliableObjectStorageThankYouFor')}</Note>
  </div>
  return null
}
