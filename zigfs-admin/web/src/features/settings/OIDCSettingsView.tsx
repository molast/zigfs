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
    try { const result = await api.validateOIDCProvider(providerValue()); toast(`Discovery 和 JWKS 可用：${result.issuer}。请通过登录验证客户端配置。`) }
    catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function save() {
    if (readOnly || busy || !loaded || !validate(false)) return
    setBusy(true)
    const value = providerValue()
    try {
      const saved = await (selected ? api.updateOIDCProvider(value) : api.createOIDCProvider(value))
      setProviders(current => [...current.filter(item => item.provider_id !== saved.provider_id), saved])
      select(saved); toast('身份提供商配置已保存')
    } catch (error) { toast(errorMessage(error), 'error') } finally { setBusy(false) }
  }
  async function remove() {
    if (readOnly || !selected || busy || !await confirm({ title: '删除身份提供商', message: `删除 ${selected.provider_id} 的 OIDC 配置？`, danger: true, confirmLabel: '删除', cancelLabel: '取消' })) return
    setBusy(true)
    try { await api.deleteOIDCProvider(selected.provider_id); setProviders(current => current.filter(item => item.provider_id !== selected.provider_id)); reset(); toast('身份提供商已删除') }
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
    if (!/^[A-Za-z0-9_-]+$/.test(draft.providerId)) return fail('提供商 ID 只能包含字母、数字、下划线和连字符。')
    if (!draft.clientId.trim() || (!draft.clientSecret && !selected?.has_secret)) return fail('请填写 客户端 ID 和 客户端密钥。')
    const validUrl = (value: string) => { try { return ['https:', 'http:'].includes(new URL(value).protocol) } catch { return false } }
    if (!validUrl(draft.configurationUrl)) return fail('请填写有效的 发现文档 URL。')
    if (!validUrl(draft.redirectUri)) return fail('请填写有效的 回调地址。')
    if (!draft.scopes.split(',').map(value => value.trim()).includes('openid')) return fail('Scopes 必须包含 openid。')
    if (notify) toast('表单格式校验通过；尚未验证身份提供商连接或登录。')
    return true
  }
  return <section className="oidc-page">
    <header className="page-header"><h2>OpenID Connect 身份提供商</h2></header>
    <section className="oidc-environment" aria-label="登录配置说明">
      <strong>登录配置说明</strong>
      <p>配置用于控制台登录的身份提供商。客户端密钥加密保存，读取配置时不会返回。</p>
      <p>配置保存后立即生效。启用后将在登录页显示；修改配置会使该提供商已有的登录会话失效。</p>
    </section>
    <div className="oidc-layout">
      <aside className="oidc-provider-list">
        <header className="oidc-list-header"><div><h3>身份提供商</h3><p>查看和管理已配置的身份提供商。</p></div>
          <Button variant="outline" size="sm" disabled={busy || !loaded} onClick={reset}><Plus data-icon="inline-start" />添加身份提供商</Button>
        </header>
        {providers.length ? <div className="flex flex-col gap-1 overflow-y-auto p-2">{providers.map(provider => <Button size="sm" key={provider.provider_id} variant={selected?.provider_id === provider.provider_id ? 'secondary' : 'ghost'} disabled={busy} onClick={() => select(provider)} className="justify-start" aria-pressed={selected?.provider_id === provider.provider_id}>{provider.display_name || provider.provider_id}</Button>)}</div> : <Empty><EmptyHeader><EmptyDescription>{loaded ? '尚未配置身份提供商' : loadFailed ? '无法加载身份提供商' : '正在加载身份提供商…'}</EmptyDescription></EmptyHeader>{loadFailed && <Button variant="outline" onClick={() => void refresh()}>重试</Button>}</Empty>}
      </aside>
      <form className="oidc-editor" onSubmit={event => { event.preventDefault(); void save() }}>
        <header className="oidc-editor-header"><div><h3>{selected ? '编辑身份提供商' : '添加身份提供商'}</h3><p>{readOnly ? '此配置由 ZIGFS_OIDC_PROVIDERS 管理，请修改环境变量后重启 ZigFS。' : '配置身份提供商及其权限策略映射。'}</p></div><div className="flex gap-2">{selected && <Button size="sm" variant="destructive" type="button" disabled={busy || readOnly} onClick={() => void remove()}>删除</Button>}<Button size="sm" variant="outline" type="button" disabled={busy} onClick={() => void validateRemote()}>验证连接</Button><Button size="sm" type="submit" disabled={busy || !loaded || readOnly}>{busy ? '处理中…' : '保存'}</Button></div></header>
        <Separator />
        <FieldGroup className="oidc-fields">
          {input('providerId', '提供商 ID', '只能包含字母、数字、下划线和连字符。')}
          <Field><FieldLabel htmlFor="oidc-enabled">启用</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-enabled" disabled={busy || readOnly} checked={enabled} onCheckedChange={setEnabled} /><span>{enabled ? '已启用' : '已禁用'}</span></div></Field>
          {input('displayName', '显示名称')}
          {input('configurationUrl', '发现文档 URL', undefined, 'https://idp.example.com/.well-known/openid-configuration')}
          {input('clientId', '客户端 ID')}
          {input('clientSecret', '客户端密钥', selected ? '留空保留现有密钥。' : '创建身份提供商时必须填写客户端密钥。', '客户端密钥', 'password')}
          <div className="oidc-full">{input('scopes', '授权范围（Scopes）', '使用英文逗号分隔，必须包含 openid。')}</div>
          <div className="oidc-full">{input('audiences', '其他受众（Audiences）', '使用英文逗号分隔受众 ID。', '')}</div>
          <Field><FieldLabel htmlFor="oidc-dynamic">动态回调地址</FieldLabel><div className="flex items-center gap-3"><Switch id="oidc-dynamic" disabled={busy || readOnly} checked={dynamicRedirect} onCheckedChange={setDynamicRedirect} /><span>{dynamicRedirect ? '已启用' : '已禁用'}</span></div><FieldDescription>关闭动态回调时，需填写完整的回调 URL。</FieldDescription></Field>
          {input('redirectUri', dynamicRedirect ? '控制台公开地址' : '回调地址', dynamicRedirect ? '使用此可信来源生成回调地址，路径为 /api/v1/auth/oidc/callback。' : '必须填写完整的回调 URL。', 'https://zigfs.example.com/api/v1/auth/oidc/callback')}
        </FieldGroup>
        <Separator />
        <Collapsible open={advanced} onOpenChange={setAdvanced}>
          <CollapsibleTrigger asChild><Button size="sm" type="button" variant="ghost" className="oidc-advanced-trigger"><ChevronRight data-icon="inline-start" className={advanced ? 'rotate-90' : ''} />高级设置<span className="text-muted-foreground">策略声明 · 用户组声明 · 角色声明</span></Button></CollapsibleTrigger>
          <CollapsibleContent><FieldGroup className="oidc-fields oidc-advanced-fields">
            {input('claimName', '策略声明名')}{input('claimPrefix', '声明值前缀')}
            {input('rolePolicy', '固定策略', '可选，将此身份提供商映射到已有权限策略。')}{input('groupsClaim', '用户组声明名')}
            {input('rolesClaim', '角色声明名', '可选，指定读取角色值的声明（例如 roles）；留空仅使用用户组声明。')}{input('emailClaim', '邮箱声明名')}
            {input('usernameClaim', '用户名声明名')}
          </FieldGroup></CollapsibleContent>
        </Collapsible>
      </form>
    </div>
  </section>
}
