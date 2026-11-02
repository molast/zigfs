import { t } from '@/locales'
import type { ApiClient, OIDCProvider } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useEffect, useState } from 'react'
import { ChevronRight, Plus } from 'lucide-react'
import { Button } from '../../components/ui/Button'
import { Badge } from '../../components/ui/Badge'
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
  const errorMessage = (error: unknown) => error instanceof Error ? error.message : t('settings.operationFailed')
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
    try { const result = await api.validateOIDCProvider(providerValue()); toast(t('settings.discoveryAndJwksAreAvailableValueSignInTo', { '0': result.issuer })) }
    catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function save() {
    if (readOnly || busy || !loaded || !validate(false)) return
    setBusy(true)
    const value = providerValue()
    try {
      const saved = await (selected ? api.updateOIDCProvider(value) : api.createOIDCProvider(value))
      setProviders(current => [...current.filter(item => item.provider_id !== saved.provider_id), saved])
      select(saved); toast(t('settings.identityProviderConfigurationSaved'))
    } catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function remove() {
    if (readOnly || !selected || busy || !await confirm({ title: t('settings.deleteIdentityProvider'), message: t('settings.deleteTheOidcConfigurationForValue', { '0': selected.provider_id }), danger: true, confirmLabel: t('settings.delete'), cancelLabel: t('settings.cancel') })) return
    setBusy(true)
    try { await api.deleteOIDCProvider(selected.provider_id); setProviders(current => current.filter(item => item.provider_id !== selected.provider_id)); reset(); toast(t('settings.identityProviderDeleted')) }
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
    if (!/^[A-Za-z0-9_-]+$/.test(draft.providerId)) return fail(t('settings.providerIdMayOnlyContainLettersNumbersUnderscoresAnd'))
    if (!draft.clientId.trim() || (!draft.clientSecret && !selected?.has_secret)) return fail(t('settings.enterAClientIdAndClientSecret'))
    const validUrl = (value: string) => { try { return ['https:', 'http:'].includes(new URL(value).protocol) } catch { return false } }
    if (!validUrl(draft.configurationUrl)) return fail(t('settings.enterAValidDiscoveryDocumentUrl'))
    if (!validUrl(draft.redirectUri)) return fail(t('settings.enterAValidRedirectUri'))
    if (!draft.scopes.split(',').map(value => value.trim()).includes('openid')) return fail(t('settings.scopesMustIncludeOpenid'))
    if (notify) toast(t('settings.formValidationPassedProviderConnectivityAndSignInHave'))
    return true
  }
  return <section className="oidc-page">
    <header className="page-header"><h2>{t('settings.openidConnectIdentityProviders')}</h2></header>
    <section className="oidc-environment" aria-label={t('settings.signInConfiguration')}>
      <strong>{t('settings.signInConfiguration')}</strong>
      <p>{t('settings.configureIdentityProvidersForConsoleSignInClientSecrets')}</p>
      <p>{t('settings.changesTakeEffectImmediatelyEnabledProvidersAppearOnThe')}</p>
    </section>
    <div className="oidc-layout">
      <aside className="oidc-provider-list">
        <header className="oidc-list-header"><div><h3>{t('settings.identityProviders')}</h3><p>{t('settings.viewAndManageConfiguredIdentityProviders')}</p></div>
          <Button variant="outline" size="sm" disabled={busy || !loaded} onClick={reset}><Plus data-icon="inline-start" />{t('settings.addIdentityProvider')}</Button>
        </header>
        {providers.length ? <div className="oidc-provider-items">{providers.map(provider => {
          const isSelected = selected?.provider_id === provider.provider_id
          return <Button key={provider.provider_id} variant="ghost" disabled={busy} onClick={() => select(provider)} className={`oidc-provider-card${isSelected ? ' is-selected' : ''}`} aria-pressed={isSelected}>
            <span className="oidc-provider-card-heading"><span className="oidc-provider-card-identity"><strong>{provider.display_name || provider.provider_id}</strong><small>{provider.provider_id}</small></span><Badge className={`oidc-status-badge${provider.enabled ? ' is-enabled' : ''}`}>{provider.enabled ? t('settings.enabled') : t('settings.disabled')}</Badge></span>
            <span className="oidc-provider-card-badges">
              <Badge>{provider.environment_managed ? t('settings.environmentManaged') : t('settings.persistedConfiguration')}</Badge>
              <Badge>{provider.has_secret ? t('settings.secretConfigured') : t('settings.secretNotConfigured')}</Badge>
            </span>
          </Button>
        })}</div> : <Empty><EmptyHeader><EmptyDescription>{loaded ? t('settings.noIdentityProvidersConfiguredYet') : loadFailed ? t('settings.unableToLoadIdentityProviders') : t('settings.loadingIdentityProviders')}</EmptyDescription></EmptyHeader>{loadFailed && <Button variant="outline" onClick={() => void refresh()}>{t('settings.retry')}</Button>}</Empty>}
      </aside>
      <form className="oidc-editor" onSubmit={event => { event.preventDefault(); void save() }}>
        <header className="oidc-editor-header"><div><h3>{selected ? t('settings.editIdentityProvider') : t('settings.addIdentityProvider')}</h3><p>{readOnly ? t('settings.managedByZigfsOidcProvidersUpdateTheEnvironmentVariable') : t('settings.configureAnIdentityProviderAndItsPolicyMappings')}</p></div><div className="flex gap-2">{selected && <Button size="sm" variant="destructive" type="button" disabled={busy || readOnly} onClick={() => void remove()}>{t('settings.delete')}</Button>}<Button size="sm" variant="outline" type="button" disabled={busy} onClick={() => void validateRemote()}>{t('settings.validateConnection')}</Button><Button size="sm" type="submit" disabled={busy || !loaded || readOnly}>{busy ? t('settings.processing') : t('settings.save')}</Button></div></header>
        <Separator />
        <FieldGroup className="oidc-fields">
          {input('providerId', t('settings.providerId'), t('settings.onlyLettersNumbersUnderscoresAndHyphensAreAllowed'))}
          <Field><FieldLabel htmlFor="oidc-enabled">{t('settings.enable')}</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-enabled" disabled={busy || readOnly} checked={enabled} onCheckedChange={setEnabled} /><span>{enabled ? t('settings.enabled') : t('settings.disabled')}</span></div></Field>
          {input('displayName', t('settings.displayName'))}
          {input('configurationUrl', t('settings.discoveryDocumentUrl'), undefined, 'https://idp.example.com/.well-known/openid-configuration')}
          {input('clientId', t('settings.clientId'))}
          {input('clientSecret', t('settings.clientSecret'), selected ? t('settings.leaveBlankToKeepTheExistingSecret') : t('settings.aClientSecretIsRequiredWhenCreatingAnIdentity'), t('settings.clientSecret'), 'password')}
          <div className="oidc-full">{input('scopes', t('settings.scopes'), t('settings.separateScopesWithCommasTheOpenidScopeIsRequired'))}</div>
          <div className="oidc-full">{input('audiences', t('settings.otherAudiences'), t('settings.separateAudienceIdsWithCommas'), '')}</div>
          <Field><FieldLabel htmlFor="oidc-dynamic">{t('settings.dynamicRedirectUri')}</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-dynamic" disabled={busy || readOnly} checked={dynamicRedirect} onCheckedChange={setDynamicRedirect} /><span>{dynamicRedirect ? t('settings.enabled') : t('settings.disabled')}</span></div><FieldDescription>{t('settings.enterAnAbsoluteCallbackUrlWhenDynamicRedirectIs')}</FieldDescription></Field>
          {input('redirectUri', dynamicRedirect ? t('settings.publicConsoleUrl') : t('settings.redirectUri'), dynamicRedirect ? t('settings.theCallbackUsesThisTrustedOriginWithThePath') : t('settings.enterAnAbsoluteCallbackUrl'), 'https://zigfs.example.com/api/v1/auth/oidc/callback')}
        </FieldGroup>
        <Separator />
        <Collapsible open={advanced} onOpenChange={setAdvanced}>
          <CollapsibleTrigger asChild><Button size="sm" type="button" variant="ghost" className="oidc-advanced-trigger"><ChevronRight data-icon="inline-start" className={advanced ? 'rotate-90' : ''} />{t('settings.advancedSettings')}<span className="text-muted-foreground">{t('settings.policyClaimGroupsClaimRolesClaim')}</span></Button></CollapsibleTrigger>
          <CollapsibleContent><FieldGroup className="oidc-fields oidc-advanced-fields">
            {input('claimName', t('settings.policyClaimName'))}{input('claimPrefix', t('settings.claimValuePrefix'))}
            {input('rolePolicy', t('settings.fixedPolicy'), t('settings.optionalMapThisIdentityProviderToExistingPolicies'))}{input('groupsClaim', t('settings.groupsClaimName'))}
            {input('rolesClaim', t('settings.rolesClaimName'), t('settings.optionalSpecifyTheClaimForRoleValuesForExample'))}{input('emailClaim', t('settings.emailClaimName'))}
            {input('usernameClaim', t('settings.usernameClaimName'))}
          </FieldGroup></CollapsibleContent>
        </Collapsible>
      </form>
    </div>
  </section>
}
