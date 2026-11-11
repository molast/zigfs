import type { AuditQuery, StructuredAuditEvent } from '@/types/api'

// Keep the saved audit format in downloads while applying the page's filters.
export function filterAuditLogContent(content: string, query: AuditQuery): string {
  return content.split('\n').filter(line => {
    const marker = line.indexOf(' [audit] ')
    try {
      const event: StructuredAuditEvent = JSON.parse(marker >= 0 ? line.slice(marker + 9) : line)
      if (!event.event_id || !event.request || !event.response) return false
      const matches = (filter: string | undefined, value: string | null | undefined) => !filter || filter === value
      return matches(query.category, event.event_category) && matches(query.action, event.event_action) && matches(query.outcome, event.response.status) &&
        matches(query.actor, event.identity.principal_name) && matches(query.bucket, event.resource.bucket) && matches(query.request_id, event.request.request_id) &&
        matches(query.service, event.operation.service) && matches(query.event_type, event.event_type) && matches(query.source_ip, event.request.source_ip)
    } catch { return false }
  }).join('\n')
}
