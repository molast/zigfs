import type { HTMLAttributes } from 'react'
import { CircleAlert } from 'lucide-react'
import { Button } from './Button'
import { Tooltip, TooltipContent, TooltipTrigger } from './tooltip'
import { t } from '@/locales'
import { cn } from '@/lib/utils'

type CardProps = HTMLAttributes<HTMLDivElement> & {
  help?: string
}

export function Card({ className, help, children, ...props }: CardProps) {
  return (
    <div className={cn('ui-card', help && 'ui-card-with-help', className)} {...props}>
      {children}
      {help && (
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              className="ui-card-help"
              aria-label={t('monitor.metricHelp')}
            >
              <CircleAlert aria-hidden="true" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top" className="max-w-80 leading-relaxed">
            {help}
          </TooltipContent>
        </Tooltip>
      )}
    </div>
  )
}

export function CardHeader({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="card-header"
      className={cn('flex flex-col gap-1.5 p-4', className)}
      {...props}
    />
  )
}

export function CardTitle({ className, ...props }: HTMLAttributes<HTMLHeadingElement>) {
  return (
    <h3
      data-slot="card-title"
      className={cn('text-sm font-semibold leading-none', className)}
      {...props}
    />
  )
}

export function CardDescription({ className, ...props }: HTMLAttributes<HTMLParagraphElement>) {
  return (
    <p
      data-slot="card-description"
      className={cn('text-xs text-muted-foreground leading-relaxed', className)}
      {...props}
    />
  )
}

export function CardContent({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div data-slot="card-content" className={cn('px-4 pb-4', className)} {...props} />
}

export function CardFooter({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="card-footer"
      className={cn('flex items-center px-4 pb-4', className)}
      {...props}
    />
  )
}
