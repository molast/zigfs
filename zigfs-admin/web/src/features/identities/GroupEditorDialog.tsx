import { useEffect, useId, useState } from 'react'
import { Plus, Search } from 'lucide-react'
import type { ApiClient, ManagedGroup, ManagedPolicy, ManagedUser } from '../../api/client'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../../components/ui/Tabs'
import { Switch } from '../../components/ui/switch'
import { Field, FieldLabel } from '../../components/ui/field'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '../../components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import { MultiChoice } from './IdentityMultiChoice'

type Section = 'members' | 'policies'

export function GroupEditorDialog({ api, initialGroup, users, policies, onSaved, onClose }: {
  api: ApiClient
  initialGroup: ManagedGroup
  users: ManagedUser[]
  policies: ManagedPolicy[]
  onSaved: (group: ManagedGroup) => void
  onClose: () => void
}) {
  const id = useId()
  const toast = useToast()
  const [group, setGroup] = useState(initialGroup)
  const [tab, setTab] = useState<Section>('members')
  const [query, setQuery] = useState('')
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let active = true
    setLoading(true); setFailed(false)
    void api.getGroup(initialGroup.name).then(value => {
      if (active) setGroup(value)
    }).catch(reason => {
      if (active) { setFailed(true); toast(reason instanceof Error ? reason.message : '加载用户组失败', 'error') }
    }).finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [api, initialGroup.name, reload, toast])

  async function update(change: Partial<Pick<ManagedGroup, 'enabled' | 'members' | 'policies'>>) {
    if (saving) return
    setSaving(true)
    try {
      // Merge only the edited field into the latest server record.
      const latest = await api.getGroup(group.name)
      const saved = await api.updateGroup({ ...latest, ...change })
      setGroup(saved); onSaved(saved); setEditing(false)
      toast('Group updated')
    } catch (reason) { toast(reason instanceof Error ? reason.message : '更新用户组失败', 'error') }
    finally { setSaving(false) }
  }
  const disabled = saving || loading || failed
  const names = group[tab].filter(name => name.toLowerCase().includes(query.trim().toLowerCase())).sort()

  return <Dialog open onOpenChange={open => { if (!open && !saving) onClose() }}><DialogContent className="identity-dialog group-edit-dialog" aria-busy={loading || saving}>
    <DialogHeader><DialogTitle>{group.name}</DialogTitle><DialogDescription className="sr-only">Manage group status, members and policies.</DialogDescription></DialogHeader>
    <div className="group-edit-body">
      <Field orientation="horizontal" className="group-status-field"><FieldLabel htmlFor={`${id}-status`}>Status</FieldLabel><Switch id={`${id}-status`} checked={group.enabled} disabled={disabled || editing} onCheckedChange={enabled => void update({ enabled })} /></Field>
      <Tabs value={tab} onValueChange={value => { setTab(value as Section); setQuery(''); setEditing(false) }}>
        <TabsList aria-label="Group sections" className="group-edit-tabs"><TabsTrigger value="members" disabled={saving}>Members</TabsTrigger><TabsTrigger value="policies" disabled={saving}>Policies</TabsTrigger></TabsList>
        {(['members', 'policies'] as const).map(section => <TabsContent value={section} key={section}>
          {editing ? <form onSubmit={event => { event.preventDefault(); void update({ [section]: draft }) }} className="group-selection-form">
            <MultiChoice title={section === 'members' ? 'Users' : 'Policies'} placeholder={section === 'members' ? 'Select user group members' : 'Select policies'} options={(section === 'members' ? users : policies).map(item => item.name)} selected={draft} onChange={setDraft} disabled={saving} />
            <div className="flex justify-end gap-2"><Button type="button" variant="outline" disabled={saving} onClick={() => setEditing(false)}>Cancel</Button><Button type="submit" disabled={saving}>{saving ? 'Saving…' : 'Save'}</Button></div>
          </form> : <>
            <div className="group-edit-toolbar"><div className="identity-search"><Search aria-hidden="true" /><Input aria-label={section === 'members' ? 'Search User' : 'Search Policy'} placeholder={section === 'members' ? 'Search User' : 'Search Policy'} value={query} onChange={event => setQuery(event.target.value)} /></div><Button variant="outline" disabled={disabled} onClick={() => { setDraft([...group[section]]); setEditing(true) }}><Plus />{section === 'members' ? 'Edit User' : 'Edit Policy'}</Button></div>
            <div className="group-edit-table"><Table><TableHeader><TableRow><TableHead>Name</TableHead></TableRow></TableHeader><TableBody>
              {!loading && !failed && names.map(name => <TableRow key={name}><TableCell>{name}</TableCell></TableRow>)}
              {(loading || failed || !names.length) && <TableRow><TableCell><Empty><EmptyHeader><EmptyTitle>{loading ? 'Loading…' : failed ? 'Unable to load group' : 'No data'}</EmptyTitle><EmptyDescription>{loading ? 'Loading group details.' : failed ? 'Please retry.' : query ? 'No matching results.' : 'There is nothing to display yet.'}</EmptyDescription></EmptyHeader>{failed && <Button variant="outline" onClick={() => setReload(value => value + 1)}>Retry</Button>}</Empty></TableCell></TableRow>}
            </TableBody></Table></div>
          </>}
        </TabsContent>)}
      </Tabs>
    </div>
    <footer className="identity-form-footer"><Button variant="outline" disabled={saving} onClick={onClose}>Close</Button></footer>
  </DialogContent></Dialog>
}
