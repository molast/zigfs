import { t, getFormatLocale } from '@/locales'
import { useCallback, useEffect, useId, useMemo, useState, type FormEvent } from 'react'
import { ArrowDown, ArrowLeft, ArrowUp, ArrowUpDown, Pencil, Plus, Search, Trash2, UsersRound } from 'lucide-react'
import type { ApiClient, GroupWrite, ManagedGroup, ManagedPolicy, ManagedUser, UserWrite } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Badge } from '../../components/ui/Badge'
import { Input } from '../../components/ui/Input'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { Checkbox } from '../../components/ui/checkbox'
import { Field, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '../../components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import { MultiChoice } from './IdentityMultiChoice'
import { GroupEditorDialog } from './GroupEditorDialog'
import { UserEditorDialog } from './UserEditorDialog'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '../../components/ui/select'

type Kind = 'users' | 'groups'
type Identity = ManagedUser | ManagedGroup
type SortKey = 'name' | 'policies' | 'enabled' | 'groups' | 'updated_at'
const message = (reason: unknown) => reason instanceof Error ? reason.message : t('identities.operationFailedPleaseTryAgain')
const dateLabel = (value: number) => value ? new Date(value * 1000).toLocaleString(getFormatLocale()) : '—'

export function IdentitiesView({ kind, api }: { kind: Kind; api: ApiClient }) {
  const isGroup = kind === 'groups'
  const title = isGroup ? t('identities.userGroups') : t('identities.users')
  const singular = isGroup ? t('identities.group') : t('identities.user')
  const toast = useToast()
  const confirm = useConfirm()
  const [users, setUsers] = useState<ManagedUser[]>([])
  const [groups, setGroups] = useState<ManagedGroup[]>([])
  const [policies, setPolicies] = useState<ManagedPolicy[]>([])
  const [loaded, setLoaded] = useState(false)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState<string | null>(null)
  const [checked, setChecked] = useState<string[]>([])
  const [editor, setEditor] = useState<{ value: Identity | null } | null>(null)
  const [editingGroup, setEditingGroup] = useState<string | null>(null)
  const [batch, setBatch] = useState<'groups' | 'policies' | null>(null)
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)
  const [rows, setRows] = useState(10)
  const [sort, setSort] = useState<{ key: SortKey; desc: boolean }>({ key: isGroup ? 'name' : 'updated_at', desc: !isGroup })

  const refresh = useCallback(async () => {
    setBusy(true)
    try {
      const [nextUsers, nextGroups, nextPolicies] = await Promise.all([api.listUsers(), api.listGroups(), api.listPolicies()])
      setUsers(nextUsers); setGroups(nextGroups); setPolicies(nextPolicies); setLoaded(true)
      const names = new Set((isGroup ? nextGroups : nextUsers).map(item => item.name))
      setSelected(current => current && names.has(current) ? current : null)
      setChecked(current => current.filter(name => names.has(name)))
    } catch (reason) { toast(message(reason), 'error') }
    finally { setBusy(false) }
  }, [api, isGroup, toast])
  useEffect(() => { void refresh() }, [refresh])

  const items = isGroup ? groups : users
  const current = items.find(item => item.name === selected)
  const filtered = useMemo(() => {
    const sortValue = (item: Identity): string | number => {
      if (sort.key === 'policies') return item.policies.join(', ')
      if (sort.key === 'groups') return 'groups' in item ? item.groups.join(', ') : ''
      if (sort.key === 'enabled') return Number(item.enabled)
      return item[sort.key] ?? 0
    }
    return items.filter(item => item.name.toLowerCase().includes(query.trim().toLowerCase())).sort((a, b) => {
      const left = sortValue(a), right = sortValue(b)
      const order = typeof left === 'number' && typeof right === 'number' ? left - right : String(left).localeCompare(String(right))
      return (sort.desc ? -order : order) || a.name.localeCompare(b.name)
    })
  }, [items, query, sort])
  const pages = Math.ceil(filtered.length / rows)
  const currentPage = pages ? Math.min(page, pages) : 0
  const visible = filtered.slice(Math.max(0, currentPage - 1) * rows, currentPage * rows)
  const allChecked = visible.length > 0 && visible.every(item => checked.includes(item.name))
  const someChecked = visible.some(item => checked.includes(item.name))
  const memberships = current && !isGroup ? groups.filter(group => group.members.includes(current.name)) : []

  async function save(value: UserWrite | GroupWrite) {
    setBusy(true)
    try {
      if (isGroup) await (editor?.value ? api.updateGroup(value as GroupWrite) : api.createGroup(value as GroupWrite))
      else await (editor?.value ? api.updateUser(value) : api.createUser(value))
      setEditor(null)
      toast(`${singular} ${editor?.value ? 'updated' : 'created'}`)
      await refresh()
    } finally { setBusy(false) }
  }
  async function remove(names: string[]) {
    if (!await confirm({ title: names.length > 1 ? t('identities.deleteSelected') : t('identities.deleteValue', { '0': singular }), message: t('identities.deleteValueValue', { '0': names.length, '1': isGroup ? t('common.groupsUsersWillBeRetained') : t('common.usersGroupMembershipsWillAlsoBeRemoved') }), danger: true, confirmLabel: t('identities.delete'), cancelLabel: t('identities.cancel') })) return
    setBusy(true)
    const done: string[] = []
    const failed: string[] = []
    for (const name of names) {
      try { await (isGroup ? api.deleteGroup(name) : api.deleteUser(name)); done.push(name) }
      catch (reason) { failed.push(`${name}: ${message(reason)}`) }
    }
    setChecked(current => current.filter(name => !done.includes(name)))
    if (done.length) toast(t('identities.deletedValueValue', { '0': done.length, '1': isGroup ? t('common.groups') : t('common.users') }))
    if (failed.length) toast(failed.join('；'), 'error')
    await refresh()
  }
  async function assign(names: string[]) {
    const targets = batch === 'groups' ? names : checked
    const failed: string[] = []
    let done = 0
    setBusy(true)
    try {
      for (const name of targets) {
        try {
          const group = await api.getGroup(name)
          await api.updateGroup({ ...group, ...(batch === 'groups' ? { members: [...new Set([...group.members, ...checked])] } : { policies: [...new Set([...group.policies, ...names])] }) })
          done++
        } catch (reason) { failed.push(`${name}: ${message(reason)}`) }
      }
      if (done) toast(t('identities.updatedValueGroups', { '0': done }))
      await refresh()
      if (failed.length) throw new Error(failed.join('；'))
      setBatch(null); setChecked([])
    } finally { setBusy(false) }
  }
  function sortHeader(label: string, key: SortKey) {
    const active = sort.key === key
    const Icon = active ? sort.desc ? ArrowDown : ArrowUp : ArrowUpDown
    return <TableHead aria-sort={active ? sort.desc ? 'descending' : 'ascending' : 'none'}><Button variant="ghost" size="sm" onClick={() => { setSort({ key, desc: active ? !sort.desc : false }); setPage(1) }}>{label}<Icon /></Button></TableHead>
  }

  return <section className="identities-page" aria-busy={busy}>
    <header className="page-header identities-header">
      <div className="flex items-center gap-2">{current && <Button variant="ghost" size="icon" aria-label={`Back to ${title}`} onClick={() => setSelected(null)}><ArrowLeft /></Button>}<h2>{current?.name ?? title}</h2></div>
      <div className="identity-header-actions">
        {current ? <><Button variant="outline" disabled={busy} onClick={() => setEditor({ value: current })}><Pencil />{t('identities.edit')}</Button><Button variant="destructive" disabled={busy} onClick={() => void remove([current.name])}><Trash2 />{t('identities.delete')}</Button></> : <>
          <div className="identity-search"><Search aria-hidden="true" /><Input aria-label={`Search ${title}`} placeholder={isGroup ? t('identities.searchUserGroup') : t('identities.searchAccessUser')} value={query} onChange={event => { setQuery(event.target.value); setPage(1); setChecked([]) }} /></div>
          {!isGroup && <Button variant="outline" disabled={busy || !checked.length} onClick={() => void remove(checked)}><Trash2 />{t('identities.deleteSelected')}</Button>}
          <Button variant="outline" disabled={busy || !checked.length} onClick={() => setBatch(isGroup ? 'policies' : 'groups')}><UsersRound />{isGroup ? t('identities.assignPolicy') : t('identities.addToGroup')}</Button>
          <Button variant="outline" disabled={busy || !loaded} onClick={() => setEditor({ value: null })}><Plus />{isGroup ? t('identities.addUserGroup') : t('identities.addUser')}</Button>
        </>}
      </div>
    </header>
    {current ? <Tabs key={current.name} defaultValue="summary" orientation="vertical" className="identity-detail">
      <TabsList className="identity-detail-nav" aria-label={`${singular} sections`}>
        <TabsTrigger value="summary">{t('identities.summary')}</TabsTrigger>
        <TabsTrigger value="policies">{t('identities.policiesCountLabel')}{current.policies.length})</TabsTrigger>
        <TabsTrigger value="members">{isGroup ? t('identities.membersValue', { '0': (current as ManagedGroup).members.length }) : t('identities.groupsValue', { '0': memberships.length })}</TabsTrigger>
      </TabsList>
      <div className="identity-detail-content">
        <TabsContent value="summary"><h3>{singular} {t('identities.summary')}</h3><dl className="definition-list">
          <div><dt>{t('identities.name')}</dt><dd>{current.name}</dd></div><div><dt>{t('identities.status')}</dt><dd><Badge>{current.enabled ? t('identities.enabled') : t('identities.disabled')}</Badge></dd></div>
          <div><dt>{t('identities.description')}</dt><dd className="whitespace-pre-wrap break-words">{current.description || '—'}</dd></div>
          <div><dt>{t('identities.policies')}</dt><dd>{current.policies.length}</dd></div>
          <div><dt>{isGroup ? t('identities.members') : t('identities.groups')}</dt><dd>{isGroup ? (current as ManagedGroup).members.length : memberships.length}</dd></div>
        </dl></TabsContent>
        <TabsContent value="policies"><h3>{t('identities.assignedPolicies')}</h3><NameList names={current.policies} empty={t('identities.noPolicies')} />
          {!isGroup && <><h3 className="mt-6">{t('identities.policiesFromGroups')}</h3><NameList names={[...new Set(memberships.filter(group => group.enabled).flatMap(group => group.policies))]} empty={t('identities.noGroupPolicies')} /></>}
        </TabsContent>
        <TabsContent value="members"><h3>{isGroup ? t('identities.groupMembers') : t('identities.userGroups')}</h3><NameList names={isGroup ? (current as ManagedGroup).members : memberships.map(group => group.name)} empty={isGroup ? t('identities.noMembersInThisGroup') : t('identities.thisUserDoesNotBelongToAnyGroups')} />{!isGroup && <p className="identity-scope-note">{t('identities.editMembershipsOnTheUserGroupsPage')}</p>}</TabsContent>
      </div>
    </Tabs> : <>
      <div className="identity-table-frame">
        <Table><TableHeader><TableRow>
          <TableHead className="identity-check-cell"><Checkbox aria-label={t('identities.selectCurrentPage')} disabled={busy || !visible.length} checked={allChecked ? true : someChecked ? 'indeterminate' : false} onCheckedChange={value => setChecked(current => value === true ? [...new Set([...current, ...visible.map(item => item.name)])] : current.filter(name => !visible.some(item => item.name === name)))} /></TableHead>
          {sortHeader(t('common.name'), 'name')}
          {!isGroup && <>{sortHeader(t('common.policyName'), 'policies')}{sortHeader(t('common.status'), 'enabled')}{sortHeader(t('common.memberOf'), 'groups')}{sortHeader(t('common.updatedAt'), 'updated_at')}</>}
          <TableHead className="identity-actions-cell">{t('identities.actions')}</TableHead>
        </TableRow></TableHeader><TableBody>
          {visible.map(item => <TableRow key={item.name} data-state={checked.includes(item.name) ? 'selected' : undefined}>
            <TableCell className="identity-check-cell"><Checkbox aria-label={`Select ${item.name}`} disabled={busy} checked={checked.includes(item.name)} onCheckedChange={value => setChecked(current => value === true ? [...current, item.name] : current.filter(name => name !== item.name))} /></TableCell>
            <TableCell>{item.name}</TableCell>
            {!isGroup && <><TableCell><NameList names={item.policies} empty="—" /></TableCell><TableCell><Badge>{item.enabled ? t('identities.enabled') : t('identities.disabled')}</Badge></TableCell><TableCell><NameList names={'groups' in item ? item.groups : []} empty="—" /></TableCell><TableCell>{dateLabel(item.updated_at)}</TableCell></>}
            <TableCell className="identity-actions-cell"><div className="flex items-center justify-center gap-2"><Button variant="outline" size="sm" disabled={busy} onClick={() => isGroup ? setEditingGroup(item.name) : setEditor({ value: item })}><Pencil data-icon="inline-start" />{t('identities.edit')}</Button><Button variant="destructive" size="sm" disabled={busy} onClick={() => void remove([item.name])}><Trash2 data-icon="inline-start" />{t('identities.delete')}</Button></div></TableCell>
          </TableRow>)}
          {!visible.length && <TableRow><TableCell colSpan={isGroup ? 3 : 7} className="identity-empty-cell"><Empty><EmptyHeader><EmptyTitle>{!loaded ? busy ? t('identities.loading') : t('identities.unableToLoadData') : query ? t('identities.noMatchingResults') : t('identities.noData')}</EmptyTitle><EmptyDescription>{!loaded ? t('identities.retryLoadingData') : query ? t('identities.tryAnotherSearch') : isGroup ? t('identities.createUserGroupsToOrganizePermissions') : t('identities.createAUserToGetStarted')}</EmptyDescription></EmptyHeader>{!loaded && !busy && <Button variant="outline" onClick={() => void refresh()}>{t('identities.retry')}</Button>}</Empty></TableCell></TableRow>}
        </TableBody></Table>
      </div>
      <footer className="identity-pagination">
        <div className="flex items-center gap-3"><span>{t('identities.rowsPerPage')}</span><Select value={String(rows)} onValueChange={value => { setRows(Number(value)); setPage(1) }}><SelectTrigger aria-label={t('identities.rowsPerPage')} className="identity-page-size"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{[10, 25, 50].map(size => <SelectItem key={size} value={String(size)}>{size}</SelectItem>)}</SelectGroup></SelectContent></Select></div>
        <div className="flex items-center gap-2"><span>{t('common.pagination', { page: currentPage, total: pages })}</span>{[[t('common.first'), 1], [t('common.prev'), currentPage - 1], [t('common.next'), currentPage + 1], [t('common.last'), pages]].map(([label, target], index) => <Button key={label} variant="outline" size="sm" disabled={!pages || (index < 2 ? currentPage <= 1 : currentPage >= pages)} onClick={() => setPage(Number(target))}>{label}</Button>)}</div>
      </footer>
    </>}
    {editingGroup && groups.find(group => group.name === editingGroup) && <GroupEditorDialog key={editingGroup} api={api} initialGroup={groups.find(group => group.name === editingGroup)!} users={users} policies={policies} onSaved={saved => setGroups(current => current.map(group => group.name === saved.name ? saved : group))} onClose={() => { setEditingGroup(null); void refresh() }} />}
    {editor && (!isGroup && editor.value ? <UserEditorDialog key={editor.value.name} api={api} initialUser={editor.value as ManagedUser} groups={groups} policies={policies} onSaved={saved => setUsers(current => current.map(user => user.name === saved.name ? saved : user))} onClose={() => setEditor(null)} /> : <IdentityEditor kind={kind} value={editor.value} users={users} groups={groups} policies={policies} onSave={save} onClose={() => setEditor(null)} />)}
    {batch && <AssignmentDialog kind={batch} count={checked.length} options={(batch === 'groups' ? groups : policies).map(item => item.name)} onSave={assign} onClose={() => setBatch(null)} />}
  </section>
}

function NameList({ names, empty }: { names: string[]; empty: string }) {
  return names.length ? <div className="flex flex-wrap gap-2">{names.map(name => <Badge key={name}>{name}</Badge>)}</div> : <span className="identity-muted">{empty}</span>
}

function IdentityEditor({ kind, value, users, groups, policies, onSave, onClose }: { kind: Kind; value: Identity | null; users: ManagedUser[]; groups: ManagedGroup[]; policies: ManagedPolicy[]; onSave: (value: UserWrite | GroupWrite) => Promise<void>; onClose: () => void }) {
  const id = useId()
  const toast = useToast()
  const [name, setName] = useState(value?.name ?? '')
  const [password, setPassword] = useState('')
  const [enabled, setEnabled] = useState(value?.enabled ?? true)
  const [assigned, setAssigned] = useState(value?.policies ?? [])
  const [members, setMembers] = useState(value && 'members' in value ? value.members : [])
  const [selectedGroups, setSelectedGroups] = useState(value && 'groups' in value ? value.groups : [])
  const [saving, setSaving] = useState(false)
  const isGroup = kind === 'groups'
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (saving) return
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(name.trim())) { toast(t('identities.nameMustContain1128LettersNumbersPeriodsUnderscores'), 'error'); return }
    const size = new TextEncoder().encode(password).length
    if (!isGroup && ((!value && !password) || (password && (size < 8 || size > 1024)))) { toast(t('identities.passwordMustContain81024Bytes'), 'error'); return }
    setSaving(true)
    try {
      await onSave({ name: name.trim(), description: value?.description ?? '', enabled, policies: assigned, ...(isGroup ? { members } : { groups: selectedGroups, ...(password ? { password } : {}) }) })
    } catch (reason) { toast(message(reason), 'error') }
    finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className={`identity-dialog ${isGroup ? 'identity-group-dialog' : 'identity-user-dialog'}`}>
    <DialogHeader><DialogTitle>{isGroup ? value ? t('identities.editGroupMembers') : t('identities.addGroupMembers') : value ? t('identities.editUser') : t('identities.createUser')}</DialogTitle><DialogDescription className="sr-only">{isGroup ? t('identities.setTheGroupNameAndSelectUsers') : t('identities.setTheUserNamePasswordGroupsAndPolicy')}</DialogDescription></DialogHeader>
    <form onSubmit={event => void submit(event)} noValidate className="identity-form">
      <fieldset disabled={saving} className="identity-form-body"><FieldGroup>
        <div className={isGroup ? '' : 'identity-user-fields'}>
          <Field><FieldLabel htmlFor={`${id}-name`}>{isGroup ? t('identities.name') : t('identities.userName')}</FieldLabel><Input id={`${id}-name`} autoFocus value={name} disabled={Boolean(value)} maxLength={128} autoComplete="off" onChange={event => setName(event.target.value)} /></Field>
          {!isGroup && <Field><FieldLabel htmlFor={`${id}-password`}>{t('identities.password')}</FieldLabel><Input id={`${id}-password`} type="password" autoComplete="new-password" value={password} placeholder={value ? t('identities.leaveBlankToKeepPassword') : ''} onChange={event => setPassword(event.target.value)} /></Field>}
        </div>
        {isGroup ? <MultiChoice title={t('identities.users')} placeholder={t('identities.selectUserGroupMembers')} options={users.map(user => user.name)} selected={members} onChange={setMembers} disabled={saving} /> : <>
          <MultiChoice title={t('identities.groups')} placeholder={t('identities.selectGroup')} options={groups.map(group => group.name)} selected={selectedGroups} onChange={setSelectedGroups} disabled={saving} />
          <MultiChoice title={t('identities.policy')} placeholder={t('identities.selectUserGroupPolicies')} options={policies.map(policy => policy.name)} selected={assigned} onChange={setAssigned} disabled={saving} />
        </>}
        {value && <Field orientation="horizontal"><Checkbox id={`${id}-enabled`} checked={enabled} onCheckedChange={checked => setEnabled(checked === true)} /><FieldLabel htmlFor={`${id}-enabled`}>{t('identities.enabled')}</FieldLabel></Field>}
      </FieldGroup></fieldset>
      <footer className="identity-form-footer"><Button variant="outline" type="button" disabled={saving} onClick={onClose}>{t('identities.cancel')}</Button><Button type="submit" disabled={saving}>{saving ? t('identities.submitting') : t('identities.submit')}</Button></footer>
    </form>
  </DialogContent></Dialog>
}

function AssignmentDialog({ kind, count, options, onSave, onClose }: { kind: 'groups' | 'policies'; count: number; options: string[]; onSave: (names: string[]) => Promise<void>; onClose: () => void }) {
  const [selected, setSelected] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  const toast = useToast()
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!selected.length || saving) return
    setSaving(true)
    try { await onSave(selected) } catch (reason) { toast(message(reason), 'error') } finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog">
    <DialogHeader><DialogTitle>{kind === 'groups' ? t('identities.addToGroup') : t('identities.assignPolicy')}</DialogTitle><DialogDescription className="identity-muted">{count} {kind === 'groups' ? 'users' : 'groups'} {t('identities.selected')}</DialogDescription></DialogHeader>
    <form onSubmit={event => void submit(event)} className="identity-form"><div className="identity-form-body"><MultiChoice title={kind === 'groups' ? t('identities.groups') : t('identities.policy')} placeholder={kind === 'groups' ? t('identities.selectGroup') : t('identities.selectPolicies')} options={options} selected={selected} onChange={setSelected} disabled={saving} /></div><footer className="identity-form-footer"><Button variant="outline" type="button" disabled={saving} onClick={onClose}>{t('identities.cancel')}</Button><Button disabled={saving || !selected.length} type="submit">{saving ? t('identities.submitting') : t('identities.submit')}</Button></footer></form>
  </DialogContent></Dialog>
}
