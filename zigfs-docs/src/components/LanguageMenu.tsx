'use client';

import { useI18n } from 'fumadocs-ui/contexts/i18n';
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from 'fumadocs-ui/components/ui/popover';

export function LanguageMenu() {
  const { locale, locales = [], onChange } = useI18n();
  const label = locale === 'zh' ? '选择语言' : 'Choose a language';

  return (
    <Popover>
      <PopoverTrigger aria-label={label} className="rounded-md p-1.5 text-sm font-medium hover:bg-fd-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring">
        {locales.find((item) => item.locale === locale)?.name}
      </PopoverTrigger>
      <PopoverContent align="end" className="flex w-40 min-w-0 flex-col gap-0.5 p-1">
        <p className="p-2 text-xs font-medium text-fd-muted-foreground">{label}</p>
        {locales.map((item) => (
          <PopoverClose
            key={item.locale}
            onClick={() => onChange?.(item.locale)}
            className={`rounded-lg px-2 py-1.5 text-start text-sm transition-colors ${item.locale === locale ? 'bg-fd-primary/10 text-fd-primary' : 'text-fd-muted-foreground hover:bg-fd-accent hover:text-fd-accent-foreground'}`}
          >
            {item.name}
          </PopoverClose>
        ))}
      </PopoverContent>
    </Popover>
  );
}
