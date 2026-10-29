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
    withLoading('正在加载存储信息...', load).catch((reason: Error) => notifyError(reason.message))
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
      title: '扫描并清理存储',
      message: '将扫描完整 namespace，并永久删除所有未被对象版本或未完成上传引用的数据。有效对象与历史版本不会被删除。',
      confirmLabel: '扫描并清理',
      danger: true,
    })) return
    try {
      const report = await withLoading('正在扫描并清理存储...', () => api.runStorageGC())
      setLastResult(report)
      const [storageInfo, scannerInfo] = await Promise.all([api.storage(), api.storageScanner()])
      setStorage(storageInfo)
      setScanner(scannerInfo)
      showToast(`清理完成，回收 ${report.removed_generations} 个 generation（${formatBytes(report.removed_bytes)}）`)
    } catch (reason) {
      notifyError(reason instanceof Error ? reason.message : '存储清理失败')
    }
  }

  return (
    <section>
      <header className="page-header">
        <div><p className="eyebrow">Capacity & Reclamation</p><h2>Storage</h2><p className="page-description">查看逻辑对象占用、分片扫描进度和不可达数据回收结果。</p></div>
        <button className="danger-button" type="button" onClick={() => void runGC()}><Trash2 className="button-icon" aria-hidden="true" />扫描并清理</button>
      </header>
      {storage && (
        <div className="panel metric-grid metric-grid-three">
          <Metric label="Object bytes" value={formatBytes(storage.used)} />
          <Metric label="Total capacity" value={storage.total === null ? 'Not reported' : formatBytes(storage.total)} />
          <Metric label="Available" value={storage.available === null ? 'Not reported' : formatBytes(storage.available)} />
        </div>
      )}
      <div className="storage-cleanup-grid">
        <article className="panel storage-cleanup-item">
          <Clock3 aria-hidden="true" />
          <div><span>Incomplete MPU</span><strong>超时自动清理</strong><p>超过配置保留期的未完成上传由 Scanner 删除。</p></div>
        </article>
        <article className="panel storage-cleanup-item">
          <ScanSearch aria-hidden="true" />
          <div><span>Dangling Data</span><strong>Scanner 发现并 Purge</strong><p>按 16 个分片推进，完整周期覆盖整个 namespace。</p></div>
        </article>
        <article className="panel storage-cleanup-item">
          <Trash2 aria-hidden="true" />
          <div><span>Deleted Data</span><strong>Trash / GC</strong><p>不可达 generation 先移入 Trash，再执行最终物理删除。</p></div>
        </article>
      </div>
      {scanner && (
        <section className="panel scanner-panel">
          <header>
            <div><h3>Namespace Scanner</h3><p>后台每个周期处理一个分片。</p></div>
            <span className="scanner-progress">下个分片 {scanner.next_partition + 1} / {scanner.partitions}</span>
          </header>
          <div className="scanner-track" aria-label={`Scanner progress ${scanner.next_partition} of ${scanner.partitions}`}>
            {Array.from({ length: scanner.partitions }, (_, index) => <span className={index < scanner.next_partition ? 'complete' : index === scanner.next_partition ? 'next' : ''} key={index} />)}
          </div>
          {lastResult ? (
            <div className="scanner-result-grid">
              <Metric label="Scanned" value={`${lastResult.scanned_generations} / ${formatBytes(lastResult.scanned_bytes)}`} />
              <Metric label="Retained" value={`${lastResult.retained_generations} / ${formatBytes(lastResult.retained_bytes)}`} />
              <Metric label="Purged" value={`${lastResult.removed_generations} / ${formatBytes(lastResult.removed_bytes)}`} />
              <Metric label="Expired MPU" value={String(lastResult.expired_multipart_uploads)} />
            </div>
          ) : <p className="scanner-empty"><RefreshCw aria-hidden="true" />等待首次后台扫描</p>}
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
