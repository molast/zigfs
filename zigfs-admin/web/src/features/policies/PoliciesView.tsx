import { t } from '@/locales'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowDownUp, ArrowLeft, ChevronLeft, ChevronRight, Copy, Eraser, RefreshCw, Shield, Trash2 } from 'lucide-react'
import { Badge } from '../../components/ui/Badge'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { ToolbarControls, ToolbarCreateButton, ToolbarSearch } from '../../components/ui/ToolbarControls'
import { useConfirm } from '../../components/ConfirmProvider'

import type { ApiClient } from '../../api/client'
import { useLoading } from '../../components/LoadingProvider'
import { useToast } from '../../components/ToastProvider'

interface Policy { name: string; document: string }

export function PoliciesView({ api }: { api: ApiClient }) {
  const confirm = useConfirm()
  const { withLoading } = useLoading()
  const toast = useToast()
  const [policies, setPolicies] = useState<Policy[]>([])
  const refreshList = useCallback(async () => {
    try {
      setPolicies(await withLoading(t('policies.loadingPolicies'), () => api.listPolicies()))
    } catch (reason) { toast(policyError(reason), 'error') }
  }, [api, withLoading, toast])
  useEffect(() => { void refreshList() }, [refreshList])
  const [query, setQuery] = useState('')
  const [rowsPerPage, setRowsPerPage] = useState(10)
  const [sortAscending, setSortAscending] = useState(true)
  const [page, setPage] = useState(1)
  const [selected, setSelected] = useState<Policy | null>(null)
  const [draftDocument, setDraftDocument] = useState('')
  const [detailTab, setDetailTab] = useState<'summary' | 'users' | 'groups' | 'raw'>('summary')
  const [creating, setCreating] = useState(false)

  const filteredPolicies = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return policies.filter((policy) => !needle || policy.name.toLowerCase().includes(needle)).sort((a, b) => sortAscending ? a.name.localeCompare(b.name) : b.name.localeCompare(a.name))
  }, [policies, query, sortAscending])
  const pageCount = Math.max(1, Math.ceil(filteredPolicies.length / rowsPerPage))
  const currentPage = Math.min(page, pageCount)
  const visiblePolicies = filteredPolicies.slice((currentPage - 1) * rowsPerPage, currentPage * rowsPerPage)

  function openCreate() {
    setCreating(true)
  }
  async function removePolicy(policy: Policy) {
    if (!await confirm({ title: t('policies.deletePolicy'), message: t('policies.areYouSureYouWantToDeletePolicyValue', { '0': policy.name }), confirmLabel: t('policies.delete'), cancelLabel: t('policies.cancel'), danger: true })) return false
    try {
      await withLoading(t('policies.deletingPolicy'), () => api.deletePolicy(policy.name))
      setPolicies((current) => current.filter((item) => item.name !== policy.name))
      toast(t('policies.policyDeleted'))
      return true
    } catch (reason) { toast(policyError(reason), 'error'); return false }
  }
  async function openPolicy(policy: Policy) {
    try {
      const next = await withLoading(t('policies.loadingPolicy'), () => api.getPolicy(policy.name))
      setSelected(next)
      setDraftDocument(next.document)
      setDetailTab('summary')
    } catch (reason) { toast(policyError(reason), 'error') }
  }
  async function savePolicy() {
    if (!selected) return
    validateDocument(draftDocument)
    const saved = await withLoading(t('policies.savingPolicy'), () => api.updatePolicy({ name: selected.name, document: draftDocument }))
    setSelected(saved)
    setPolicies((items) => items.map((item) => item.name === saved.name ? saved : item))
    toast(t('policies.policySaved'))
  }
  async function refreshPolicy() {
    if (!selected) return
    try {
      const saved = await withLoading(t('policies.refreshingPolicy'), () => api.getPolicy(selected.name))
      setSelected(saved)
      setDraftDocument(saved.document)
    } catch (reason) { toast(policyError(reason), 'error') }
  }

  if (selected) return <PolicyDetail api={api} policy={selected} tab={detailTab} setTab={setDetailTab} onSave={savePolicy} onRefresh={refreshPolicy} document={draftDocument} setDocument={setDraftDocument} onBack={() => setSelected(null)} onDelete={async () => { if (await removePolicy(selected)) setSelected(null) }} />
  if (creating) return <CreatePolicy onCancel={() => setCreating(false)} onSave={async (policy) => { const saved = await withLoading(t('policies.creatingPolicy'), () => api.createPolicy(policy)); setPolicies((current) => [...current, saved]); setCreating(false); setSelected(saved); setDraftDocument(saved.document); setDetailTab('summary') }} />

  return (
    <section className="policies-page">
      <header className="page-header policies-header">
        <h2>{t('policies.iamPolicies')}</h2>
        <ToolbarControls className="policies-header-actions">
          <ToolbarSearch label={t('policies.searchPolicies')} value={query} onChange={(event) => { setQuery(event.target.value); setPage(1) }} placeholder={t('policies.search')} />
          <ToolbarCreateButton label={t('policies.newPolicy')} onClick={openCreate} />
        </ToolbarControls>
      </header>
      <Card className="panel table-panel policies-panel">
        <div className="table-wrap"><table><thead><tr>
          <th><button className="policy-sort-button" type="button" onClick={() => setSortAscending((current) => !current)}>{t('policies.name')} <ArrowDownUp aria-hidden="true" /></button></th>
          <th className="policy-actions-heading">{t('policies.actions')}</th>
        </tr></thead><tbody>
          {visiblePolicies.map((policy) => <tr key={policy.name} className="policy-row" onClick={() => void openPolicy(policy)}><td>{policy.name}</td><td><div className="table-actions policy-actions"><Button variant="destructive" size="sm" type="button" onClick={(event) => { event.stopPropagation(); void removePolicy(policy) }}><Trash2 data-icon="inline-start" aria-hidden="true" />{t('policies.delete')}</Button></div></td></tr>)}
          {visiblePolicies.length === 0 && <tr><td colSpan={2} className="policies-empty">{t('policies.noPoliciesFound')}</td></tr>}
        </tbody></table></div>
        <footer className="policies-pagination">
          <label>{t('policies.rowsPerPage')}<select value={rowsPerPage} onChange={(event) => { setRowsPerPage(Number(event.target.value)); setPage(1) }}><option value={10}>10</option><option value={25}>25</option><option value={50}>50</option></select></label>
          <div className="pagination-controls"><span>{t('policies.page')} {currentPage} {t('policies.of')} {pageCount}</span><button className="icon-button" type="button" aria-label={t('policies.previousPage')} disabled={currentPage === 1} onClick={() => setPage((current) => Math.max(1, current - 1))}><ChevronLeft aria-hidden="true" /></button><button className="icon-button" type="button" aria-label={t('policies.nextPage')} disabled={currentPage === pageCount} onClick={() => setPage((current) => Math.min(pageCount, current + 1))}><ChevronRight aria-hidden="true" /></button></div>
        </footer>
      </Card>
    </section>
  )
}

function CreatePolicy({ onCancel, onSave }: { onCancel: () => void; onSave: (policy: Policy) => Promise<void> }) {
  const toast = useToast()
  const [name, setName] = useState('')
  const [document, setDocument] = useState(JSON.stringify({ Version: '2012-10-17', Statement: [] }, null, 2))
  const [saving, setSaving] = useState(false)
  async function save() {
    const trimmedName = name.trim()
    if (!trimmedName) { toast(t('policies.policyNameIsRequired'), 'error'); return }
    try { validateDocument(document) } catch (reason) { toast(policyError(reason), 'error'); return }
    setSaving(true)
    try { await onSave({ name: trimmedName, document }) }
    catch (reason) { toast(policyError(reason), 'error') }
    finally { setSaving(false) }
  }
  return <Dialog open onOpenChange={(open) => { if (!open) onCancel() }}><DialogContent className="policy-create-page">
    <DialogHeader className="policy-create-heading"><div><Shield aria-hidden="true" /><DialogTitle>{t('policies.createPolicy')}</DialogTitle></div></DialogHeader>
    <div className="policy-create-form">
      <label>{t('policies.policyName')}<Input autoFocus value={name} onChange={(event) => setName(event.target.value)} /></label>
      <label>{t('policies.writePolicy')}<Textarea value={document} onChange={(event) => setDocument(event.target.value)} spellCheck={false} /></label>
      <div className="policy-create-actions"><Button variant="outline" type="button" onClick={() => setDocument('')}><Eraser className="button-icon" aria-hidden="true" />{t('policies.clear')}</Button><Button type="button" disabled={saving} onClick={() => void save()}>{t('policies.save')}</Button></div>
    </div>
  </DialogContent></Dialog>
}

function PolicyDetail({ api, policy, tab, setTab, document, setDocument, onBack, onDelete, onSave, onRefresh }: { api: ApiClient; onSave: () => Promise<void>; onRefresh: () => Promise<void>; policy: Policy; tab: 'summary' | 'users' | 'groups' | 'raw'; setTab: (tab: 'summary' | 'users' | 'groups' | 'raw') => void; document: string; setDocument: (document: string) => void; onBack: () => void; onDelete: () => void | Promise<void> }) {
  const statements = readStatements(document)
  const [statementQuery, setStatementQuery] = useState('')
  const normalizedStatementQuery = statementQuery.trim().toLocaleLowerCase()
  const visibleStatements = normalizedStatementQuery ? statements.filter(statement => JSON.stringify(statement).toLocaleLowerCase().includes(normalizedStatementQuery)) : statements
  const toast = useToast()
  const [saving, setSaving] = useState(false)
  async function save() {
    setSaving(true)
    try { await onSave() } catch (reason) { toast(policyError(reason), 'error') }
    finally { setSaving(false) }
  }
  return <section className="policy-detail-page">
    <button className="policy-back-button" type="button" onClick={onBack}><ArrowLeft aria-hidden="true" /> <span>{t('policies.policy')}</span></button>
    <header className="policy-detail-header"><div className="policy-detail-identity"><Shield aria-hidden="true" /><div><h2>{policy.name}</h2><p>{t('policies.iamPolicy')}</p></div></div><div className="policy-detail-actions"><button className="danger-button" type="button" onClick={onDelete}><Trash2 className="button-icon" aria-hidden="true" />{t('policies.deletePolicy')}</button><button className="secondary-button" type="button" onClick={() => void onRefresh()}><RefreshCw className="button-icon" aria-hidden="true" />{t('policies.refresh')}</button></div></header>
    <div className="policy-detail-shell"><nav className="policy-detail-tabs" aria-label={t('policies.policySections')}>{([['summary', t('common.summary')], ['users', t('common.users')], ['groups', t('common.groups')], ['raw', t('common.rawPolicy')]] as const).map(([value, label]) => <button key={value} className={tab === value ? 'active' : ''} type="button" onClick={() => setTab(value)}>{label}</button>)}</nav><main className="policy-detail-content">
      {tab === 'summary' && <><h3>{t('policies.policySummary')}</h3><div className="policy-statements"><div className="policy-statements-heading"><strong>{t('policies.statements')}</strong><ToolbarSearch label={t('policies.search')} placeholder={t('policies.search')} value={statementQuery} onChange={event => setStatementQuery(event.target.value)} /></div>{visibleStatements.map((statement, index) => <Statement key={index} effect={statement.Effect} actions={statement.Action ?? statement.NotAction ?? []} resources={statement.Resource ?? statement.NotResource} notAction={Boolean(statement.NotAction)} notResource={Boolean(statement.NotResource)} />)}{normalizedStatementQuery && visibleStatements.length === 0 && <p className="policy-statements-empty">{t('policies.noMatchingStatements')}</p>}</div></>}
      {tab === 'users' && <><h3>{t('policies.users')}</h3><PolicyAssignments api={api} name={policy.name} kind="users" /></>}
      {tab === 'groups' && <><h3>{t('policies.groups')}</h3><PolicyAssignments api={api} name={policy.name} kind="groups" /></>}
      {tab === 'raw' && <><h3>{t('policies.rawPolicy')}</h3><div className="raw-policy-wrap"><Textarea aria-label={t('policies.policyJson')} value={document} onChange={(event) => setDocument(event.target.value)} spellCheck={false} /><button className="icon-button raw-copy" type="button" aria-label={t('policies.copyPolicy')} onClick={() => void navigator.clipboard?.writeText(document)}><Copy aria-hidden="true" /></button></div><Button className="raw-save" type="button" disabled={saving} onClick={() => void save()}>{t('policies.save')}</Button></>}
    </main></div>
  </section>
}

function readStatements(document: string): Array<{ Effect: string; Action?: string | string[]; NotAction?: string | string[]; Resource?: string | string[]; NotResource?: string | string[] }> {
  try {
    const value = JSON.parse(document) as { Statement?: unknown }
    const statements = Array.isArray(value.Statement) ? value.Statement : [value.Statement]
    return statements.filter((item): item is { Effect: string; Action?: string | string[]; NotAction?: string | string[]; Resource?: string | string[]; NotResource?: string | string[] } => Boolean(item && typeof item === 'object' && 'Effect' in item && ('Action' in item || 'NotAction' in item)))
  } catch {
    return []
  }
}

function Statement({ effect, actions, resources, notAction, notResource }: { effect: string; actions: string | string[]; resources?: string | string[]; notAction: boolean; notResource: boolean }) {
  const actionText = Array.isArray(actions) ? actions.join(', ') : actions
  const resourceText = resources ? (Array.isArray(resources) ? resources.join(', ') : resources) : t('policies.allResources')
  return <div className="policy-statement"><div><b>{t('policies.effect')}</b><span><span className={effect === 'Allow' ? 'policy-allow' : 'policy-deny'}>●</span> {effect}</span></div><div><b>{notAction ? t('policies.notaction') : t('policies.actionsLabel')}</b><span>{actionText}</span></div><div><b>{notResource ? t('policies.notresource') : t('policies.resources')}</b><span>{resourceText}</span></div></div>
}

function validateDocument(document: string) {
  const value = JSON.parse(document)
  if (!value || typeof value !== 'object' || value.Version !== '2012-10-17' || (!value.Statement || typeof value.Statement !== 'object')) {
    throw new Error(t('policies.policyMustIncludeVersion20121017AndA'))
  }
}

function policyError(reason: unknown): string {
  if (reason instanceof SyntaxError) {
    const location = reason.message.match(/line (\d+) column (\d+)/)
    const position = location ? t('policies.lineValueColumnValue', { '0': location[1], '1': location[2] }) : ''
    return t('policies.invalidJsonValueCheckQuotesCommasAndUnescapedNewlines', { '0': position })
  }
  return reason instanceof Error ? reason.message : t('policies.operationFailedPleaseTryAgain')
}

function PolicyAssignments({ api, name, kind }: { api: ApiClient; name: string; kind: 'users' | 'groups' }) {
  const toast = useToast()
  const [names, setNames] = useState<string[] | null>(null)
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    let active = true
    setNames(null)
    setFailed(false)
    const load = kind === 'users' ? api.listUsers() : api.listGroups()
    void load.then(items => {
      if (active) setNames(items.filter(item => item.policies.includes(name)).map(item => item.name))
    }).catch(reason => { if (active) { setFailed(true); toast(policyError(reason), 'error') } })
    return () => { active = false }
  }, [api, name, kind, toast])
  if (failed) return <p className="policy-muted">{t('policies.assignmentsUnavailableSwitchTabsToRetry')}</p>
  if (!names) return <p className="policy-muted">{t('policies.loadingAssignments')}</p>
  if (!names.length) return <p className="policy-muted">{t(kind === 'users' ? 'policies.noUserAssignments' : 'policies.noGroupAssignments')}</p>
  return <div className="flex flex-wrap gap-2">{names.map(value => <Badge key={value}>{value}</Badge>)}</div>
}
