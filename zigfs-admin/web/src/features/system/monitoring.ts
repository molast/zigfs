import type { MonitorPoint } from '@/types/api'

/** Recent observed peak, never mixing runs or turning missing observations into zero. */
export function monitorLevel(latest: MonitorPoint | null | undefined, history: MonitorPoint[], field: keyof MonitorPoint, limit?: number | null) {
  const raw = latest?.[field]
  const value = typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : null
  const recent = latest ? history.filter(point => point.run_id === latest.run_id && point.timestamp >= latest.timestamp - 60 && point.timestamp <= latest.timestamp)
    .map(point => ({ timestamp: point.timestamp, value: point[field] }))
    .filter(point => point.value != null && Number.isFinite(point.value) && point.value >= 0) : []
  const peak = Math.max(value ?? 0, ...recent.map(point => point.value as number))
  const max = Math.max(value ?? 0, peak, limit != null && Number.isFinite(limit) && limit > 0 ? limit : peak * 1.2, 1)
  const previous = recent.filter(point => point.timestamp < (latest?.timestamp ?? 0)).at(-1)?.value
  return { value, max, peak, rising: value != null && previous != null && value > previous }
}

/** Add an explicit null observation rather than drawing across a missing interval. */
export function historyWithGaps(points: MonitorPoint[], stepSeconds: number): MonitorPoint[] {
  return points.flatMap((point, index) => {
    const previous = points[index - 1]
    if (!previous || (previous.run_id === point.run_id && point.timestamp - previous.timestamp <= stepSeconds * 1.5)) return [point]
    const gap = Object.fromEntries(Object.keys(point).map(key => [key, key === 'timestamp' ? Math.min(previous.timestamp + stepSeconds, (previous.timestamp + point.timestamp) / 2) : null])) as unknown as MonitorPoint
    return [gap, point]
  })
}

export function formatMonitorBytes(value: number | null | undefined, locale: string): string {
  if (value == null || !Number.isFinite(value) || value < 0) return '—'
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  const index = value > 0 ? Math.max(0, Math.min(4, Math.floor(Math.log(value) / Math.log(1024)))) : 0
  return `${(value / 1024 ** index).toLocaleString(locale, { maximumFractionDigits: 1 })} ${units[index]}`
}

/** Cumulative operation histogram upper bounds; overflow remains unavailable. */
export function operationPercentile(row: { completed: number; histogram: number[] }, quantile: number): number | null {
  if (row.completed <= 0) return null
  const target = Math.ceil(row.completed * quantile)
  const bounds = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000]
  let count = 0
  for (let index = 0; index < bounds.length; index++) {
    count += row.histogram[index] ?? 0
    if (count >= target) return bounds[index]
  }
  return null
}

/** Tooltip labels may be series names; always format the observation timestamp. */
export function formatMonitorTime(timestamp: unknown, locale: string): string {
  if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return '—'
  const date = new Date(timestamp * 1000)
  return Number.isFinite(date.getTime()) ? date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—'
}

/** Draw just the filled arc: a zero-length rounded dash can paint both endpoints. */
export function gaugeArc(value: number | null | undefined): string | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null
  const angle = Math.min(100, value) / 100 * Math.PI
  const x = 100 - 84 * Math.cos(angle)
  const y = 100 - 84 * Math.sin(angle)
  return `M 16 100 A 84 84 0 0 1 ${x.toFixed(6)} ${y.toFixed(6)}`
}
