import { useState } from 'react'
import type { ApiClient, LogQuery } from '@/api/client'
import { t } from '@/locales'
import { Button } from '@/components/ui/Button'
import { Textarea } from '@/components/ui/Textarea'
import { Field, FieldLabel, FieldDescription } from '@/components/ui/field'
import { useErrorToast } from '@/components/ToastProvider'

export function LogAccessPanel({ api }: { api: ApiClient }) {
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<LogQuery | null>(null)
  const notifyError = useErrorToast()
  const read = async (download: boolean) => {
    if (busy) return
    setBusy(true)
    try {
      const next = await api.queryLogs(download)
      setResult(next)
      if (download) {
        const url = URL.createObjectURL(new Blob([next.content], { type: 'text/plain;charset=utf-8' }))
        const link = document.createElement('a')
        link.href = url; link.download = 'zigfs.log'; link.click()
        setTimeout(() => URL.revokeObjectURL(url), 1000)
      }
    } catch (error) { notifyError(error instanceof Error ? error.message : t('settings.logQueryFailed')) }
    finally { setBusy(false) }
  }
  return <div className="settings-detail-stack mt-4">
    <div className="flex gap-2"><Button variant="outline" disabled={busy} onClick={() => void read(false)}>{t('settings.logRead')}</Button><Button variant="outline" disabled={busy} onClick={() => void read(true)}>{t('settings.logDownload')}</Button></div>
    {result && <Field><FieldLabel htmlFor="log-query-content">{t('settings.logContent')}</FieldLabel><Textarea id="log-query-content" readOnly value={result.content} placeholder={t('settings.logNoRecords')} rows={12} />{result.truncated && <FieldDescription>{t('settings.logTruncated')}</FieldDescription>}</Field>}
  </div>
}
