import type { ApiClient, OIDCProvider } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useEffect, useState } from 'react'
import { ChevronRight, Plus } from 'lucide-react'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Switch } from '../../components/ui/switch'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Separator } from '../../components/ui/separator'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '../../components/ui/collapsible'
import { Empty, EmptyDescription, EmptyHeader } from '../../components/ui/empty'
import { useToast } from '../../components/ToastProvider'

const defaults = {
  providerId: '', displayName: '', configurationUrl: '', clientId: '', clientSecret: '',
  scopes: 'openid,profile,email', audiences: '', redirectUri: '', claimName: 'groups',
  claimPrefix: '', rolePolicy: '', groupsClaim: 'groups', rolesClaim: 'roles',
  emailClaim: 'email', usernameClaim: 'preferred_username',
}

export function OIDCSettingsView({ api }: { api: ApiClient }) {
  const [draft, setDraft] = useState(defaults)
  const [enabled, setEnabled] = useState(true)
  const [dynamicRedirect, setDynamicRedirect] = useState(false)
  const [advanced, setAdvanced] = useState(false)
  const toast = useToast()
  const confirm = useConfirm()
  const [providers, setProviders] = useState<OIDCProvider[]>([])
  const [selected, setSelected] = useState<OIDCProvider | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [loadFailed, setLoadFailed] = useState(false)
  const [busy, setBusy] = useState(false)
  const readOnly = selected?.environment_managed ?? false
  const errorMessage = (error: unknown) => error instanceof Error ? error.message : '操作失败'
  async function refresh() {
    setLoadFailed(false)
    try { const result = await api.listOIDCProviders(); setProviders(result.items); setLoaded(true) }
    catch (error) { setLoadFailed(true); toast(errorMessage(error), 'error') }
  }
  useEffect(() => { void refresh() }, [api])
  function select(provider: OIDCProvider) {
    setSelected(provider)
    setDraft({ providerId: provider.provider_id, displayName: provider.display_name, configurationUrl: provider.configuration_url, clientId: provider.client_id, clientSecret: '', scopes: provider.scopes, audiences: provider.audiences, redirectUri: provider.redirect_uri, claimName: provider.claim_name, claimPrefix: provider.claim_prefix, rolePolicy: provider.role_policy, groupsClaim: provider.groups_claim, rolesClaim: provider.roles_claim, emailClaim: provider.email_claim, usernameClaim: provider.username_claim })
    setEnabled(provider.enabled); setDynamicRedirect(provider.dynamic_redirect)
  }
  function reset() { setSelected(null); setDraft({ ...defaults }); setEnabled(true); setDynamicRedirect(false); setAdvanced(false) }
  function providerValue(): OIDCProvider {
    return { provider_id: draft.providerId, display_name: draft.displayName, enabled, configuration_url: draft.configurationUrl, client_id: draft.clientId, client_secret: draft.clientSecret, scopes: draft.scopes, audiences: draft.audiences, dynamic_redirect: dynamicRedirect, redirect_uri: draft.redirectUri, claim_name: draft.claimName, claim_prefix: draft.claimPrefix, role_policy: draft.rolePolicy, groups_claim: draft.groupsClaim, roles_claim: draft.rolesClaim, email_claim: draft.emailClaim, username_claim: draft.usernameClaim }
  }
  async function validateRemote() {
    if (busy || !validate(false)) return
    setBusy(true)
    try { const result = await api.validateOIDCProvider(providerValue()); toast(`Discovery 和 JWKS 可用：${result.issuer}。请通过登录验证 Client 配置。`) }
    catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function save() {
    if (readOnly || busy || !loaded || !validate(false)) return
    setBusy(true)
    const value = providerValue()
    try {
      const saved = await (selected ? api.updateOIDCProvider(value) : api.createOIDCProvider(value))
      setProviders(current => [...current.filter(item => item.provider_id !== saved.provider_id), saved])
      select(saved); toast('Provider 配置已保存')
    } catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function remove() {
    if (readOnly || !selected || busy || !await confirm({ title: 'Delete Provider', message: `删除 ${selected.provider_id} 的 OIDC 配置？`, danger: true, confirmLabel: 'Delete', cancelLabel: 'Cancel' })) return
    setBusy(true)
    try { await api.deleteOIDCProvider(selected.provider_id); setProviders(current => current.filter(item => item.provider_id !== selected.provider_id)); reset(); toast('Provider 已删除') }
    catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  function input(key: keyof typeof defaults, label: string, help?: string, placeholder = label, type = 'text') {
    return <Field><FieldLabel htmlFor={`oidc-${key}`}>{label}</FieldLabel>
      <Input id={`oidc-${key}`} disabled={busy || readOnly || (key === 'providerId' && selected !== null)} value={draft[key]} type={type} autoComplete={type === 'password' ? 'new-password' : 'off'} placeholder={placeholder} onChange={event => setDraft(current => ({ ...current, [key]: event.target.value }))} />
      {help && <FieldDescription>{help}</FieldDescription>}
    </Field>
  }
  function validate(notify = true): boolean {
    const fail = (message: string) => { toast(message, 'error'); return false }
    if (!/^[A-Za-z0-9_-]+$/.test(draft.providerId)) return fail('Provider ID 只能包含字母、数字、下划线和连字符。')
    if (!draft.clientId.trim() || (!draft.clientSecret && !selected?.has_secret)) return fail('请填写 Client ID 和 Client Secret。')
    const validUrl = (value: string) => { try { return ['https:', 'http:'].includes(new URL(value).protocol) } catch { return false } }
    if (!validUrl(draft.configurationUrl)) return fail('请填写有效的 Configuration URL。')
    if (!validUrl(draft.redirectUri)) return fail('请填写有效的 Redirect URI。')
    if (!draft.scopes.split(',').map(value => value.trim()).includes('openid')) return fail('Scopes 必须包含 openid。')
    if (notify) toast('表单格式校验通过；尚未验证 Provider 连接或登录。')
    return true
  }
  return <section className="oidc-page">
    <header className="page-header"><h2>OIDC Providers</h2></header>
    <section className="oidc-environment" aria-label="Provider configuration">
      <strong>Provider Configuration</strong>
      <p>Provider settings are persisted in ZigFS. Client secrets are encrypted and never returned.</p>
      <p>配置保存后立即生效。启用的 Provider 可用于登录；修改配置会使其已有登录会话失效。</p>
    </section>
    <div className="oidc-layout">
      <aside className="oidc-provider-list">
        <header className="oidc-list-header"><div><h3>OIDC Providers</h3><p>View and manage persisted OIDC providers.</p></div>
          <Button variant="outline" size="sm" disabled={busy || !loaded} onClick={reset}><Plus data-icon="inline-start" />Add Provider</Button>
        </header>
        {providers.length ? <div className="flex flex-col gap-1 overflow-y-auto p-2">{providers.map(provider => <Button size="sm" key={provider.provider_id} variant={selected?.provider_id === provider.provider_id ? 'secondary' : 'ghost'} disabled={busy} onClick={() => select(provider)} className="justify-start" aria-pressed={selected?.provider_id === provider.provider_id}>{provider.display_name || provider.provider_id}</Button>)}</div> : <Empty><EmptyHeader><EmptyDescription>{loaded ? 'No OIDC providers configured yet.' : loadFailed ? 'Unable to load providers.' : 'Loading providers…'}</EmptyDescription></EmptyHeader>{loadFailed && <Button variant="outline" onClick={() => void refresh()}>Retry</Button>}</Empty>}
      </aside>
      <form className="oidc-editor" onSubmit={event => { event.preventDefault(); void save() }}>
        <header className="oidc-editor-header"><div><h3>{selected ? 'Edit Provider' : 'Add Provider'}</h3><p>{readOnly ? 'Managed by ZIGFS_OIDC_PROVIDERS. Update the environment and restart ZigFS.' : 'Configure an identity provider and its policy mappings.'}</p></div><div className="flex gap-2">{selected && <Button size="sm" variant="destructive" type="button" disabled={busy || readOnly} onClick={() => void remove()}>Delete</Button>}<Button size="sm" variant="outline" type="button" disabled={busy} onClick={() => void validateRemote()}>Validate</Button><Button size="sm" type="submit" disabled={busy || !loaded || readOnly}>{busy ? 'Saving…' : 'Save'}</Button></div></header>
        <Separator />
        <FieldGroup className="oidc-fields">
          {input('providerId', 'Provider ID', 'Only letters, numbers, underscores, and hyphens are allowed.')}
          <Field><FieldLabel htmlFor="oidc-enabled">Enabled</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-enabled" disabled={busy || readOnly} checked={enabled} onCheckedChange={setEnabled} /><span>{enabled ? 'Enabled' : 'Disabled'}</span></div></Field>
          {input('displayName', 'Display Name')}
          {input('configurationUrl', 'Configuration URL', undefined, 'https://idp.example.com/.well-known/openid-configuration')}
          {input('clientId', 'Client ID')}
          {input('clientSecret', 'Client Secret', selected ? 'Leave blank to keep the existing secret.' : 'Client secret is required when creating a provider.', 'Client Secret', 'password')}
          <div className="oidc-full">{input('scopes', 'Scopes', 'Use comma-separated scopes. The openid scope is required.')}</div>
          <div className="oidc-full">{input('audiences', 'Other Audiences', 'Comma-separated audience IDs.', '')}</div>
          <Field><FieldLabel htmlFor="oidc-dynamic">Use Dynamic Redirect URI</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-dynamic" disabled={busy || readOnly} checked={dynamicRedirect} onCheckedChange={setDynamicRedirect} /><span>{dynamicRedirect ? 'Enabled' : 'Disabled'}</span></div><FieldDescription>Provide an absolute callback URL when dynamic redirect is disabled.</FieldDescription></Field>
          {input('redirectUri', dynamicRedirect ? 'Public Console URL' : 'Redirect URI', dynamicRedirect ? 'The callback is derived from this trusted origin: /api/v1/auth/oidc/callback.' : 'Must be an absolute callback URL.', 'https://zigfs.example.com/api/v1/auth/oidc/callback')}
        </FieldGroup>
        <Separator />
        <Collapsible open={advanced} onOpenChange={setAdvanced}>
          <CollapsibleTrigger asChild><Button size="sm" type="button" variant="ghost" className="oidc-advanced-trigger"><ChevronRight data-icon="inline-start" className={advanced ? 'rotate-90' : ''} />Advanced Settings<span className="text-muted-foreground">Claim Name · Groups Claim · Roles Claim</span></Button></CollapsibleTrigger>
          <CollapsibleContent><FieldGroup className="oidc-fields oidc-advanced-fields">
            {input('claimName', 'Claim Name')}{input('claimPrefix', 'Claim Prefix')}
            {input('rolePolicy', 'Role Policy', 'Optional. Map this provider to existing policy names.')}{input('groupsClaim', 'Groups Claim')}
            {input('rolesClaim', 'Roles Claim', 'Optional. Separate claim for role values (e.g. roles). Leave empty to use groups claim only.')}{input('emailClaim', 'Email Claim')}
            {input('usernameClaim', 'Username Claim')}
          </FieldGroup></CollapsibleContent>
        </Collapsible>
      </form>
    </div>
  </section>
}
