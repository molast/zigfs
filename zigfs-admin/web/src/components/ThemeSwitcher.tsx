import { Moon, Sun } from 'lucide-react'
import { t } from '../locales'
import { Button } from './ui/Button'

export function ThemeSwitcher({ dark, onToggle }: { dark: boolean; onToggle: () => void }) {
  const label = t(dark ? 'navigation.switchToLightTheme' : 'navigation.switchToDarkTheme')
  return <Button variant="ghost" size="icon-sm" type="button" title={label} aria-label={label} onClick={onToggle}>
    {dark ? <Sun aria-hidden="true" /> : <Moon aria-hidden="true" />}
  </Button>
}
