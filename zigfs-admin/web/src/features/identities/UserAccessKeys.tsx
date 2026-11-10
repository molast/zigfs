import { t, getFormatLocale } from '@/locales'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowDown, ArrowUp, ArrowUpDown, Pencil, Plus, Trash2 } from 'lucide-react'
import type { ApiClient } from '../../api/client'
import type { AccessKey, CreatedAccessKey } from '../../types/api'
import { useConfirm } from '../../components/ConfirmProvider'
import { useToast } from '../../components/ToastProvider'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { ToolbarSearch } from '../../components/ui/ToolbarControls'
import { Badge } from '../../components/ui/Badge'
import { Checkbox } from '../../components/ui/checkbox'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '../../components/ui/select'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '../../components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import { CreateAccessKeyDialog } from '../access-keys/CreateAccessKeyDialog'
import { EditAccessKeyDialog } from '../access-keys/EditAccessKeyDialog'
import { AccessKeyCreatedDialog } from '../access-keys/AccessKeyCreatedDialog'

const errorMessage = (reason: unknown) => reason instanceof Error ? reason.message : t('identities.operationFailedPleaseTryAgain')
type SortKey = 'access_key' | 'expires_at' | 'enabled' | 'name'

export function UserAccessKeys({ api, name, enabled = true }: { api: ApiClient; name?: string; enabled?: boolean }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [keys, setKeys] = useState<AccessKey[]>([])
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<{ key: SortKey; desc: boolean }>({ key: 'access_key', desc: false })
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [creating, setCreating] = useState(false)
  const [created, setCreated] = useState<CreatedAccessKey | null>(null)
  const [editing, setEditing] = useState<AccessKey | null>(null)
  const [checked, setChecked] = useState<string[]>([])
  const [page, setPage] = useState(1)
  const [rows, setRows] = useState(10)
  const refresh = useCallback(async () => {
    setLoading(true); setFailed(false)
    try {
      const values = name ? await api.listUserAccessKeys(name) : await api.listAccessKeys()
      setKeys(values); setChecked(current => current.filter(id => values.some(key => key.id === id)))
    } catch (reason) { setFailed(true); toast(errorMessage(reason), 'error') }
    finally { setLoading(false) }
  }, [api, name, toast])
  useEffect(() => { void refresh() }, [refresh])
  const filtered = useMemo(() => keys.filter(key => [key.access_key, key.name, key.description].some(value => (value ?? '').toLowerCase().includes(query.trim().toLowerCase()))).sort((a, b) => {
    const left = a[sort.key] ?? '', right = b[sort.key] ?? ''
    const result = typeof left === 'boolean' && typeof right === 'boolean' ? Number(left) - Number(right) : String(left).localeCompare(String(right))
    return (sort.desc ? -result : result) || a.access_key.localeCompare(b.access_key)
  }), [keys, query, sort])
  const pages = Math.ceil(filtered.length / rows)
  const currentPage = pages ? Math.min(page, pages) : 0
  const visible = name ? filtered : filtered.slice(Math.max(0, currentPage - 1) * rows, currentPage * rows)
  const allChecked = visible.length > 0 && visible.every(key => checked.includes(key.id))
  const someChecked = visible.some(key => checked.includes(key.id))
  async function remove(ids: string[]) {
    if (!await confirm({ title: ids.length > 1 ? t('identities.deleteSelectedAccessKeys') : t('identities.deleteAccessKey'), message: t('identities.deleteValueAccessKeysClientsUsingTheseKeysWill', { '0': ids.length }), danger: true, confirmLabel: t('identities.delete'), cancelLabel: t('identities.cancel') })) return
    setBusy(true)
    const done: string[] = [], errors: string[] = []
    for (const id of ids) {
      try { await (name ? api.deleteUserAccessKey(name, id) : api.deleteAccessKey(id)); done.push(id) }
      catch (reason) { errors.push(`${id}: ${errorMessage(reason)}`) }
    }
    setKeys(current => current.filter(key => !done.includes(key.id)))
    setChecked(current => current.filter(id => !done.includes(id)))
    if (done.length) toast(t('identities.deletedValueAccessKeyvalue', { '0': done.length, '1': done.length > 1 ? t('identities.s') : '' }))
    if (errors.length) toast(errors.join('；'), 'error')
    setBusy(false)
  }
  function heading(label: string, key: SortKey) {
    const active = sort.key === key
    const Icon = active ? sort.desc ? ArrowDown : ArrowUp : ArrowUpDown
    return <TableHead aria-sort={active ? sort.desc ? 'descending' : 'ascending' : 'none'}><Button type="button" variant="ghost" size="sm" onClick={() => { setSort({ key, desc: active ? !sort.desc : false }); setPage(1) }}>{label}<Icon data-icon="inline-end" /></Button></TableHead>
  }
  const actions = <div className="identity-header-actions"><ToolbarSearch label={t('identities.searchAccessKey')} wrapperClassName="identity-search" placeholder={t('identities.searchAccessKey')} value={query} onChange={event => { setQuery(event.target.value); setPage(1) }} />{!name && checked.length > 0 && <Button type="button" variant="outline" disabled={busy || loading || failed} onClick={() => void remove(checked)}><Trash2 data-icon="inline-start" />{t('identities.deleteSelected')}</Button>}<Button type="button" variant="outline" disabled={!enabled || loading || busy || failed} onClick={() => setCreating(true)}><Plus data-icon="inline-start" />{t('identities.addAccessKey')}</Button></div>
  return <section className={name ? 'user-access-keys' : 'identities-page access-keys-page'}>
    {name ? <div className="group-edit-toolbar justify-end">{actions}</div> : <header className="page-header identities-header"><h2>{t('identities.accessKeys')}</h2>{actions}</header>}
    {!enabled && <p className="identity-scope-note">{t('identities.thisUserIsDisabledAndTheirAccessKeysCannot')}</p>}
    <div className={name ? 'group-edit-table user-keys-table' : 'identity-table-frame access-keys-table'} aria-busy={loading || busy}><Table><TableHeader><TableRow>
      {!name && <TableHead className="identity-check-cell"><Checkbox aria-label={t('identities.selectCurrentPage')} disabled={busy || loading || failed || !visible.length} checked={allChecked ? true : someChecked ? 'indeterminate' : false} onCheckedChange={value => setChecked(current => value === true ? [...new Set([...current, ...visible.map(key => key.id)])] : current.filter(id => !visible.some(key => key.id === id)))} /></TableHead>}
      {heading(t('common.accessKey'), 'access_key')}{heading(t('common.expiration'), 'expires_at')}{heading(t('common.status'), 'enabled')}{heading(t('common.name'), 'name')}<TableHead>{t('identities.description')}</TableHead><TableHead className="identity-actions-cell">{t('identities.actions')}</TableHead>
    </TableRow></TableHeader><TableBody>
      {!loading && !failed && visible.map(key => <TableRow key={key.id} data-state={checked.includes(key.id) ? 'selected' : undefined}>
        {!name && <TableCell className="identity-check-cell"><Checkbox aria-label={`Select ${key.access_key}`} disabled={busy} checked={checked.includes(key.id)} onCheckedChange={value => setChecked(current => value === true ? [...new Set([...current, key.id])] : current.filter(id => id !== key.id))} /></TableCell>}
        <TableCell>{key.access_key}</TableCell><TableCell>{key.expires_at ? new Date(key.expires_at).toLocaleString(getFormatLocale()) : '—'}</TableCell><TableCell><Badge>{key.expires_at && Date.parse(key.expires_at) <= Date.now() ? t('identities.expired') : !enabled ? t('identities.userDisabled') : key.enabled ? t('identities.available') : t('identities.disabled')}</Badge></TableCell><TableCell>{key.name || '—'}</TableCell><TableCell className="max-w-48 break-words whitespace-normal">{key.description || '—'}</TableCell><TableCell className="identity-actions-cell"><div className="flex items-center justify-center gap-2"><Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => setEditing(key)}><Pencil data-icon="inline-start" />{t('identities.edit')}</Button><Button type="button" variant="destructive" size="sm" disabled={busy} onClick={() => void remove([key.id])}><Trash2 data-icon="inline-start" />{t('identities.delete')}</Button></div></TableCell>
      </TableRow>)}
      {(loading || failed || !visible.length) && <TableRow><TableCell colSpan={name ? 6 : 7} className={name ? undefined : 'identity-empty-cell'}><Empty><EmptyHeader><EmptyTitle>{loading ? t('identities.loading') : failed ? t('identities.unableToLoadAccessKeys') : keys.length ? t('identities.noMatchingAccessKeys') : t('identities.noAccessKeys')}</EmptyTitle><EmptyDescription>{loading ? t('identities.loadingAccessKeys') : failed ? t('identities.retryLoadingAccessKeys') : keys.length ? t('identities.tryAnotherSearch') : t('identities.createANewAccessKeyToGetStarted')}</EmptyDescription></EmptyHeader>{failed && <Button type="button" variant="outline" onClick={() => void refresh()}>{t('identities.retry')}</Button>}</Empty></TableCell></TableRow>}
    </TableBody></Table></div>
    {!name && <footer className="identity-pagination"><div className="flex items-center gap-3"><span>{t('identities.rowsPerPage')}</span><Select value={String(rows)} onValueChange={value => { setRows(Number(value)); setPage(1) }}><SelectTrigger aria-label={t('identities.rowsPerPage')} className="identity-page-size"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{[10, 25, 50].map(count => <SelectItem key={count} value={String(count)}>{count}</SelectItem>)}</SelectGroup></SelectContent></Select></div><div className="flex items-center gap-2"><span>{t('common.pagination', { page: currentPage, total: pages })}</span>{[[t('common.first'), 1], [t('common.prev'), currentPage - 1], [t('common.next'), currentPage + 1], [t('common.last'), pages]].map(([label, target], index) => <Button type="button" key={label} variant="outline" size="sm" disabled={!pages || (index < 2 ? currentPage <= 1 : currentPage >= pages)} onClick={() => setPage(Number(target))}>{label}</Button>)}</div></footer>}
    {creating && <CreateAccessKeyDialog userName={name} onCreate={value => name ? api.createUserAccessKey(name, value) : api.createAccessKey(value)} onClose={() => setCreating(false)} onCreated={value => { setCreated(value); setCreating(false); void refresh() }} />}
    {created && <AccessKeyCreatedDialog value={created} onClose={() => setCreated(null)} />}
    {editing && <EditAccessKeyDialog key={editing.id} value={editing} userScoped={Boolean(name)} onSave={change => name ? api.updateUserAccessKey(name, editing.id, change) : api.updateAccessKey(editing.id, change)} onSaved={saved => setKeys(current => current.map(key => key.id === saved.id ? saved : key))} onClose={() => setEditing(null)} />}
  </section>
}
