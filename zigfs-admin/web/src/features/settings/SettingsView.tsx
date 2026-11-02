import { t, getFormatLocale } from '@/locales'
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
  { id: 'general', get label() { return t('settings.general') }, get subtitle() { return t('settings.instanceDetails') }, get description() { return t('settings.viewInstanceDetailsAndRuntimeSettings') }, icon: Home },
  { id: 'network', get label() { return t('settings.network') }, get subtitle() { return t('settings.networkAndAccess') }, get description() { return t('settings.viewApiListenAddressesPublicEndpointsAndS3Addressing') }, icon: Globe },
  { id: 'security', get label() { return t('settings.security') }, get subtitle() { return t('settings.securityConfiguration') }, get description() { return t('settings.viewAdminSessionAndRequestSignatureSettings') }, icon: ShieldCheck },
  { id: 'storage', get label() { return t('settings.storage') }, get subtitle() { return t('settings.storagePoliciesAndSettings') }, get description() { return t('settings.viewStorageBuffersMultipartUploadRetentionAndLifecycleScan') }, icon: Database },
  { id: 'logs', get label() { return t('settings.logs') }, get subtitle() { return t('settings.logsAndObservability') }, get description() { return t('settings.viewMetricsConfigurationAndAvailableLogSettings') }, icon: FileText },
  { id: 'about', get label() { return t('settings.aboutZigfs') }, get subtitle() { return t('settings.versionAndInformation') }, get description() { return t('settings.viewTheServiceVersionAndInstanceRuntimeInformation') }, icon: Info },
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
      if (results.some(result => result.status === 'rejected')) notifyError(t('settings.someSystemInformationCouldNotBeLoadedRefreshConfiguration'))
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

  const startup = system && observedAt ? new Date(observedAt.getTime() - system.uptime * 1000).toLocaleString(getFormatLocale()) : '—'
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const groups: Partial<Record<Category, SettingGroup[]>> = {
    general: [
      { title: t('settings.instanceInformation'), items: [
        { id: 'service', label: t('settings.serviceName'), value: 'ZigFS', help: t('settings.currentObjectStorageService') },
        { id: 'description', label: t('settings.instanceDescription'), value: t('settings.notReported'), multiline: true, help: t('settings.theServiceDoesNotReportACustomInstanceDescription') },
        { id: 'instance-id', label: t('settings.instanceId'), value: t('settings.notReported'), help: t('settings.theServiceDoesNotReportASeparateInstanceId') },
        { id: 'startup', label: t('settings.startedAt'), value: startup, help: t('settings.estimatedFromReportedUptimeDisplayedInYourLocalTimezone') },
        { id: 'uptime', label: t('settings.uptime'), value: system ? duration(system.uptime) : '—', help: t('settings.asOfTheLastRefresh') },
      ] },
      { title: t('settings.basicConfiguration'), items: [
        { id: 'region', label: t('settings.defaultRegion'), value: settings?.s3_region ?? '—', help: t('settings.s3ServiceAndSignatureVerificationRegion') },
        { id: 'timezone', label: t('settings.displayTimezone'), value: timezone, help: t('settings.yourBrowserTimezoneServerTimestampsUseUtc') },
        { id: 'date-format', label: t('settings.dateAndTimeFormat'), value: t('settings.followsTheSelectedLanguage'), help: t('settings.datesAndTimesUseTheSelectedLanguageAndLocal') },
      ] },
    ],
    security: [
      { title: t('settings.sessionSecurity'), items: [
        { id: 'session-ttl', label: t('settings.adminSessionLifetime'), value: settings ? duration(settings.admin_session_ttl_seconds) : '—', help: t('settings.maximumConsoleSessionLifetime') },
      ] },
      { title: t('settings.requestValidation'), items: [
        { id: 'clock-skew', label: t('settings.signatureClockSkew'), value: settings ? duration(settings.request_time_skew_seconds) : '—', help: t('settings.allowedClockDifferenceBetweenClientAndServerForS3') },
      ] },
    ],

  }

  return <section className="system-settings-page" aria-busy={busy}>
    <header className="system-settings-heading"><SettingsIcon aria-hidden="true" /><div><h2>{t('settings.systemSettings')}</h2><p>{t('settings.viewGlobalSettingsForThisZigfsInstance')}</p></div></header>
    <Tabs value={category} onValueChange={value => setCategory(value as Category)} orientation="vertical" className="system-settings-layout">
      <Card className="system-settings-navigation"><TabsList aria-label={t('settings.systemSettingsCategories')} className="system-settings-nav">
        {categories.map(item => <TabsTrigger key={item.id} value={item.id}><item.icon aria-hidden="true" /><span><strong>{item.label}</strong><small>{item.subtitle}</small></span></TabsTrigger>)}
      </TabsList></Card>
      <div className="system-settings-main">
        <Card className="system-settings-editor">
          {categories.map(item => <TabsContent key={item.id} value={item.id} className="system-settings-tab">
            <CardHeader><div className="system-settings-section-heading"><item.icon aria-hidden="true" /><div><CardTitle>{item.label}</CardTitle><CardDescription>{item.description}</CardDescription></div><Badge>{busy ? t('settings.loading') : settings ? t('settings.effectiveReadOnly') : t('settings.configurationUnavailable')}</Badge></div></CardHeader>
            <CardContent className="system-settings-scroll">{groups[item.id] ? <Card className="system-settings-form"><CardContent>
              {groups[item.id]?.map((group, index) => <div key={group.title}>{index > 0 && <Separator />}<FieldSet><FieldLegend>{group.title}</FieldLegend><FieldGroup>
                {group.items.map(setting => <Field key={setting.id} className="system-settings-field"><FieldLabel htmlFor={`system-${setting.id}`}>{setting.label}</FieldLabel>{setting.multiline ? <Textarea id={`system-${setting.id}`} readOnly value={setting.value} rows={2} aria-describedby={setting.help ? `system-${setting.id}-help` : undefined} /> : <Input id={`system-${setting.id}`} readOnly value={setting.value} aria-describedby={setting.help ? `system-${setting.id}-help` : undefined} />}{setting.help && <FieldDescription id={`system-${setting.id}-help`}>{setting.help}</FieldDescription>}</Field>)}
              </FieldGroup></FieldSet></div>)}
            </CardContent></Card> : <SettingsPanels category={item.id} settings={settings} system={system} storage={storage} scanner={scanner} health={health} />}</CardContent>
          </TabsContent>)}
          <footer className="system-settings-actions"><span>{t('settings.configurationIsReadOnlyRestartZigfsAfterChangingService')}</span><Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{busy ? t('settings.loadingProgress') : t('settings.refreshConfiguration')}</Button></footer>
        </Card>
        <div className="system-settings-notes">
          <Card><CardHeader><CircleCheck aria-hidden="true" /><div><CardTitle>{t('settings.currentConfiguration')}</CardTitle><CardDescription>{t('settings.showsEffectiveRuntimeValues')}</CardDescription></div></CardHeader></Card>
          <Card><CardHeader><Info aria-hidden="true" /><div><CardTitle>{t('settings.restartRequired')}</CardTitle><CardDescription>{t('settings.restartTheServiceToApplyConfigurationChanges')}</CardDescription></div></CardHeader></Card>
          <Card><CardHeader><Box aria-hidden="true" /><div><CardTitle>{t('settings.instanceInformation')}</CardTitle><CardDescription>{t('settings.versionLabel')}{system?.version ?? '—'} {t('settings.lastFetched')}{observedAt?.toLocaleTimeString(getFormatLocale()) ?? '—'}</CardDescription></div></CardHeader></Card>
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
  return [days && t('settings.valueDays', { '0': days }), hours && t('settings.valueHours', { '0': hours }), minutes && t('settings.valueMinutes', { '0': minutes }), rest && t('settings.valueSeconds', { '0': rest })].filter(Boolean).join(' ') || t('settings.zeroSeconds')
}
