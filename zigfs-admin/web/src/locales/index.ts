import { useSyncExternalStore } from 'react'
import en from './en.json'
import zh from './zh.json'

export type Locale = 'en' | 'zh'
type Catalog = Record<string, Record<string, string>>
type English = typeof en
export type TranslationKey = { [M in keyof English]: `${M & string}.${keyof English[M] & string}` }[keyof English]
const catalogs: Record<Locale, Catalog> = { en, zh }
const storageKey = 'zigfs-admin-locale'
const listeners = new Set<() => void>()

function savedLocale(): Locale {
  try { return localStorage.getItem(storageKey) === 'zh' ? 'zh' : 'en' } catch { return 'en' }
}
let locale = savedLocale()
function updateDocument() {
  document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en'
  document.title = t('common.consoleTitle')
}
export function getLocale(): Locale { return locale }
export function getFormatLocale() { return locale === 'zh' ? 'zh-CN' : 'en-US' }
export function setLocale(next: Locale) {
  if (next === locale) return
  locale = next
  try { localStorage.setItem(storageKey, locale) } catch { /* Keep the in-memory preference when storage is unavailable. */ }
  updateDocument()
  for (const notify of listeners) notify()
}
export function useLocale() {
  return useSyncExternalStore(callback => { listeners.add(callback); return () => { listeners.delete(callback) } }, getLocale, () => 'en' as Locale)
}
export function t(key: TranslationKey, values: Record<string, string | number> = {}): string {
  const [module, name] = key.split('.')
  const message = catalogs[locale][module]?.[name] ?? catalogs.en[module]?.[name] ?? key
  return message.replace(/\{(\w+)\}/g, (match, name: string) => values[name] === undefined ? match : String(values[name]))
}
updateDocument()
window.addEventListener('storage', event => {
  if (event.key === storageKey || event.key === null) {
    const next = savedLocale()
    if (next !== locale) { locale = next; updateDocument(); for (const notify of listeners) notify() }
  }
})

/** Translate known display enums without changing protocol values or user data. */
export function displayValue(value: string): string {
  return Object.hasOwn(en.labels, value) ? t(`labels.${value}` as TranslationKey) : value
}
