import { t } from '@/locales'
import { useErrorToast } from '../../components/ToastProvider'
import { useState } from 'react'
import { Clock3, Pencil, Plus, RefreshCw, Trash2, X } from 'lucide-react'
import {
  createLifecycleRule,
  validateLifecycleRules,
  type LifecycleAction,
  type LifecycleRule,
} from './lifecycle'
import { useConfirm } from '../../components/ConfirmProvider'

interface LifecycleRulesEditorProps {
  rules: LifecycleRule[]
  configured: boolean
  loading: boolean
  onSave: (rules: LifecycleRule[]) => Promise<void>
}

export function LifecycleRulesEditor({ rules, configured, loading, onSave }: LifecycleRulesEditorProps) {
  const confirm = useConfirm()
  const [draft, setDraft] = useState<LifecycleRule | null>(null)
  const [editingIndex, setEditingIndex] = useState<number | null>(null)
  const notifyError = useErrorToast()

  function addRule() {
    setEditingIndex(null)
    setDraft(createLifecycleRule(nextRuleId(rules)))
  }

  function editRule(index: number) {
    setEditingIndex(index)
    setDraft({ ...rules[index] })
  }

  function closeEditor() {
    setDraft(null)
    setEditingIndex(null)
  }

  async function submitRule() {
    if (!draft) return
    const next = editingIndex === null
      ? [...rules, { ...draft, id: draft.id.trim() }]
      : rules.map((rule, index) => index === editingIndex ? { ...draft, id: draft.id.trim() } : rule)
    try {
      validateLifecycleRules(next)
      await onSave(next)
      closeEditor()
    } catch (reason) {
      notifyError((reason as Error).message)
    }
  }

  async function toggleRule(index: number) {
    try {
      await onSave(rules.map((rule, ruleIndex) => ruleIndex === index ? { ...rule, enabled: !rule.enabled } : rule))
    } catch {
      // BucketDetailView reports the ZigFS error through a toast.
    }
  }

  async function removeRule(index: number) {
    if (!await confirm({
      title: t('buckets.deleteLifecycleRule'),
      message: t('buckets.deleteLifecycleRuleValueThisCannotBeUndone', { '0': rules[index].id }),
      confirmLabel: t('buckets.delete'),
      danger: true,
    })) return
    try {
      await onSave(rules.filter((_, ruleIndex) => ruleIndex !== index))
    } catch {
      // BucketDetailView reports the ZigFS error through a toast.
    }
  }

  return (
    <section className="lifecycle-rules">
      <div className="lifecycle-rules-header">
        <div>
          <h3>{t('buckets.lifecycleRules')}</h3>
          <p>{t('buckets.objectExpirationRulesRunThroughTheZigfsBackgroundScanner')}</p>
        </div>
        <div className="lifecycle-rules-actions">
          <span className={`status-badge ${configured ? 'enabled' : ''}`}>{configured ? t('buckets.configured') : t('buckets.notConfigured')}</span>
          <button className="primary-button" type="button" onClick={addRule} disabled={loading || rules.length >= 1000}>
            <Plus className="button-icon" aria-hidden="true" />{t('buckets.addRule')}</button>
        </div>
      </div>

      {rules.length > 0 ? (
        <div className="table-wrap lifecycle-table-wrap">
          <table className="lifecycle-table">
            <thead><tr><th>{t('buckets.rule')}</th><th>{t('buckets.filter')}</th><th>{t('buckets.expiry')}</th><th>{t('buckets.status')}</th><th>{t('buckets.actions')}</th></tr></thead>
            <tbody>{rules.map((rule, index) => (
              <tr key={rule.id}>
                <td><strong>{rule.id}</strong><small>{objectVersionLabel(rule.action)}</small></td>
                <td><code>{rule.prefix || t('buckets.allObjects')}</code></td>
                <td>{expiryLabel(rule)}</td>
                <td>
                  <button
                    className={`lifecycle-status-toggle${rule.enabled ? ' enabled' : ''}`}
                    type="button"
                    role="switch"
                    aria-checked={rule.enabled}
                    aria-label={`${rule.id} ${rule.enabled ? t('buckets.enabled') : t('buckets.disabled')}`}
                    onClick={() => void toggleRule(index)}
                    disabled={loading}
                  ><span aria-hidden="true" />{rule.enabled ? t('buckets.enabled') : t('buckets.disabled')}</button>
                </td>
                <td className="table-actions">
                  <button className="icon-button" type="button" title={t('buckets.editRule')} aria-label={t('buckets.editValue', { '0': rule.id })} onClick={() => editRule(index)} disabled={loading}><Pencil aria-hidden="true" /></button>
                  <button className="icon-button danger-icon-button" type="button" title={t('buckets.deleteRule')} aria-label={t('buckets.deleteValue', { '0': rule.id })} onClick={() => void removeRule(index)} disabled={loading}><Trash2 aria-hidden="true" /></button>
                </td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      ) : (
        <div className="empty-state empty-panel lifecycle-empty">
          <Clock3 aria-hidden="true" />
          <strong>{t('buckets.noLifecycleRulesConfigured')}</strong>
          <span>{t('buckets.addYourFirstObjectExpirationRule')}</span>
        </div>
      )}

      {draft && (
        <div className="modal-backdrop" role="presentation" onMouseDown={closeEditor}>
          <section className="lifecycle-modal" role="dialog" aria-modal="true" aria-labelledby="lifecycle-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><RefreshCw aria-hidden="true" /><h3 id="lifecycle-dialog-title">{editingIndex === null ? t('buckets.addLifecycleRule') : t('buckets.editLifecycleRule')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('buckets.close')} onClick={closeEditor}><X aria-hidden="true" /></button>
            </header>

            <div className="lifecycle-form">
              <label className="lifecycle-field lifecycle-field-wide">
                <span>{t('buckets.ruleId')}</span>
                <input value={draft.id} maxLength={255} onChange={(event) => setDraft({ ...draft, id: event.target.value })} autoFocus />
              </label>

              <div className="lifecycle-field lifecycle-field-wide lifecycle-status-field">
                <span>{t('buckets.status')}</span>
                <button
                  className={`lifecycle-status-toggle${draft.enabled ? ' enabled' : ''}`}
                  type="button"
                  role="switch"
                  aria-checked={draft.enabled}
                  onClick={() => setDraft({ ...draft, enabled: !draft.enabled })}
                ><span aria-hidden="true" />{draft.enabled ? t('buckets.enabled') : t('buckets.disabled')}</button>
              </div>

              <fieldset className="lifecycle-rule-type lifecycle-field-wide">
                <legend>{t('buckets.ruleType')}</legend>
                <label><input type="radio" name="lifecycle-type" checked readOnly />{t('buckets.expiry')}</label>
                <label className="disabled-option" title={t('buckets.transitionsAreNotSupportedYet')}><input type="radio" name="lifecycle-type" disabled />{t('buckets.transition')}</label>
              </fieldset>

              <label className="lifecycle-field lifecycle-field-wide">
                <span>{t('buckets.objectVersion')}</span>
                <select value={draft.action} onChange={(event) => setDraft({ ...draft, action: event.target.value as LifecycleAction })}>
                  <option value="current-days">{t('buckets.currentVersionAfterDays')}</option>
                  <option value="current-date">{t('buckets.currentVersionOnDate')}</option>
                  <option value="noncurrent-days">{t('buckets.nonCurrentVersion')}</option>
                  <option value="delete-marker">{t('buckets.expiredDeleteMarker')}</option>
                </select>
              </label>

              {draft.action === 'current-date' ? (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>{t('buckets.expireOn')}</span>
                  <input type="date" value={draft.expirationDate} onChange={(event) => setDraft({ ...draft, expirationDate: event.target.value })} />
                </label>
              ) : draft.action !== 'delete-marker' ? (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>{draft.action === 'noncurrent-days' ? t('buckets.nonCurrentExpiration') : t('buckets.expireAfter')}</span>
                  <div className="input-with-suffix"><input type="number" min={1} step={1} value={draft.days} onChange={(event) => setDraft({ ...draft, days: Number(event.target.value) })} /><span>{t('buckets.days')}</span></div>
                </label>
              ) : null}

              <label className="lifecycle-field lifecycle-field-wide">
                <span>{t('buckets.prefixFilter')}</span>
                <input value={draft.prefix} placeholder={t('buckets.allObjects')} onChange={(event) => setDraft({ ...draft, prefix: event.target.value })} />
              </label>

              {draft.action === 'noncurrent-days' && (
                <label className="lifecycle-field lifecycle-field-wide">
                  <span>{t('buckets.keepNewestNonCurrentVersionsOptional')}</span>
                  <input
                    type="number"
                    min={1}
                    step={1}
                    value={draft.newerNoncurrentVersions ?? ''}
                    placeholder={t('buckets.notSet')}
                    onChange={(event) => setDraft({
                      ...draft,
                      newerNoncurrentVersions: event.target.value ? Number(event.target.value) : undefined,
                    })}
                  />
                </label>
              )}
            </div>
            <footer className="lifecycle-modal-actions">
              <button className="secondary-button" type="button" onClick={closeEditor} disabled={loading}>{t('buckets.cancel')}</button>
              <button className="primary-button" type="button" onClick={() => void submitRule()} disabled={loading}>{t('buckets.save')}</button>
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
    case 'current-date': return t('buckets.currentVersion')
    case 'noncurrent-days': return t('buckets.nonCurrentVersion')
    case 'delete-marker': return t('buckets.deletemarker')
  }
}

function expiryLabel(rule: LifecycleRule) {
  switch (rule.action) {
    case 'current-days': return t('buckets.afterValueDays', { '0': rule.days })
    case 'current-date': return t('buckets.onValue', { '0': rule.expirationDate })
    case 'noncurrent-days': return t('buckets.afterValueNonCurrentDaysvalue', { '0': rule.days, '1': rule.newerNoncurrentVersions ? ` · keep ${rule.newerNoncurrentVersions}` : '' })
    case 'delete-marker': return t('buckets.whenExpired')
  }
}
