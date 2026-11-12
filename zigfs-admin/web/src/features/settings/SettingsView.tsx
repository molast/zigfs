import { DisplaySettingsPanel } from './DisplaySettingsPanel'
import { formatTime } from '@/lib/dateTime'
import { AuthenticationSettingsPanel } from './AuthenticationSettingsPanel'
import { RegionSettingsPanel } from './RegionSettingsPanel'
import { InstanceSettingsPanel } from './InstanceSettingsPanel'
import { t } from '@/locales'
import { FileText, Globe, Home, Info, RefreshCw, Settings as SettingsIcon, ShieldCheck, CircleCheck, Box } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { ApiClient, KmsStatus } from '../../api/client'
import { useErrorToast } from '../../components/ToastProvider'
import { Badge } from '../../components/ui/Badge'
import { Button } from '../../components/ui/Button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { LogConfigurationPanel } from './LogConfigurationPanel'
import { SettingsPanels } from './SettingsPanels'
import { KmsSettingsPanel, createKmsDraft } from './KmsSettingsPanel'
import type { ManagementHealth, StorageInfo, Settings, SystemInfo } from '../../types/api'

const categories = [
  { id: 'general', get label() { return t('settings.general') }, get subtitle() { return t('settings.instanceDetails') }, get description() { return t('settings.viewInstanceDetailsAndRuntimeSettings') }, icon: Home },
  { id: 'network', get label() { return t('settings.network') }, get subtitle() { return t('settings.networkAndAccess') }, get description() { return t('settings.viewApiListenAddressesPublicEndpointsAndS3Addressing') }, icon: Globe },
  { id: 'security', get label() { return t('settings.security') }, get subtitle() { return t('settings.securityConfiguration') }, get description() { return t('settings.viewAdminSessionAndRequestSignatureSettings') }, icon: ShieldCheck },
  { id: 'logs', get label() { return t('settings.logs') }, get subtitle() { return t('settings.logsAndObservability') }, get description() { return t('settings.logSettingsDescription') }, icon: FileText },
  { id: 'about', get label() { return t('settings.aboutZigfs') }, get subtitle() { return t('settings.versionAndInformation') }, get description() { return t('settings.viewTheServiceVersionAndInstanceRuntimeInformation') }, icon: Info },
] as const

type Category = typeof categories[number]['id']

export function SettingsView({ api }: { api: ApiClient }) {
  const [category, setCategory] = useState<Category>('general')
  const [kmsDraft, setKmsDraft] = useState(createKmsDraft)
  const [kmsStatus, setKmsStatus] = useState<KmsStatus | null>(null)
  const [settings, setSettings] = useState<Settings | null>(null)
  const [system, setSystem] = useState<SystemInfo | null>(null)
  const [storage, setStorage] = useState<StorageInfo | null>(null)
  const [health, setHealth] = useState<ManagementHealth | null>(null)
  const [observedAt, setObservedAt] = useState<Date | null>(null)
  const [busy, setBusy] = useState(false)
  const mounted = useRef(false)
  const pending = useRef(false)
  const notifyError = useErrorToast()

  useEffect(() => {
    let active = true
    api.kmsSettings().then(status => { if (active) { setKmsStatus(status); setKmsDraft(status.configured ? status.config : createKmsDraft()) } }).catch(error => { if (active) notifyError(error instanceof Error ? error.message : t('settings.kmsRequestFailed')) })
    return () => { active = false }
  }, [api, notifyError])

  const refresh = useCallback(async () => {
    if (pending.current) return
    pending.current = true
    setBusy(true)
    try {
      const results = await Promise.allSettled([api.settings(), api.system(), api.storage(), api.managementHealth()])
      const [configuration, runtime, capacity, readiness] = results
      if (!mounted.current) return
      setSettings(configuration.status === 'fulfilled' ? configuration.value : null)
      setSystem(runtime.status === 'fulfilled' ? runtime.value : null)
      setStorage(capacity.status === 'fulfilled' ? capacity.value : null)
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

  return <section className="system-settings-page" aria-busy={busy}>
    <header className="system-settings-heading"><SettingsIcon aria-hidden="true" /><div><h2>{t('settings.systemSettings')}</h2><p>{t('settings.viewGlobalSettingsForThisZigfsInstance')}</p></div></header>
    <Tabs value={category} onValueChange={value => setCategory(value as Category)} orientation="vertical" className="system-settings-layout">
      <Card className="system-settings-navigation"><TabsList aria-label={t('settings.systemSettingsCategories')} className="system-settings-nav">
        {categories.map(item => <TabsTrigger key={item.id} value={item.id}><item.icon aria-hidden="true" /><span><strong>{item.label}</strong><small>{item.subtitle}</small></span></TabsTrigger>)}
      </TabsList></Card>
      <div className="system-settings-main">
        <Card className="system-settings-editor">
          {categories.map(item => <TabsContent key={item.id} value={item.id} data-settings-category={item.id} className="system-settings-tab">
            <CardHeader><div className="system-settings-section-heading"><item.icon aria-hidden="true" /><div><CardTitle>{item.label}</CardTitle><CardDescription>{item.description}</CardDescription></div>{item.id !== 'security' && item.id !== 'logs' && item.id !== 'network' && item.id !== 'general' && <Badge>{busy ? t('settings.loading') : settings ? t('settings.effectiveReadOnly') : t('settings.configurationUnavailable')}</Badge>}</div></CardHeader>
            <CardContent className="system-settings-scroll"><div className="settings-detail-stack">{item.id === 'security' ? <KmsSettingsPanel api={api} status={kmsStatus} setStatus={setKmsStatus} draft={kmsDraft} setDraft={setKmsDraft} /> : item.id === 'logs' ? <LogSettingsTabs api={api} /> : item.id === 'general' ? <><InstanceSettingsPanel api={api} observedAt={observedAt} /><RegionSettingsPanel api={api} observedAt={observedAt} /><AuthenticationSettingsPanel api={api} observedAt={observedAt} /><DisplaySettingsPanel api={api} observedAt={observedAt} /></> : <SettingsPanels api={api} onSaved={refresh} category={item.id} settings={settings} system={system} storage={storage} scanner={null} health={health} />}</div></CardContent>
          </TabsContent>)}
          {category !== 'security' && category !== 'logs' && category !== 'network' && <footer className="system-settings-actions"><span>{t(category === 'general' ? 'settings.instanceOtherSettingsReadOnly' : 'settings.configurationIsReadOnlyRestartZigfsAfterChangingService')}</span><Button size="sm" variant="outline" disabled={busy} onClick={() => void refresh()}><RefreshCw data-icon="inline-start" />{busy ? t('settings.loadingProgress') : t('settings.refreshConfiguration')}</Button></footer>}
        </Card>
        {category !== 'security' && category !== 'logs' && category !== 'network' && <div className="system-settings-notes">
          <Card><CardHeader><CircleCheck aria-hidden="true" /><div><CardTitle>{t('settings.currentConfiguration')}</CardTitle><CardDescription>{t('settings.showsEffectiveRuntimeValues')}</CardDescription></div></CardHeader></Card>
          {category !== 'general' && <Card><CardHeader><Info aria-hidden="true" /><div><CardTitle>{t('settings.restartRequired')}</CardTitle><CardDescription>{t('settings.restartTheServiceToApplyConfigurationChanges')}</CardDescription></div></CardHeader></Card>}
          <Card><CardHeader><Box aria-hidden="true" /><div><CardTitle>{t('settings.instanceInformation')}</CardTitle><CardDescription>{t('settings.versionLabel')}{system?.version ?? '—'} {t('settings.lastFetched')}{formatTime(observedAt)}</CardDescription></div></CardHeader></Card>
        </div>}
      </div>
    </Tabs>
  </section>
}

function LogSettingsTabs({ api }: { api: ApiClient }) {
  return <Tabs defaultValue="system" className="settings-log-tabs">
    <TabsList aria-label={t('settings.logs')}>
      <TabsTrigger value="system">{t('navigation.systemLogs')}</TabsTrigger>
      <TabsTrigger value="audit">{t('settings.auditLogs')}</TabsTrigger>
    </TabsList>
    <TabsContent value="system"><LogConfigurationPanel api={api} kind="system" /></TabsContent>
    <TabsContent value="audit"><LogConfigurationPanel api={api} kind="audit" /></TabsContent>
  </Tabs>
}
