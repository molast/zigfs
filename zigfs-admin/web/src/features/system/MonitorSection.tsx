import { useState, type ReactNode } from 'react'
import { ChevronRight } from 'lucide-react'
import { Badge } from '@/components/ui/Badge'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { t } from '@/locales'

export function MonitorSection({ title, panels, description, attention = 0, defaultOpen = false, children }: {
  title: string
  panels: number
  description?: string
  attention?: number
  defaultOpen?: boolean
  children: ReactNode
}) {
  const [open, setOpen] = useState(defaultOpen)
  return <Collapsible open={open} onOpenChange={setOpen} className="monitor-module">
    <CollapsibleTrigger aria-label={title} className="group flex w-full flex-wrap items-center gap-2 px-2 py-1.5 text-left text-sm font-medium">
      <ChevronRight aria-hidden="true" className="size-4 shrink-0 transition-transform group-data-[state=open]:rotate-90" />
      <span>{title}</span><span className="text-xs font-normal text-muted-foreground">{t('monitor.panelCount', { count: panels })}</span>
      {attention > 0 && <Badge variant="destructive">{t('monitor.firingCount', { count: attention })}</Badge>}
    </CollapsibleTrigger>
    <CollapsibleContent><div className="flex min-w-0 flex-col gap-3 pt-3 pb-3">
      {description && <p className="text-xs text-muted-foreground">{description}</p>}{children}
    </div></CollapsibleContent>
  </Collapsible>
}
