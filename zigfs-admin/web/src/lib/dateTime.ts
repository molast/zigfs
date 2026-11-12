import { useSyncExternalStore } from 'react'
import { getFormatLocale } from '@/locales'

export type DateFormat = 'locale' | 'ymd' | 'dmy' | 'mdy'
export interface DisplayPreferences { timezone: string; date_format: DateFormat }
export const defaultDisplayPreferences: DisplayPreferences = { timezone: 'browser', date_format: 'locale' }
let preferences = defaultDisplayPreferences
const listeners = new Set<() => void>()
const supportedZones = new Map<string, boolean>()
const formatters = new Map<string, Intl.DateTimeFormat>()

export function getDisplayPreferences() { return preferences }
export function setDisplayPreferences(next: DisplayPreferences) {
  if (next.timezone === preferences.timezone && next.date_format === preferences.date_format) return
  preferences = { ...next }
  for (const listener of listeners) listener()
}
export function useDisplayPreferences() {
  return useSyncExternalStore(callback => { listeners.add(callback); return () => { listeners.delete(callback) } }, getDisplayPreferences, () => defaultDisplayPreferences)
}
export function browserTimezone() { return Intl.DateTimeFormat().resolvedOptions().timeZone }
export function supportsTimezone(timezone: string) {
  if (supportedZones.has(timezone)) return supportedZones.get(timezone)!
  let supported = true
  try { new Intl.DateTimeFormat('en-US', { timeZone: timezone }) } catch { supported = false }
  supportedZones.set(timezone, supported)
  return supported
}

type DateValue = Date | string | number | null | undefined
function format(value: DateValue, kind: 'date' | 'time' | 'both', selected: DisplayPreferences) {
  if (value === null || value === undefined || value === '') return '—'
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.valueOf())) return '—'
  const timeZone = selected.timezone === 'browser' ? undefined : supportsTimezone(selected.timezone) ? selected.timezone : 'UTC'
  const dateOptions: Intl.DateTimeFormatOptions = kind === 'time' ? {} : { year: 'numeric', month: '2-digit', day: '2-digit' }
  const timeOptions: Intl.DateTimeFormatOptions = kind === 'date' ? {} : { hour: '2-digit', minute: '2-digit', second: '2-digit' }
  const key = JSON.stringify([getFormatLocale(), timeZone, kind, selected.date_format === 'locale'])
  let formatter = formatters.get(key)
  if (!formatter) {
    if (formatters.size >= 64) formatters.clear()
    formatter = selected.date_format === 'locale'
      ? new Intl.DateTimeFormat(getFormatLocale(), { ...dateOptions, ...timeOptions, timeZone })
      : new Intl.DateTimeFormat('en-GB', { ...dateOptions, ...timeOptions, timeZone, hourCycle: 'h23', numberingSystem: 'latn', calendar: 'gregory' })
    formatters.set(key, formatter)
  }
  if (selected.date_format === 'locale') return formatter.format(date)
  const parts = formatter.formatToParts(date)
  const part = (name: Intl.DateTimeFormatPartTypes) => parts.find(item => item.type === name)?.value ?? ''
  const day = part('day'), month = part('month'), year = part('year')
  const dateText = selected.date_format === 'dmy' ? `${day}/${month}/${year}` : selected.date_format === 'mdy' ? `${month}/${day}/${year}` : `${year}-${month}-${day}`
  const timeText = `${part('hour')}:${part('minute')}:${part('second')}`
  return kind === 'date' ? dateText : kind === 'time' ? timeText : `${dateText} ${timeText}`
}
export function formatDateTime(value: DateValue, selected = preferences) { return format(value, 'both', selected) }
export function formatDate(value: DateValue, selected = preferences) { return format(value, 'date', selected) }
export function formatTime(value: DateValue, selected = preferences) { return format(value, 'time', selected) }
