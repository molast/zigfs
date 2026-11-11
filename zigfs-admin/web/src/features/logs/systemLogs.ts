export const logLevels = ['ERROR', 'WARN', 'INFO', 'DEBUG', 'TRACE', 'UNKNOWN'] as const
export type LogLevel = typeof logLevels[number]
export interface SystemLog {
  schema_version: string
  timestamp: string | null
  level: LogLevel
  message: string
  service: { name: string; version?: string; instance_id: string | null }
  source: { type: string; component: string; file?: string; line?: number; function?: string }
  context: { request_id?: string | null; trace_id?: string | null; bucket?: string | null; object_key?: string | null }
  error: { code?: string; type?: string; message?: string; stack_trace?: string; trace_kind?: string } | null
  metadata: Record<string, unknown>
  raw: string
}
const record = (value: unknown): Record<string, unknown> => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
const text = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined
export function parseSystemLogs(content: string): SystemLog[] {
  return content.split('\n').filter(line => line.trim()).map(raw => {
    let value: Record<string, unknown> = {}
    let parsed = false
    try { value = record(JSON.parse(raw)); parsed = typeof value.message === 'string' } catch { /* Legacy text below. */ }
    if (!parsed) {
      const match = raw.match(/^([+]?\d+)\s+(\w+)\s+\[([^\]]+)\]\s+(.*)$/)
      if (match) {
        value = { timestamp: Number(match[1]), level: match[2], scope: match[3], message: match[4] }; parsed = true
        const suffix = match[4].lastIndexOf('\t@zigfs:')
        if (suffix >= 0) {
          try {
            const diagnostic = record(JSON.parse(match[4].slice(suffix + 8)))
            if (diagnostic.error) { value.error = diagnostic.error; value.source = diagnostic.source; value.message = match[4].slice(0, suffix) }
          } catch { /* Preserve unrecognized text unchanged. */ }
        }
      }
    }
    const stamp = typeof value.timestamp === 'number' ? value.timestamp * 1000 : Date.parse(text(value.timestamp) ?? '')
    const validTime = Number.isFinite(stamp) && Number.isFinite(new Date(stamp).getTime())
    const level = (text(value.level) ?? '').toUpperCase().replace(/^WARNING$/, 'WARN').replace(/^ERR$/, 'ERROR')
    const service = record(value.service), source = record(value.source), context = record(value.context)
    const message = text(value.message) ?? raw
    const error = record(value.error)
    const legacyComponent = text(value.scope)
    return {
      schema_version: text(value.schema_version) ?? '1.0', timestamp: validTime ? new Date(stamp).toISOString() : null,
      level: logLevels.includes(level as LogLevel) ? level as LogLevel : 'UNKNOWN', message,
      service: { name: text(service.name) ?? 'zigfs', version: text(service.version), instance_id: text(service.instance_id) ?? null },
      source: { type: text(source.type) ?? 'application', component: text(source.component) ?? (legacyComponent && legacyComponent !== 'default' ? legacyComponent : message.startsWith('http request') ? 'api' : 'server'), file: text(source.file), line: typeof source.line === 'number' ? source.line : undefined, function: text(source.function) },
      context: { request_id: text(context.request_id) ?? message.match(/(?:^|\s)request_id=(\S+)/)?.[1], trace_id: text(context.trace_id), bucket: text(context.bucket), object_key: text(context.object_key) },
      error: value.error == null ? null : { code: text(error.code), type: text(error.type), message: text(error.message), stack_trace: text(error.stack_trace), trace_kind: text(error.trace_kind) }, metadata: { ...record(value.metadata), ...(!parsed || !validTime ? { parse_status: 'unparsed' } : {}) }, raw,
    }
  }).filter(log => !/^http request method=[A-Z]+ path=\S* status=\d+ request_id=\S+ duration_ms=[+]?\d+$/.test(log.message))
}
export interface LogFilters { level: string; component: string; source: string; keyword: string }
export function filterSystemLogs(logs: SystemLog[], filters: LogFilters): SystemLog[] {
  const keyword = filters.keyword.trim().toLowerCase()
  return logs.filter(log => (filters.level === 'all' || log.level === filters.level) && (filters.component === 'all' || log.source.component === filters.component) && (filters.source === 'all' || log.source.type === filters.source) && (!keyword || [log.message, log.context.request_id, log.context.trace_id, log.service.instance_id, JSON.stringify(log.error)].some(value => value?.toLowerCase().includes(keyword))))
}
export function logHistogram(logs: SystemLog[], from: number, to: number) {
  const width = Math.max(1, (to - from + 1) / 30)
  const bins = Array.from({ length: 30 }, (_, i) => ({ timestamp: (from + i * width) * 1000, ERROR: 0, WARN: 0, INFO: 0, DEBUG: 0, TRACE: 0, UNKNOWN: 0 }))
  for (const log of logs) {
    if (!log.timestamp) continue
    const seconds = Date.parse(log.timestamp) / 1000
    if (seconds < from || seconds >= to + 1) continue
    bins[Math.min(29, Math.floor((seconds - from) / width))][log.level]++
  }
  return bins
}
