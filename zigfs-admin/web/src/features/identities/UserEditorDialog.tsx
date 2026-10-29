import { useEffect, useId, useState, type FormEvent } from 'react'
import type { ApiClient, ManagedGroup, ManagedPolicy, ManagedUser, UserWrite } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { Switch } from '../../components/ui/switch'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'
import { MultiChoice } from './IdentityMultiChoice'
import { UserAccessKeys } from './UserAccessKeys'

export function UserEditorDialog({ api, initialUser, groups, policies, onSaved, onClose }: {
  api: ApiClient
  initialUser: ManagedUser
  groups: ManagedGroup[]
  policies: ManagedPolicy[]
  onSaved: (user: ManagedUser) => void
  onClose: () => void
}) {
  const id = useId()
  const toast = useToast()
  const [user, setUser] = useState(initialUser)
  const [changes, setChanges] = useState<Partial<Pick<UserWrite, 'enabled' | 'groups' | 'policies'>>>({})
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const [saving, setSaving] = useState(false)
  const [invalidPassword, setInvalidPassword] = useState(false)
  const [tab, setTab] = useState('account')

  useEffect(() => {
    let active = true
    setLoading(true); setFailed(false)
    void api.getUser(initialUser.name).then(value => {
      if (active) setUser(value)
    }).catch(reason => {
      if (active) { setFailed(true); toast(reason instanceof Error ? reason.message : '加载用户失败', 'error') }
    }).finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [api, initialUser.name, reload, toast])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (loading || failed || saving || tab === 'access-keys') return
    const size = new TextEncoder().encode(password).length
    if (tab === 'account' && password && (size < 8 || size > 1024)) {
      setInvalidPassword(true)
      toast('密码长度需为 8–1024 字节', 'error')
      return
    }
    setSaving(true)
    try {
      const latest = await api.getUser(user.name)
      const change = tab === 'groups'
        ? { groups: changes.groups ?? latest.groups }
        : tab === 'policies'
          ? { policies: changes.policies ?? latest.policies }
          : { enabled: changes.enabled ?? latest.enabled, ...(password ? { password } : {}) }
      const saved = await api.updateUser({ ...latest, ...change })
      onSaved(saved)
      toast('User updated')
      onClose()
    } catch (reason) { toast(reason instanceof Error ? reason.message : '更新用户失败', 'error') }
    finally { setSaving(false) }
  }
  const disabled = loading || failed || saving

  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog user-edit-dialog" aria-busy={loading || saving}>
    <DialogHeader><DialogTitle>{user.name}</DialogTitle><DialogDescription className="sr-only">Manage user account, groups, policies and access keys. Leave the secret key blank to keep the current password.</DialogDescription></DialogHeader>
    <form className="identity-form" onSubmit={event => void submit(event)} noValidate>
      <div className="identity-form-body">
        <Tabs value={tab} onValueChange={value => { if (!saving) setTab(value) }}>
          <TabsList aria-label="User sections" className="group-edit-tabs user-edit-tabs">
            <TabsTrigger value="account">Account</TabsTrigger><TabsTrigger value="groups">Groups</TabsTrigger><TabsTrigger value="policies">Policies</TabsTrigger><TabsTrigger value="access-keys">Access Keys</TabsTrigger>
          </TabsList>
          <TabsContent value="account"><FieldGroup>
            <Field orientation="horizontal" className="user-status-field"><FieldLabel htmlFor={`${id}-status`}>Status</FieldLabel><Switch id={`${id}-status`} checked={changes.enabled ?? user.enabled} disabled={disabled} onCheckedChange={enabled => setChanges(current => ({ ...current, enabled }))} /></Field>
            <Field data-invalid={invalidPassword || undefined}><FieldLabel htmlFor={`${id}-secret`}>Change Secret Key</FieldLabel><Input id={`${id}-secret`} type="password" autoComplete="new-password" disabled={disabled} value={password} aria-invalid={invalidPassword} onChange={event => { setPassword(event.target.value); setInvalidPassword(false) }} /></Field>
          </FieldGroup></TabsContent>
          <TabsContent value="groups"><MultiChoice title="Groups" placeholder="Select Group" options={groups.map(group => group.name)} selected={changes.groups ?? user.groups} disabled={disabled} onChange={value => setChanges(current => ({ ...current, groups: value }))} /></TabsContent>
          <TabsContent value="policies"><MultiChoice title="Policy" placeholder="Select user group policies" options={policies.map(policy => policy.name)} selected={changes.policies ?? user.policies} disabled={disabled} onChange={value => setChanges(current => ({ ...current, policies: value }))} /></TabsContent>
          <TabsContent value="access-keys"><UserAccessKeys api={api} name={user.name} enabled={user.enabled} /></TabsContent>
        </Tabs>
        {failed && <Button type="button" variant="outline" onClick={() => setReload(value => value + 1)}>Retry</Button>}
      </div>
      <footer className="identity-form-footer"><Button type="button" variant="outline" disabled={saving} onClick={onClose}>{tab === 'access-keys' ? 'Close' : 'Cancel'}</Button>{tab !== 'access-keys' && <Button type="submit" disabled={disabled}>{saving ? 'Submitting…' : 'Submit'}</Button>}</footer>
    </form>
  </DialogContent></Dialog>
}
