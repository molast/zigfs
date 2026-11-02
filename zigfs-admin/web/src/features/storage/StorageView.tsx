import { t } from '@/locales'
import { Clock3, RefreshCw, ScanSearch, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import type { StorageInfo, StorageScanReport, StorageScannerStatus } from '../../types/api'

export function StorageView({ api }: { api: ApiClient }) {
  const { withLoading } = useLoading()
  const confirm = useConfirm()
  const showToast = useToast()
  const [storage, setStorage] = useState<StorageInfo | null>(null)
  const [scanner, setScanner] = useState<StorageScannerStatus | null>(null)
  const [lastResult, setLastResult] = useState<StorageScanReport | null>(null)
  const notifyError = useErrorToast()

  const load = useCallback(async () => {
    const [storageInfo, scannerInfo] = await Promise.all([api.storage(), api.storageScanner()])
    setStorage(storageInfo)
    setScanner(scannerInfo)
    setLastResult(scannerInfo.last_scan)
  }, [api])

  useEffect(() => {
    withLoading(t('storage.loadingStorageInformation'), load).catch((reason: Error) => notifyError(reason.message))
    let active = true
    const timer = window.setInterval(() => {
      api.storageScanner().then((scannerInfo) => {
        if (!active) return
        setScanner(scannerInfo)
        setLastResult(scannerInfo.last_scan)
      }).catch((reason: Error) => {
        if (active) notifyError(reason.message)
      })
    }, 30_000)
    return () => {
      active = false
      window.clearInterval(timer)
    }
  }, [api, load, withLoading])

  async function runGC() {
    if (!await confirm({
      title: t('storage.scanAndCleanStorage'),
      message: t('storage.scanTheEntireNamespaceAndPermanentlyRemoveDataNot'),
      confirmLabel: t('storage.scanAndClean'),
      danger: true,
    })) return
    try {
      const report = await withLoading(t('storage.scanningAndCleaningStorage'), () => api.runStorageGC())
      setLastResult(report)
      const [storageInfo, scannerInfo] = await Promise.all([api.storage(), api.storageScanner()])
      setStorage(storageInfo)
      setScanner(scannerInfo)
      showToast(t('storage.cleanupCompletedReclaimedValueGenerationsValue', { '0': report.removed_generations, '1': formatBytes(report.removed_bytes) }))
    } catch (reason) {
      notifyError(reason instanceof Error ? reason.message : t('storage.storageCleanupFailed'))
    }
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">{t('storage.capacityReclamation')}</p><h2>{t('storage.storage')}</h2><p className="page-description">{t('storage.viewLogicalObjectUsagePartitionScanProgressAndUnreferenced')}</p></div>
        <button className="danger-button" type="button" onClick={() => void runGC()}><Trash2 className="button-icon" aria-hidden="true" />{t('storage.scanAndClean')}</button>
      </header>
      {storage && (
        <div className="panel metric-grid metric-grid-three">
          <Metric label={t('storage.objectBytes')} value={formatBytes(storage.used)} />
          <Metric label={t('storage.totalCapacity')} value={storage.total === null ? t('common.notReported') : formatBytes(storage.total)} />
          <Metric label={t('storage.available')} value={storage.available === null ? t('common.notReported') : formatBytes(storage.available)} />
        </div>
      )}
      <div className="storage-cleanup-grid">
        <article className="panel storage-cleanup-item">
          <Clock3 aria-hidden="true" />
          <div><span>{t('storage.incompleteMpu')}</span><strong>{t('storage.automaticExpiryCleanup')}</strong><p>{t('storage.theScannerRemovesIncompleteUploadsBeyondTheConfiguredRetention')}</p></div>
        </article>
        <article className="panel storage-cleanup-item">
          <ScanSearch aria-hidden="true" />
          <div><span>{t('storage.danglingData')}</span><strong>{t('storage.detectedAndPurgedByTheScanner')}</strong><p>{t('storage.scansProgressThrough16PartitionsAFullCycleCovers')}</p></div>
        </article>
        <article className="panel storage-cleanup-item">
          <Trash2 aria-hidden="true" />
          <div><span>{t('storage.deletedData')}</span><strong>{t('storage.trashGc')}</strong><p>{t('storage.unreferencedGenerationsMoveToTrashBeforeFinalPhysicalDeletion')}</p></div>
        </article>
      </div>
      {scanner && (
        <section className="panel scanner-panel">
          <header>
            <div><h3>{t('storage.namespaceScanner')}</h3><p>{t('storage.eachBackgroundCycleProcessesOnePartition')}</p></div>
            <span className="scanner-progress">{t('storage.nextPartition')} {scanner.next_partition + 1} / {scanner.partitions}</span>
          </header>
          <div className="scanner-track" aria-label={`Scanner progress ${scanner.next_partition} of ${scanner.partitions}`}>
            {Array.from({ length: scanner.partitions }, (_, index) => <span className={index < scanner.next_partition ? 'complete' : index === scanner.next_partition ? 'next' : ''} key={index} />)}
          </div>
          {lastResult ? (
            <div className="scanner-result-grid">
              <Metric label={t('storage.scanned')} value={`${lastResult.scanned_generations} / ${formatBytes(lastResult.scanned_bytes)}`} />
              <Metric label={t('storage.retained')} value={`${lastResult.retained_generations} / ${formatBytes(lastResult.retained_bytes)}`} />
              <Metric label={t('storage.purged')} value={`${lastResult.removed_generations} / ${formatBytes(lastResult.removed_bytes)}`} />
              <Metric label={t('storage.expiredMpu')} value={String(lastResult.expired_multipart_uploads)} />
            </div>
          ) : <p className="scanner-empty"><RefreshCw aria-hidden="true" />{t('storage.waitingForTheFirstBackgroundScan')}</p>}
        </section>
      )}
    </section>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return <article className="metric"><span>{label}</span><strong>{value}</strong></article>
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index += 1
  }
  return `${value.toFixed(1)} ${units[index]}`
}
