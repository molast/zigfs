import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { Settings } from '../../types/api'

export function SettingsView({ api }: { api: ApiClient }) {
  const [settings, setSettings] = useState<Settings | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    api.settings().then(setSettings).catch((reason: Error) => setError(reason.message))
  }, [api])

  return (
    <section>
      <header className="page-header"><div><p className="eyebrow">Effective configuration</p><h2>Settings</h2><p className="page-description">当前生效的只读配置。修改配置后需要重启 ZigFS。</p></div></header>
      {error && <p className="error-banner">{error}</p>}
      {settings && (
        <section className="panel table-panel"><dl className="definition-list">
          <Row label="API address" value={settings.api_address} />
          <Row label="S3 public endpoint" value={settings.s3_public_endpoint} />
          <Row label="S3 region" value={settings.s3_region} />
          <Row label="Request clock skew" value={`${settings.request_time_skew_seconds}s`} />
          <Row label="Multipart expiry" value={`${settings.multipart_expiry_seconds}s`} />
          <Row label="Stream buffer" value={`${settings.stream_buffer_size.toLocaleString()} B`} />
          <Row label="Metrics" value={settings.metrics_enabled ? settings.metrics_address : 'Disabled'} />
          <Row label="Admin session TTL" value={`${settings.admin_session_ttl_seconds}s`} />
        </dl></section>
      )}
    </section>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return <div><dt>{label}</dt><dd>{value}</dd></div>
}
