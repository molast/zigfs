import type { HTMLAttributes } from 'react'
import { cn } from '@/lib/utils'

export function Badge({ className, variant = 'default', ...props }: HTMLAttributes<HTMLSpanElement> & { variant?: 'default' | 'destructive' }) {
  return <span className={cn('ui-badge', variant === 'destructive' && 'ui-badge-destructive', className)} {...props} />
}
