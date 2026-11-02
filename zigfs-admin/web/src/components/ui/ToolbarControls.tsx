import { Plus, RefreshCw, Search } from 'lucide-react'
import type { ComponentProps, ReactNode } from 'react'
import { cn } from '@/lib/utils'
import { Button, type ButtonProps } from './Button'
import { Input } from './Input'

export function ToolbarControls({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('toolbar-controls', className)}>{children}</div>
}

type ToolbarSearchProps = Omit<ComponentProps<typeof Input>, 'aria-label'> & {
  label: string
  wrapperClassName?: string
}

export function ToolbarSearch({ label, wrapperClassName, className, ...props }: ToolbarSearchProps) {
  return <label className={cn('toolbar-search', wrapperClassName)}>
    <Search aria-hidden="true" />
    <Input aria-label={label} className={className} {...props} />
  </label>
}

type ToolbarButtonProps = Omit<ButtonProps, 'children' | 'size' | 'variant'> & { label: string }

export function ToolbarCreateButton({ label, className, ...props }: ToolbarButtonProps) {
  return <Button type="button" variant="outline" className={cn('toolbar-control-button', className)} {...props}>
    <Plus data-icon="inline-start" aria-hidden="true" />{label}
  </Button>
}

export function ToolbarRefreshButton({ label, busy = false, disabled, className, ...props }: ToolbarButtonProps & { busy?: boolean }) {
  return <Button type="button" variant="outline" className={cn('toolbar-control-button', className)} disabled={disabled || busy} aria-busy={busy} {...props}>
    <RefreshCw data-icon="inline-start" className={busy ? 'spinning' : undefined} aria-hidden="true" />{label}
  </Button>
}
