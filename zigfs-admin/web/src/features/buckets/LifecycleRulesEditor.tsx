import { useState } from 'react'
import { Clock3, Pencil, Plus, RefreshCw, Trash2, X } from 'lucide-react'
import {
  createLifecycleRule,
  validateLifecycleRules,
  type LifecycleAction,
  type LifecycleRule,
} from './lifecycle'

interface LifecycleRulesEditorProps {
  rules: LifecycleRule[]
  configured: boolean
  loading: boolean
  onSave: (rules: LifecycleRule[]) => Promise<void>
}

export function LifecycleRulesEditor({ rules, configured, loading, onSave }: LifecycleRulesEditorProps) {
  const [draft, setDraft] = useState<LifecycleRule | null>(null)
  const [editingIndex, setEditingIndex] = useState<number | null>(null)
  const [formError, setFormError] = useState('')

  function addRule() {
    setEditingIndex(null)
    setFormError('')
    setDraft(createLifecycleRule(nextRuleId(rules)))
  }

  function editRule(index: number) {
    setEditingIndex(index)
    setFormError('')
    setDraft({ ...rules[index] })
  }

  function closeEditor() {
    setDraft(null)
    setEditingIndex(null)
    setFormError('')
  }

  async function submitRule() {
    if (!draft) return
    const next = editingIndex === null
      ? [...rules, { ...draft, id: draft.id.trim() }]
      : rules.map((rule, index) => index === editingIndex ? { ...draft, id: draft.id.trim() } : rule)
    try {
      validateLifecycleRules(next)
      setFormError('')
      await onSave(next)
      closeEditor()
    } catch (reason) {
      setFormError((reason as Error).message)
    }
  }

  async function toggleRule(index: number) {
    try {
      await onSave(rules.map((rule, ruleIndex) => ruleIndex === index ? { ...rule, enabled: !rule.enabled } : rule))
    } catch {
      // BucketDetailView renders the ZigFS error banner.
    }
  }

  async function removeRule(index: number) {
    if (!window.confirm(`删除 Lifecycle 规则“${rules[index].id}”？`)) return
    try {
      await onSave(rules.filter((_, ruleIndex) => ruleIndex !== index))
    } catch {
      // BucketDetailView renders the ZigFS error banner.
    }
  }

  return (
    <section className="lifecycle-rules">
      <div className="lifecycle-rules-header">
        <div>
          <h3>Lifecycle rules</h3>
          <p>对象过期规则由 ZigFS 后台扫描执行。</p>
        </div>
        <div className="lifecycle-rules-actions">
          <span className={`status-badge ${configured ? 'enabled' : ''}`}>{configured ? 'Configured' : 'Not configured'}</span>
          <button className="primary-button" type="button" onClick={addRule} disabled={loading || rules.length >= 1000}>
            <Plus className="button-icon" aria-hidden="true" />添加规则
          </button>
        </div>
      </div>

      {rules.length > 0 ? (
        <div className="table-wrap lifecycle-table-wrap">
          <table className="lifecycle-table">
            <thead><tr><th>Rule</th><th>Filter</th><th>Expiry</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>{rules.map((rule, index) => (
              <tr key={rule.id}>
                <td><strong>{rule.id}</strong><small>{objectVersionLabel(rule.action)}</small></td>
                <td><code>{rule.prefix || 'All objects'}</code></td>
                <td>{expiryLabel(rule)}</td>
                <td>
                  <button
                    className={`lifecycle-status-toggle${rule.enabled ? ' enabled' : ''}`}
                    type="button"
                    role="switch"
                    aria-checked={rule.enabled}
                    aria-label={`${rule.id} ${rule.enabled ? '已启用' : '已禁用'}`}
                    onClick={() => void toggleRule(index)}
                    disabled={loading}
                  ><span aria-hidden="true" />{rule.enabled ? 'Enabled' : 'Disabled'}</button>
                </td>
                <td className="table-actions">
                  <button className="icon-button" type="button" title="编辑规则" aria-label={`编辑 ${rule.id}`} onClick={() => editRule(index)} disabled={loading}><Pencil aria-hidden="true" /></button>
                  <button className="icon-button danger-icon-button" type="button" title="删除规则" aria-label={`删除 ${rule.id}`} onClick={() => void removeRule(index)} disabled={loading}><Trash2 aria-hidden="true" /></button>
                </td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      ) : (
        <div className="empty-state empty-panel lifecycle-empty">
          <Clock3 aria-hidden="true" />
          <strong>尚未配置 Lifecycle</strong>
          <span>添加第一条对象过期规则。</span>
        </div>
      )}

      {draft && (
        <div className="modal-backdrop" role="presentation" onMouseDown={closeEditor}>
          <section className="lifecycle-modal" role="dialog" aria-modal="true" aria-labelledby="lifecycle-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><RefreshCw aria-hidden="true" /><h3 id="lifecycle-dialog-title">{editingIndex === null ? 'Add Lifecycle Rule' : 'Edit Lifecycle Rule'}</h3></div>
              <button className="icon-button" type="button" aria-label="关闭" onClick={closeEditor}><X aria-hidden="true" /></button>
            </header>

            <div className="lifecycle-form">
              <label className="lifecycle-field lifecycle-field-wide">
                <span>Rule ID</span>
                <input value={draft.id} maxLength={255} onChange={(event) => setDraft({ ...draft, id: event.target.value })} autoFocus />
              </label>

              <div className="lifecycle-field lifecycle-field-wide lifecycle-status-field">
                <span>Status</span>
                <button
                  className={`lifecycle-status-toggle${draft.enabled ? ' enabled' : ''}`}
                  type="button"
                  role="switch"
                  aria-checked={draft.enabled}
                  onClick={() => setDraft({ ...draft, enabled: !draft.enabled })}
                ><span aria-hidden="true" />{draft.enabled ? 'Enabled' : 'Disabled'}</button>
              </div>

              <fieldset className="lifecycle-rule-type lifecycle-field-wide">
                <legend>Rule type</legend>
                <label><input type="radio" name="lifecycle-type" checked readOnly />Expiry</label>
                <label className="disabled-option" title="ZigFS 暂未实现 Transition"><input type="radio" name="lifecycle-type" disabled />Transition</label>
              </fieldset>

              <label className="lifecycle-field lifecycle-field-wide">
                <span>Object version</span>
                <select value={draft.action} onChange={(event) => setDraft({ ...draft, action: event.target.value as LifecycleAction })}>
                  <option value="current-days">Current version · after days</option>
                  <option value="current-date">Current version · on date</option>
                  <option value="noncurrent-days">Non-current version</option>
                  <option value="delete-marker">Expired delete marker</option>
                </select>
              </label>

              {draft.action === 'current-date' ? (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>Expire on</span>
                  <input type="date" value={draft.expirationDate} onChange={(event) => setDraft({ ...draft, expirationDate: event.target.value })} />
                </label>
              ) : draft.action !== 'delete-marker' ? (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>{draft.action === 'noncurrent-days' ? 'Non-current expiration' : 'Expire after'}</span>
                  <div className="input-with-suffix"><input type="number" min={1} step={1} value={draft.days} onChange={(event) => setDraft({ ...draft, days: Number(event.target.value) })} /><span>days</span></div>
                </label>
              ) : null}

              <label className="lifecycle-field lifecycle-field-wide">
                <span>Prefix filter</span>
                <input value={draft.prefix} placeholder="All objects" onChange={(event) => setDraft({ ...draft, prefix: event.target.value })} />
              </label>

              {draft.action === 'noncurrent-days' && (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>Keep newest non-current versions (optional)</span>
                  <input
                    type="number"
                    min={1}
                    step={1}
                    value={draft.newerNoncurrentVersions ?? ''}
                    placeholder="Not set"
                    onChange={(event) => setDraft({
                      ...draft,
                      newerNoncurrentVersions: event.target.value ? Number(event.target.value) : undefined,
                    })}
                  />
                </label>
              )}
            </div>

            {formError && <p className="form-error lifecycle-form-error">{formError}</p>}
            <footer className="lifecycle-modal-actions">
              <button className="secondary-button" type="button" onClick={closeEditor} disabled={loading}>取消</button>
              <button className="primary-button" type="button" onClick={() => void submitRule()} disabled={loading}>{loading ? '保存中...' : '保存'}</button>
            </footer>
          </section>
        </div>
      )}
    </section>
  )
}

function nextRuleId(rules: LifecycleRule[]) {
  let index = rules.length + 1
  while (rules.some((rule) => rule.id === `expiry-rule-${index}`)) index += 1
  return `expiry-rule-${index}`
}

function objectVersionLabel(action: LifecycleAction) {
  switch (action) {
    case 'current-days':
    case 'current-date': return 'Current version'
    case 'noncurrent-days': return 'Non-current version'
    case 'delete-marker': return 'DeleteMarker'
  }
}

function expiryLabel(rule: LifecycleRule) {
  switch (rule.action) {
    case 'current-days': return `After ${rule.days} days`
    case 'current-date': return `On ${rule.expirationDate}`
    case 'noncurrent-days': return `After ${rule.days} non-current days${rule.newerNoncurrentVersions ? ` · keep ${rule.newerNoncurrentVersions}` : ''}`
    case 'delete-marker': return 'When expired'
  }
}
