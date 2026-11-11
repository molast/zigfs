import type { ApiClient } from '@/api/client'
import { Button } from '@/components/ui/Button'
import { useToast, useErrorToast } from '@/components/ToastProvider'
import { useState, useEffect, useCallback } from 'react'
import { t } from '@/locales'
import { FileText, Clock, List, RefreshCw } from 'lucide-react'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/Card'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/Input'
import { OptionSelect } from '@/components/ui/OptionSelect'

const initialDraft = {
  level: 'info', format: 'json', output: 'console', directory: '',
  retention: '7', maxSize: '100', sizeUnit: 'MiB', cleanup: 'enabled', downloads: 'enabled', range: '24h',
}

export function LogConfigurationPanel({ api }: { api: ApiClient }) {
  const [draft, setDraft] = useState(initialDraft)
  const [busy, setBusy] = useState(false)
  const [ready, setReady] = useState(false)
  const toast = useToast()
  const notifyError = useErrorToast()
  const [invalidSize, setInvalidSize] = useState(false)
  const load = useCallback(async () => {
    setBusy(true)
    try { setDraft(await api.logSettings()); setReady(true); setInvalidSize(false) }
    catch (error) { notifyError(error instanceof Error ? error.message : t('settings.logLoadFailed')) }
    finally { setBusy(false) }
  }, [api, notifyError])
  useEffect(() => { void load() }, [load])
  const save = async () => {
    if (busy || !ready) return
    if (!draft.maxSize.trim() || !Number.isFinite(Number(draft.maxSize)) || Number(draft.maxSize) <= 0) {
      setInvalidSize(true)
      notifyError(t('settings.logSizeRequired'))
      return
    }
    setInvalidSize(false)
    setBusy(true)
    try { setDraft(await api.saveLogSettings(draft)); toast(t('settings.logConfigurationSaved')) }
    catch (error) { notifyError(error instanceof Error ? error.message : t('settings.logSaveFailed')) }
    finally { setBusy(false) }
  }
  const field = (key: keyof typeof initialDraft, label: string, options: { value: string; label: string }[]) => <Field className="settings-detail-field">
    <FieldLabel htmlFor={`log-config-${key}`}>{label}</FieldLabel>
    <OptionSelect id={`log-config-${key}`} value={draft[key]} options={options} disabled={busy || !ready} onValueChange={value => setDraft(current => ({ ...current, [key]: value }))} />
  </Field>
  const enabledOptions = [{ value: 'enabled', label: t('common.enabled') }, { value: 'disabled', label: t('common.disabled') }]
  return <div className="settings-detail-stack">
    <Card className="settings-detail-card">
      <CardHeader><div className="system-settings-section-heading"><FileText aria-hidden="true" /><div><CardTitle>{t('settings.logConfiguration')}</CardTitle><CardDescription>{t('settings.systemLogLevelFormatAndDestinations')}</CardDescription></div></div></CardHeader>
      <CardContent><FieldGroup>
        {field('level', t('settings.logLevel'), ['trace', 'debug', 'info', 'warn', 'error', 'off'].map(value => ({ value, label: value.toUpperCase() })))}
        {field('format', t('settings.logFormat'), [{ value: 'json', label: 'JSON' }, { value: 'text', label: t('settings.logPlainText') }])}
        {field('output', t('settings.logOutput'), [{ value: 'console', label: t('settings.logConsole') }, { value: 'file', label: t('settings.logFile') }, { value: 'both', label: t('settings.logConsoleAndFile') }])}
        <Field className="settings-detail-field">
          <FieldLabel htmlFor="log-config-directory">{t('settings.logDirectory')}</FieldLabel>
          <div><Input id="log-config-directory" disabled={busy || !ready} placeholder="logs" value={draft.directory} aria-describedby="log-config-directory-help" onChange={event => setDraft(current => ({ ...current, directory: event.target.value }))} />
            <FieldDescription id="log-config-directory-help">{t('settings.logDirectoryDataRoot')}</FieldDescription></div>
        </Field>
      </FieldGroup></CardContent>
    </Card>
    <Card className="settings-detail-card">
      <CardHeader><div className="system-settings-section-heading"><Clock aria-hidden="true" /><div><CardTitle>{t('settings.logRetention')}</CardTitle><CardDescription>{t('settings.logRetentionPeriodAndFileSizeLimits')}</CardDescription></div></div></CardHeader>
      <CardContent><FieldGroup className="settings-field-pair">
        {field('retention', t('settings.retentionPeriod'), [{ value: 'forever', label: t('settings.logKeepForever') }, ...['1', '3', '7', '14', '30', '90'].map(value => ({ value, label: t('settings.logRetentionDays', { count: Number(value) }) }))])}
        <Field className="settings-detail-field" data-invalid={invalidSize || undefined}>
          <FieldLabel htmlFor="log-config-maxSize">{t('settings.maximumFileSize')}</FieldLabel>
          <div className="flex gap-2">
            <Input id="log-config-maxSize" disabled={busy || !ready} type="number" min="0" step="any" aria-invalid={invalidSize} value={draft.maxSize} onChange={event => { setDraft(current => ({ ...current, maxSize: event.target.value })); setInvalidSize(false) }} />
            <OptionSelect disabled={busy || !ready} aria-label={t('settings.logSizeUnit')} value={draft.sizeUnit} options={[{ value: 'KiB', label: 'KB' }, { value: 'MiB', label: 'MB' }, { value: 'GiB', label: 'GB' }]} onValueChange={value => setDraft(current => ({ ...current, sizeUnit: value }))} />
          </div>
        </Field>
        {field('cleanup', t('settings.automaticCleanup'), enabledOptions)}
      </FieldGroup></CardContent>
    </Card>
    <Card className="settings-detail-card">
      <CardHeader><div className="system-settings-section-heading"><List aria-hidden="true" /><div><CardTitle>{t('settings.logAccess')}</CardTitle><CardDescription>{t('settings.logQueriesAndDownloads')}</CardDescription></div></div></CardHeader>
      <CardContent><FieldGroup className="settings-field-pair">
        {field('downloads', t('settings.logDownloads'), enabledOptions)}
        {field('range', t('settings.queryRange'), [{ value: '1h', label: t('settings.logLastHour') }, { value: '24h', label: t('settings.logLastDay') }, { value: '7d', label: t('settings.logLastWeek') }, { value: '30d', label: t('settings.logLastMonth') }])}
      </FieldGroup></CardContent>
    </Card>
    <div className="flex justify-end gap-2">
      <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void load()}><RefreshCw data-icon="inline-start" />{t('settings.refreshConfiguration')}</Button>
      <Button type="button" size="sm" disabled={busy || !ready} onClick={() => void save()}>{t('settings.logSaveConfiguration')}</Button>
    </div>
  </div>
}
