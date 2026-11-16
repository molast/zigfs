import { useEffect, useRef, useState } from 'react'
import type { ApiClient } from '@/api/client'
import type { ReleaseCheck, SystemInfo } from '@/types/api'
import { Button } from '@/components/ui/Button'
import { useErrorToast } from '@/components/ToastProvider'
import { formatDateTime } from '@/lib/dateTime'
import { getFormatLocale, t } from '@/locales'
import { processCPUPercent } from './processMetrics'

export function AboutRuntime({ api }: { api: ApiClient }) {
  const [sample, setSample] = useState<SystemInfo | null>(null)
  const [cpu, setCPU] = useState<number | null>(null)
  const notifyError = useErrorToast()
  useEffect(() => {
    let active = true
    let previous: SystemInfo | null = null
    let timer: ReturnType<typeof setTimeout> | undefined
    let failed = false
    async function poll() {
      try {
        const next = await api.system()
        if (!active) return
        setCPU(processCPUPercent(previous, next))
        setSample(next)
        previous = next
        failed = false
      } catch {
        if (!active) return
        previous = null
        setCPU(null)
        setSample(null)
        if (!failed) notifyError(t('settings.processMetricsFailed'))
        failed = true
      } finally {
        if (active) timer = setTimeout(() => void poll(), 5000)
      }
    }
    void poll()
    return () => { active = false; clearTimeout(timer) }
  }, [api, notifyError])
  return <div>
    <dl className="settings-facts">
      <div><dt>{t('settings.processMemory')}</dt><dd>{sample?.process ? `${(sample.process.resident_bytes / 1024 / 1024).toLocaleString(getFormatLocale(), { maximumFractionDigits: 1 })} MiB` : t('settings.unavailable')}</dd></div>
      <div><dt>{t('settings.processCPU')}</dt><dd>{cpu !== null ? `${cpu.toLocaleString(getFormatLocale(), { maximumFractionDigits: 1 })}%` : t(sample?.process ? 'settings.processSampling' : 'settings.unavailable')}</dd></div>
    </dl>
    <p className="text-sm text-muted-foreground">{t('settings.processMetricsHelp')}</p>
  </div>
}

export function AboutUpdates({ api }: { api: ApiClient }) {
  const [result, setResult] = useState<ReleaseCheck | null>(null)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)
  const mounted = useRef(true)
  const notifyError = useErrorToast()
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  async function check() {
    if (busy) return
    setBusy(true)
    setFailed(false)
    setResult(null)
    try {
      const next = await api.checkUpdates()
      if (mounted.current) setResult(next)
    } catch {
      if (mounted.current) {
        setFailed(true)
        notifyError(t('settings.updateCheckFailed'))
      }
    } finally { if (mounted.current) setBusy(false) }
  }
  return <div className="flex flex-col items-start gap-2" aria-busy={busy}>
    <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void check()}>{t(busy ? 'settings.checkingUpdates' : 'settings.checkUpdates')}</Button>
    <p role="status" className="text-sm text-muted-foreground">{result ? t(result.update_available ? 'settings.updateAvailable' : 'settings.noNewerRelease', { version: result.latest_version }) : t(failed ? 'settings.updateCheckFailed' : busy ? 'settings.checkingUpdates' : 'settings.updatesNotChecked')}</p>
    {result && <>
      <a href={result.release_url} target="_blank" rel="noreferrer">{t('settings.viewRelease')}</a>
      <p className="text-sm text-muted-foreground">{t('settings.updatesCheckedAt', { time: formatDateTime(result.checked_at * 1000) })}</p>
    </>}
  </div>
}
