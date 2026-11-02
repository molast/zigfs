import { t } from '@/locales'
export type LifecycleAction = 'current-days' | 'current-date' | 'noncurrent-days' | 'delete-marker'

export interface LifecycleRule {
  id: string
  enabled: boolean
  prefix: string
  action: LifecycleAction
  days: number
  expirationDate: string
  newerNoncurrentVersions?: number
}

export function createLifecycleRule(id: string): LifecycleRule {
  return {
    id,
    enabled: true,
    prefix: '',
    action: 'current-days',
    days: 30,
    expirationDate: nextYearDate(),
  }
}

export function parseLifecycleConfiguration(xml: string): LifecycleRule[] {
  const document = new DOMParser().parseFromString(xml, 'application/xml')
  if (document.querySelector('parsererror')) throw new Error(t('buckets.unableToParseLifecycleXml'))

  const rules: LifecycleRule[] = []
  const sourceRules = Array.from(document.getElementsByTagNameNS('*', 'Rule'))
  sourceRules.forEach((source, ruleIndex) => {
    const baseId = childText(source, 'ID') || `lifecycle-rule-${ruleIndex + 1}`
    const enabled = childText(source, 'Status') === 'Enabled'
    const filter = childElement(source, 'Filter')
    const prefix = filter ? childText(filter, 'Prefix') : childText(source, 'Prefix')
    const expiration = childElement(source, 'Expiration')
    const noncurrent = childElement(source, 'NoncurrentVersionExpiration')
    const actions: Omit<LifecycleRule, 'id' | 'enabled' | 'prefix'>[] = []

    if (expiration) {
      const days = childText(expiration, 'Days')
      const date = childText(expiration, 'Date')
      const marker = childText(expiration, 'ExpiredObjectDeleteMarker')
      if (days) actions.push({ action: 'current-days', days: positiveInteger(days, 'Days'), expirationDate: nextYearDate() })
      if (date) actions.push({ action: 'current-date', days: 30, expirationDate: date.slice(0, 10) })
      if (marker === 'true') actions.push({ action: 'delete-marker', days: 30, expirationDate: nextYearDate() })
    }
    if (noncurrent) {
      const newer = childText(noncurrent, 'NewerNoncurrentVersions')
      actions.push({
        action: 'noncurrent-days',
        days: positiveInteger(childText(noncurrent, 'NoncurrentDays'), 'NoncurrentDays'),
        expirationDate: nextYearDate(),
        ...(newer ? { newerNoncurrentVersions: positiveInteger(newer, 'NewerNoncurrentVersions') } : {}),
      })
    }
    if (actions.length === 0) throw new Error(t('buckets.lifecycleRuleValueHasNoSupportedExpirationAction', { '0': baseId }))

    actions.forEach((action, actionIndex) => {
      const proposedId = actions.length === 1 ? baseId : `${baseId}-${actionSuffix(action.action)}`
      rules.push({
        id: uniqueRuleId(proposedId, rules, actionIndex),
        enabled,
        prefix,
        ...action,
      })
    })
  })
  return rules
}

export function serializeLifecycleConfiguration(rules: LifecycleRule[]): string {
  validateLifecycleRules(rules)
  const body = rules.map((rule) => {
    const action = serializeAction(rule)
    return [
      '  <Rule>',
      `    <ID>${escapeXml(rule.id.trim())}</ID>`,
      `    <Filter><Prefix>${escapeXml(rule.prefix)}</Prefix></Filter>`,
      `    <Status>${rule.enabled ? 'Enabled' : 'Disabled'}</Status>`,
      ...action.map((line) => `    ${line}`),
      '  </Rule>',
    ].join('\n')
  }).join('\n')
  return `<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\n${body}\n</LifecycleConfiguration>`
}

export function validateLifecycleRules(rules: LifecycleRule[]) {
  if (rules.length > 1000) throw new Error(t('buckets.aMaximumOf1000LifecycleRulesIsAllowed'))
  const ids = new Set<string>()
  for (const rule of rules) {
    const id = rule.id.trim()
    if (!id) throw new Error(t('buckets.ruleIdIsRequired'))
    if (id.length > 255) throw new Error(t('buckets.ruleIdValueMustNotExceed255Characters', { '0': id }))
    if (ids.has(id)) throw new Error(t('buckets.duplicateRuleIdValue', { '0': id }))
    ids.add(id)
    if (rule.action === 'current-date') {
      const parsedDate = new Date(`${rule.expirationDate}T00:00:00Z`)
      if (!/^\d{4}-\d{2}-\d{2}$/.test(rule.expirationDate) || Number.isNaN(parsedDate.valueOf()) ||
        parsedDate.toISOString().slice(0, 10) !== rule.expirationDate) {
        throw new Error(t('buckets.ruleValueHasAnInvalidExpirationDate', { '0': id }))
      }
    } else if (rule.action !== 'delete-marker' && (!Number.isInteger(rule.days) || rule.days < 1)) {
      throw new Error(t('buckets.daysForRuleValueMustBeAPositiveInteger', { '0': id }))
    }
    if (rule.newerNoncurrentVersions !== undefined &&
      (!Number.isInteger(rule.newerNoncurrentVersions) || rule.newerNoncurrentVersions < 1)) {
      throw new Error(t('buckets.retainedNewerVersionsForRuleValueMustBeA', { '0': id }))
    }
  }
}

function serializeAction(rule: LifecycleRule): string[] {
  switch (rule.action) {
    case 'current-days':
      return [`<Expiration><Days>${rule.days}</Days></Expiration>`]
    case 'current-date':
      return [`<Expiration><Date>${rule.expirationDate}T00:00:00Z</Date></Expiration>`]
    case 'noncurrent-days':
      return [
        '<NoncurrentVersionExpiration>',
        `  <NoncurrentDays>${rule.days}</NoncurrentDays>`,
        ...(rule.newerNoncurrentVersions
          ? [`  <NewerNoncurrentVersions>${rule.newerNoncurrentVersions}</NewerNoncurrentVersions>`]
          : []),
        '</NoncurrentVersionExpiration>',
      ]
    case 'delete-marker':
      return ['<Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration>']
  }
}

function childElement(parent: Element, localName: string) {
  return Array.from(parent.children).find((child) => child.localName === localName)
}

function childText(parent: Element, localName: string) {
  return childElement(parent, localName)?.textContent?.trim() ?? ''
}

function positiveInteger(value: string, field: string) {
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(t('buckets.valueMustBeAPositiveInteger', { '0': field }))
  return parsed
}

function escapeXml(value: string) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function actionSuffix(action: LifecycleAction) {
  switch (action) {
    case 'current-days': return 'current'
    case 'current-date': return 'date'
    case 'noncurrent-days': return 'noncurrent'
    case 'delete-marker': return 'markers'
  }
}

function uniqueRuleId(proposed: string, existing: LifecycleRule[], seed: number) {
  if (!existing.some((rule) => rule.id === proposed)) return proposed
  let suffix = seed + 2
  while (existing.some((rule) => rule.id === `${proposed}-${suffix}`)) suffix += 1
  return `${proposed}-${suffix}`
}

function nextYearDate() {
  const date = new Date()
  date.setUTCFullYear(date.getUTCFullYear() + 1)
  return date.toISOString().slice(0, 10)
}
