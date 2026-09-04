import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { StorageInfo } from '../../types/api'

export function StorageView({ api }: { api: ApiClient }) {
  const [storage, setStorage] = useState<StorageInfo | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    api.storage().then(setStorage).catch((reason: Error) => setError(reason.message))
  }, [api])

  return (
    <section>
      <header className="page-header"><div><p className="eyebrow">Capacity</p><h2>Storage</h2></div></header>
      {error && <p className="error-banner">{error}</p>}
      {storage && (
        <div className="metric-grid metric-grid-three">
          <Metric label="Object bytes" value={formatBytes(storage.used)} />
          <Metric label="Total capacity" value={storage.total === null ? 'Not reported' : formatBytes(storage.total)} />
          <Metric label="Available" value={storage.available === null ? 'Not reported' : formatBytes(storage.available)} />
        </div>
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
