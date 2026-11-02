import { Languages } from 'lucide-react'
import { t, useLocale, setLocale } from '../locales'
import { Button } from './ui/Button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuTrigger } from './ui/dropdown-menu'

export function LanguageSwitcher() {
  const locale = useLocale()
  return <DropdownMenu>
    <DropdownMenuTrigger asChild><Button variant="ghost" size="sm" className="language-switcher" aria-label={t('common.language')} title={t('common.language')}><Languages data-icon="inline-start" />{locale === 'en' ? t('common.en') : t('common.chineseShort')}</Button></DropdownMenuTrigger>
    <DropdownMenuContent align="end"><DropdownMenuRadioGroup value={locale} onValueChange={value => { if (value === 'en' || value === 'zh') setLocale(value) }}>
      <DropdownMenuRadioItem value="en">{t('common.english')}</DropdownMenuRadioItem>
      <DropdownMenuRadioItem value="zh">{t('common.chinese')}</DropdownMenuRadioItem>
    </DropdownMenuRadioGroup></DropdownMenuContent>
  </DropdownMenu>
}
