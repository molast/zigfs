import { AccountView } from './features/account/AccountView'
import { useDisplayPreferences, setDisplayPreferences, defaultDisplayPreferences } from './lib/dateTime'
import { Breadcrumb, BreadcrumbList, BreadcrumbItem, BreadcrumbLink, BreadcrumbPage, BreadcrumbSeparator } from './components/ui/breadcrumb'
import { Tooltip, TooltipContent, TooltipTrigger } from './components/ui/tooltip'
import { ThemeSwitcher } from './components/ThemeSwitcher'
import { LanguageSwitcher } from './components/LanguageSwitcher'
import { t, useLocale } from '@/locales'
import { useEffect, useMemo, useState } from 'react'
import {
  ChartNoAxesCombined,
  RadioTower,
  ChevronDown,
  FolderOpen,
  ScrollText,
  Terminal,
  Fingerprint,
  HardDrive,
  KeyRound,
  LogOut,
  Menu,
  PanelLeftClose,
  PanelLeftOpen,
  ShieldCheck,
  UserRoundCog,
  Settings,
  ContactRound,
  UsersRound,
  UserRound,
  X,
  type LucideIcon,
} from 'lucide-react'
import { ApiError, createApiClient } from './api/client'
import { useErrorToast } from './components/ToastProvider'
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuGroup, DropdownMenuItem } from './components/ui/dropdown-menu'
import { Button } from './components/ui/Button'
import { useLoading } from './components/LoadingProvider'
import { AccessKeysView } from './features/access-keys/AccessKeysView'
import { RolesView } from './features/roles/RolesView'
import { IdentitiesView } from './features/identities/IdentitiesView'
import { OIDCSettingsView } from './features/settings/OIDCSettingsView'
import { EventDestinationsView } from './features/events/EventDestinationsView'
import { PoliciesView } from './features/policies/PoliciesView'
import { LoginView } from './features/auth/LoginView'
import { BucketDetailView } from './features/buckets/BucketDetailView'
import { BucketsView } from './features/buckets/BucketsView'
import { ObjectsView } from './features/objects/ObjectsView'
import { SettingsView } from './features/settings/SettingsView'
import { SystemLogsView } from './features/logs/SystemLogsView'
import { LogsView } from './features/logs/LogsView'
import { StorageView } from './features/storage/StorageView'
import { SystemView } from './features/system/SystemView'
import { appRoutePath, createAppRoute, parseAppRoute, type AppRoute, type View } from './routes'
import type { AdminSession } from './types/api'

type Availability = 'checking' | 'ready' | 'offline' | 'not-ready'

const THEME_STORAGE_KEY = 'zigfs-admin-theme'

function readDarkTheme(): boolean {
  try {
    return window.localStorage.getItem(THEME_STORAGE_KEY) === 'dark'
  } catch {
    return false
  }
}

interface NavItem {
  view: View
  label: string
  icon: LucideIcon
}

const navigation: Array<{ label: string; items: NavItem[] }> = [
  { get label() { return t('navigation.objectStorage') }, items: [{ view: 'buckets', get label() { return t('navigation.objectBrowser') }, icon: FolderOpen }] },
  { get label() { return t('navigation.accessControl') }, items: [
    { view: 'users', get label() { return t('navigation.users') }, icon: ContactRound },
    { view: 'user-groups', get label() { return t('navigation.userGroups') }, icon: UsersRound },
    { view: 'access-keys', get label() { return t('navigation.accessKeys') }, icon: KeyRound },
    { view: 'roles', get label() { return t('roles.roles') }, icon: UserRoundCog },
    { view: 'policies', get label() { return t('navigation.policies') }, icon: ShieldCheck },
  ] },
  {
    get label() { return t('navigation.serviceStatus') },
    items: [
      { view: 'storage', get label() { return t('navigation.storage') }, icon: HardDrive },
      { view: 'logs', get label() { return t('navigation.logs') }, icon: ScrollText },
      { view: 'system-logs', get label() { return t('navigation.systemLogs') }, icon: Terminal },
      { view: 'system', get label() { return t('navigation.monitoring') }, icon: ChartNoAxesCombined },
    ],
  },
  { get label() { return t('navigation.configuration') }, items: [
    { view: 'event-destinations', get label() { return t('eventDestinations.title') }, icon: RadioTower },
    { view: 'oidc-settings', label: 'OpenID', icon: Fingerprint },
    // Keep System Setting as the final item in the navigation list.
    { view: 'settings', get label() { return t('navigation.systemSetting') }, icon: Settings },
  ] },
]

const viewMeta: Record<View, { section: string; label: string }> = {
  profile: { get section() { return t('account.account') }, get label() { return t('account.profile') } },
  'account-security': { get section() { return t('account.account') }, get label() { return t('account.security') } },
  buckets: { get section() { return t('navigation.objectStorage') }, get label() { return t('navigation.objectBrowser') } },
  'bucket-detail': { get section() { return t('common.buckets') }, get label() { return t('navigation.summary') } },
  objects: { get section() { return t('common.buckets') }, get label() { return t('navigation.objects') } },
  users: { get section() { return t('common.accessControl') }, get label() { return t('navigation.users') } },
  'user-groups': { get section() { return t('common.accessControl') }, get label() { return t('navigation.userGroups') } },
  'access-keys': { get section() { return t('common.accessControl') }, get label() { return t('navigation.accessKeys') } },
  roles: { get section() { return t('common.accessControl') }, get label() { return t('roles.roles') } },
  policies: { get section() { return t('common.accessControl') }, get label() { return t('navigation.policies') } },
  storage: { get section() { return t('common.system') }, get label() { return t('navigation.storage') } },
  'system-logs': { get section() { return t('common.system') }, get label() { return t('navigation.systemLogs') } },
  logs: { get section() { return t('common.system') }, get label() { return t('navigation.logs') } },
  system: { get section() { return t('common.monitoring') }, get label() { return t('navigation.runningStatus') } },
  settings: { get section() { return t('common.configuration') }, get label() { return t('navigation.systemSetting') } },
  'event-destinations': { get section() { return t('common.configuration') }, get label() { return t('eventDestinations.title') } },
  'oidc-settings': { get section() { return t('common.configuration') }, label: 'OpenID' },
}

export default function App() {
  useLocale()
  useDisplayPreferences()
  const { withLoading } = useLoading()
  const notifyError = useErrorToast()
  const [session, setSession] = useState<AdminSession | null>()
  const [route, setRoute] = useState<AppRoute>(() => parseAppRoute(window.location.pathname, window.location.search))
  const [availability, setAvailability] = useState<Availability>('checking')
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false)
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false)
  const [darkTheme, setDarkTheme] = useState(readDarkTheme)
  const api = useMemo(() => createApiClient(), [])
  useEffect(() => {
    if (!session) { setDisplayPreferences(defaultDisplayPreferences); return }
    if (session.display_preferences) setDisplayPreferences(session.display_preferences)
    else if (session.display_preferences === null) {
      setDisplayPreferences(defaultDisplayPreferences)
      notifyError(t('settings.displayLoadFailed'))
    }
  }, [session, notifyError])


  useEffect(() => {
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, darkTheme ? 'dark' : 'light')
    } catch {
      // Storage may be unavailable in private or restricted browser contexts.
    }
    document.documentElement.dataset.theme = darkTheme ? 'dark' : 'light'
  }, [darkTheme])

  async function bootstrap() {
    await withLoading(t('navigation.connectingToZigfs'), async () => {
      setAvailability('checking')
      try {
        await api.ready()
        setAvailability('ready')
        try {
          setSession(await api.session())
        } catch (reason) {
          if (reason instanceof ApiError && reason.status === 401) {
            try { setSession(await api.refreshOIDC()) } catch { setSession(null) }
          }
          else if (reason instanceof ApiError && reason.body.code === 'ConsoleAccessDenied') setSession(null)
          else throw reason
        }
      } catch (reason) {
        setSession(undefined)
        setAvailability(reason instanceof ApiError && reason.body.code === 'StorageNotReady' ? 'not-ready' : 'offline')
      }
    })
  }

  useEffect(() => {
    void bootstrap()
  }, [api])

  useEffect(() => {
    let renewing = false
    let active = true
    const expire = async () => {
      if (!session?.federated) { setSession(null); return }
      if (renewing) return
      renewing = true
      try {
        const next = await api.refreshOIDC()
        if (active) setSession(next)
      } catch { if (active) setSession(null) }
      finally { renewing = false }
    }
    window.addEventListener('zigfs:session-expired', expire)
    return () => { active = false; window.removeEventListener('zigfs:session-expired', expire) }
  }, [api, session?.federated])

  useEffect(() => {
    const invalidate = () => {
      // Feature views own their server state; this event tells them to drop
      // cached capability/permission data after any mutating API call.
      window.dispatchEvent(new CustomEvent('zigfs:capabilities-invalidated'))
    }
    window.addEventListener('zigfs:permissions-changed', invalidate)
    return () => window.removeEventListener('zigfs:permissions-changed', invalidate)
  }, [])

  useEffect(() => {
    const syncRoute = () => setRoute(parseAppRoute(window.location.pathname, window.location.search))
    window.addEventListener('popstate', syncRoute)
    return () => window.removeEventListener('popstate', syncRoute)
  }, [])

  useEffect(() => {
    if (!session || session.federated) return
    let active = true
    let pending = false
    const refreshPermissions = async () => {
      if (pending || document.hidden) return
      pending = true
      try {
        const next = await api.session()
        if (active) setSession(next)
      } catch (error) {
        if (active && error instanceof ApiError && (error.status === 401 || error.body.code === 'ConsoleAccessDenied')) setSession(null)
      } finally { pending = false }
    }
    const timer = window.setInterval(() => void refreshPermissions(), 30_000)
    const onFocus = () => void refreshPermissions()
    window.addEventListener('focus', onFocus)
    return () => { active = false; window.clearInterval(timer); window.removeEventListener('focus', onFocus) }
  }, [api, session?.subject_id, session?.federated])

  useEffect(() => {
    if (!session?.federated || !session.refreshable) return
    let active = true
    let pending = false
    const renew = async () => {
      if (pending) return
      pending = true
      try {
        const next = await api.refreshOIDC()
        if (active) setSession(next)
      } catch (error) {
        if (active) {
          notifyError(error instanceof Error ? error.message : t('navigation.operationFailedPleaseTryAgain'))
          if (error instanceof ApiError && (error.status === 401 || error.body.code === 'ConsoleAccessDenied')) setSession(null)
        }
      } finally { pending = false }
    }
    const timer = window.setInterval(() => void renew(), 30_000)
    const onFocus = () => void renew()
    window.addEventListener('focus', onFocus)
    return () => { active = false; window.clearInterval(timer); window.removeEventListener('focus', onFocus) }
  }, [api, session?.federated, session?.refreshable, notifyError])

  useEffect(() => {
    if (!session) return
    const capabilities = session.capabilities ?? { admin: false, kms: false, s3: false, sts: false }
    const canAdmin = session.is_root || capabilities.admin
    const canKms = session.is_root || capabilities.kms
    const canS3 = session.is_root || !!capabilities.s3_console
    const allowed = (view: View) => view === 'system' ? session.is_root || !!capabilities.server_info
      : view === 'system-logs' ? session.is_root || !!capabilities.console_log
      : view === 'buckets' ? canS3
      : ['users', 'user-groups', 'access-keys', 'policies', 'roles', 'storage', 'logs', 'event-destinations', 'oidc-settings'].includes(view) ? canAdmin
        : view === 'settings' ? canAdmin || canKms : true
    if (allowed(route.view)) return
    const first = navigation.flatMap(group => group.items).find(item => allowed(item.view))
    if (!first) return
    const target = appRoutePath(createAppRoute(first.view))
    window.history.replaceState(null, '', target)
    setRoute(parseAppRoute(target))
  }, [route.view, session])

  if (availability === 'offline' || availability === 'not-ready') {
    return <ServiceUnavailable state={availability} retry={() => void bootstrap()} />
  }

  if (session === undefined) {
    return <main className="session-loading" aria-label={t('navigation.verifyingYourSession')}><img className="session-logo" src="/zigfs-logo.svg" alt="ZigFS" /></main>
  }

  if (!session) {
    return <LoginView darkTheme={darkTheme} onToggleTheme={() => setDarkTheme(value => !value)} onLogin={async (username, password) => {
      await api.login(username, password)
      setSession(await api.session())
    }} onStsLogin={async (username, secretKey, sessionToken) => {
      await api.stsLogin(username, secretKey, sessionToken)
      setSession(await api.session())
    }} />
  }

  async function logout() {
    await withLoading(t('navigation.signingOut'), async () => {
      try {
        if (session?.federated) {
          const result = await api.endOIDCSession()
          setSession(null)
          if (result.logout_url) window.location.assign(result.logout_url)
        } else { await api.logout(); setSession(null) }
      } catch (error) { notifyError(error instanceof Error ? error.message : t('navigation.operationFailedPleaseTryAgain')) }
    })
  }

  function navigate(nextView: View, bucket = '', prefix = '') {
    const nextRoute = createAppRoute(nextView, bucket, prefix)
    const path = appRoutePath(nextRoute)
    const currentPath = `${window.location.pathname}${window.location.search}`
    if (currentPath !== path) window.history.pushState(null, '', path)
    setRoute(nextRoute)
    setMobileSidebarOpen(false)
  }

  const { view, bucket: selectedBucket, prefix: selectedPrefix } = route
  const meta = viewMeta[view]
  const connectionLabel = t(availability === 'ready' ? 'navigation.fsReady' : 'navigation.connectingToZigfs')
  const isBucketsActive = view === 'buckets' || view === 'bucket-detail' || view === 'objects'
  const capabilities = session.capabilities ?? { admin: false, kms: false, s3: false, sts: false }
  const canAdmin = session.is_root || capabilities.admin
  const canKms = session.is_root || capabilities.kms
  const canS3 = session.is_root || !!capabilities.s3_console
  const visibleNavigation = navigation.map(group => ({ ...group, items: group.items.filter(item => {
    if (item.view === 'system') return session.is_root || !!capabilities.server_info
    if (item.view === 'system-logs') return session.is_root || !!capabilities.console_log
    if (item.view === 'buckets') return canS3
    if (['users', 'user-groups', 'access-keys', 'policies', 'roles', 'storage', 'logs', 'event-destinations', 'oidc-settings'].includes(item.view)) return canAdmin
    if (item.view === 'settings') return canAdmin || canKms
    return true
  }) })).filter(group => group.items.length > 0)
  const restrictedView = (view === 'system' && !session.is_root && !capabilities.server_info) || (view === 'system-logs' && !session.is_root && !capabilities.console_log) || (view === 'buckets' && !canS3) || (['users', 'user-groups', 'access-keys', 'policies', 'roles', 'storage', 'logs', 'event-destinations', 'oidc-settings'].includes(view) && !canAdmin) || (view === 'settings' && !canAdmin && !canKms)

  return (
    <div className={`app-shell${sidebarCollapsed ? ' sidebar-collapsed' : ''}${mobileSidebarOpen ? ' sidebar-open' : ''}${darkTheme ? ' theme-dark' : ''}`}>
      <button className="sidebar-backdrop" type="button" aria-label={t('navigation.closeNavigation')} onClick={() => setMobileSidebarOpen(false)} />
      <aside className="sidebar">
        <div className="sidebar-brand">
          <img className="brand-logo" src="/zigfs-logo.svg" alt="" aria-hidden="true" />
          <div className="brand-copy"><strong>ZigFS</strong><span>{t('navigation.objectStorageBrand')}</span></div>
          <button className="mobile-close" type="button" aria-label={t('navigation.closeNavigation')} onClick={() => setMobileSidebarOpen(false)}><X aria-hidden="true" /></button>
        </div>
        <nav aria-label={t('navigation.primaryNavigation')}>
          {visibleNavigation.map((group, index) => (
            <div className={`nav-group${index === 2 ? ' nav-group-divider' : ''}`} key={group.label}>
              {group.items.map((item) => {
                const active = item.view === 'buckets' ? isBucketsActive : view === item.view
                const Icon = item.icon
                return (
                  <button
                    className={`nav-item${active ? ' active' : ''}`}
                    key={item.view}
                    type="button"
                    title={sidebarCollapsed ? item.label : undefined}
                    onClick={() => navigate(item.view)}
                  >
                    <Icon className="nav-icon" aria-hidden="true" strokeWidth={1.8} />
                    <span className="nav-label">{item.label}</span>
                  </button>
                )
              })}
            </div>
          ))}
        </nav>
        <div className="sidebar-footer">
          <div className="sidebar-version"><span className="status-dot" /> <span>ZigFS v0.1.0</span></div>
        </div>
      </aside>

      <div className="workspace">
        <header className="app-topbar">
          <div className="topbar-leading">
            <button className="topbar-icon desktop-sidebar-toggle" type="button" aria-label={sidebarCollapsed ? t('navigation.expandNavigation') : t('navigation.collapseNavigation')} onClick={() => setSidebarCollapsed((current) => !current)}>
              {sidebarCollapsed ? <PanelLeftOpen aria-hidden="true" /> : <PanelLeftClose aria-hidden="true" />}
            </button>
            <button className="topbar-icon mobile-sidebar-toggle" type="button" aria-label={t('navigation.openNavigation')} onClick={() => setMobileSidebarOpen(true)}><Menu aria-hidden="true" /></button>
            {(view === 'buckets' || ((view === 'objects' || view === 'bucket-detail') && selectedBucket)) ? <Breadcrumb className="topbar-object-breadcrumb">
              <BreadcrumbList>
                <BreadcrumbItem><span>{t('objects.browser')}</span></BreadcrumbItem>
                <BreadcrumbSeparator />
                {view === 'buckets' ? <BreadcrumbItem><BreadcrumbPage>{t('common.buckets')}</BreadcrumbPage></BreadcrumbItem> : <>
                  <BreadcrumbItem><BreadcrumbLink asChild><button type="button" onClick={() => navigate('buckets')}>{t('common.buckets')}</button></BreadcrumbLink></BreadcrumbItem>
                  <BreadcrumbSeparator />
                  <BreadcrumbItem><BreadcrumbPage>{selectedBucket}</BreadcrumbPage></BreadcrumbItem>
                </>}
              </BreadcrumbList>
            </Breadcrumb> : <Breadcrumb>
              <BreadcrumbList>
                <BreadcrumbItem><BreadcrumbPage>{meta.label}</BreadcrumbPage></BreadcrumbItem>
              </BreadcrumbList>
            </Breadcrumb>}

          </div>
          <div className="topbar-actions">
            <Tooltip>
              <TooltipTrigger asChild><Button variant="ghost" size="icon-sm" type="button" className="connection-state" data-connection-state={availability} aria-label={connectionLabel}><span className="status-dot" aria-hidden="true" /></Button></TooltipTrigger>
              <TooltipContent side="bottom" sideOffset={8}>{connectionLabel}</TooltipContent>
            </Tooltip>
            <ThemeSwitcher dark={darkTheme} onToggle={() => setDarkTheme(current => !current)} />
            <LanguageSwitcher />
            <DropdownMenu>
              <DropdownMenuTrigger asChild><Button variant="ghost" className="topbar-user-trigger" aria-label={t('navigation.userMenu')} title={session.display_name || session.username}><span className="topbar-user-label">{session.display_name || session.username}</span><ChevronDown data-icon="inline-end" /></Button></DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-64 max-w-[calc(100vw-24px)]">
                <DropdownMenuLabel><div>{session.display_name || session.username}</div><div className="text-muted-foreground">{t(canAdmin ? 'account.administrator' : 'account.user')}</div>{session.email && <div>{session.email}</div>}</DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuGroup>
                  <DropdownMenuItem onSelect={() => navigate('profile')}><UserRound />{t('account.profile')}</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => navigate('account-security')}><ShieldCheck />{t('account.security')}</DropdownMenuItem>
                </DropdownMenuGroup>
                <DropdownMenuSeparator />
                <DropdownMenuGroup><DropdownMenuItem onSelect={() => void logout()}><LogOut />{t('navigation.signOut')}</DropdownMenuItem></DropdownMenuGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>

        <main className={`content${view === 'bucket-detail' ? ' content-bucket-detail' : view === 'oidc-settings' ? ' content-oidc' : view === 'settings' ? ' content-system-settings' : ''}`}>
          {(view === 'profile' || view === 'account-security') && <AccountView session={session} security={view === 'account-security'} api={api} onSession={setSession} onNavigate={next => navigate(next)} />}
          {!restrictedView && view === 'buckets' && <BucketsView api={api} onOpenObjects={(name) => navigate('objects', name)} onOpenBucket={(name) => {
            navigate('bucket-detail', name)
          }} />}
          {!restrictedView && view === 'bucket-detail' && <BucketDetailView
            api={api}
            bucketName={selectedBucket}
            onBack={() => navigate('buckets')}
          />}
          {!restrictedView && view === 'objects' && <ObjectsView api={api} initialBucket={selectedBucket} initialPrefix={selectedPrefix} onNavigatePath={(prefix) => navigate('objects', selectedBucket, prefix)} />}
          {!restrictedView && view === 'access-keys' && <AccessKeysView api={api} />}
          {!restrictedView && view === 'roles' && <RolesView api={api} />}
          {!restrictedView && view === 'users' && <IdentitiesView key="users" kind="users" api={api} />}
          {!restrictedView && view === 'user-groups' && <IdentitiesView key="groups" kind="groups" api={api} />}
          {!restrictedView && view === 'policies' && <PoliciesView api={api} />}
          {!restrictedView && view === 'event-destinations' && <EventDestinationsView api={api} />}
          {!restrictedView && view === 'oidc-settings' && <OIDCSettingsView api={api} />}
          {restrictedView && <AccessDeniedView />}
          {!restrictedView && view === 'logs' && <LogsView api={api} />}
          {!restrictedView && view === 'system-logs' && <SystemLogsView api={api} />}
          {!restrictedView && view === 'storage' && <StorageView api={api} />}
          {!restrictedView && view === 'system' && <SystemView api={api} diagnosticsOnly={!canAdmin} />}
          {!restrictedView && view === 'settings' && <SettingsView api={api} session={session} />}
        </main>
      </div>
    </div>
  )
}

function AccessDeniedView() {
  return <section className="service-state" aria-live="polite"><h1>{t('navigation.accessDenied')}</h1><p>{t('navigation.yourAccountDoesNotHavePermissionToAccessThis')}</p></section>
}

function ServiceUnavailable({ state, retry }: { state: 'offline' | 'not-ready'; retry: () => void }) {
  return (
    <main className="service-state">
      <img className="service-logo" src="/zigfs-logo.svg" alt="ZigFS" />
      <span className={`service-state-dot ${state}`} />
      <h1>{state === 'offline' ? t('navigation.zigfsOffline') : t('navigation.zigfsNotReady')}</h1>
      <p>{state === 'offline' ? t('navigation.unableToConnectToZigfs') : t('navigation.zigfsIsRecoveringStorageAndMetadata')}</p>
      <Button type="button" onClick={retry}>{t('navigation.retry')}</Button>
    </main>
  )
}
