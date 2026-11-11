import { Children, useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { ChevronDown, ChevronUp } from 'lucide-react'
import { t } from '@/locales'
import { Button } from './Button'
import { FieldGroup } from './field'

export function FilterFields({ children }: { children: ReactNode }) {
  const fields = Children.toArray(children)
  const [visibleRows, setVisibleRows] = useState(2)
  const [columns, setColumns] = useState(5)
  const container = useRef<HTMLDivElement>(null)
  const id = useId()
  useEffect(() => {
    const element = container.current
    if (!element) return
    const update = () => setColumns(Math.max(1, getComputedStyle(element).gridTemplateColumns.split(/\s+/).length))
    update()
    const observer = new ResizeObserver(update)
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  const visibleCount = columns * visibleRows
  const expanded = fields.length <= visibleCount
  const overflow = fields.length > columns
  return <div className="flex items-start gap-2">
    <FieldGroup id={id} ref={container} density="compact" className="grid min-w-0 flex-1 gap-x-4 gap-y-3 md:grid-cols-2 xl:grid-cols-5">
      {fields.map((field, index) => <div key={index} hidden={index >= visibleCount}>{field}</div>)}
    </FieldGroup>
    {overflow && <div className="flex shrink-0 pt-6"><Button type="button" variant="ghost" size="sm" aria-expanded={expanded} aria-controls={id} onClick={() => setVisibleRows(expanded ? 1 : Infinity)}>{expanded ? t('audit.collapseFilters') : t('audit.expandFilters')}{expanded ? <ChevronUp data-icon="inline-end" /> : <ChevronDown data-icon="inline-end" />}</Button></div>}
  </div>
}
