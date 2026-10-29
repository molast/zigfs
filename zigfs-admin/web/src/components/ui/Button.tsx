import { Slot } from '@radix-ui/react-slot'
import { cva, type VariantProps } from 'class-variance-authority'
import type { ComponentProps } from 'react'
import { cn } from '@/lib/utils'

export const buttonVariants = cva('ui-button', { variants: { variant: { default: '', outline: 'ui-button-outline', destructive: 'ui-button-destructive', ghost: 'ui-button-ghost', secondary: 'ui-button-secondary', link: 'ui-button-link' }, size: { default: '', sm: 'ui-button-sm', icon: 'ui-button-icon', xs: 'ui-button-xs', lg: 'ui-button-lg', 'icon-xs': 'ui-button-icon ui-button-icon-xs', 'icon-sm': 'ui-button-icon ui-button-icon-sm', 'icon-lg': 'ui-button-icon ui-button-icon-lg' } }, defaultVariants: { variant: 'default', size: 'default' } })

export interface ButtonProps extends ComponentProps<'button'>, VariantProps<typeof buttonVariants> { asChild?: boolean }

export function Button({ className, variant, size, asChild = false, ...props }: ButtonProps) {
  const Comp = asChild ? Slot : 'button'
  return <Comp data-slot="button" data-size={size ?? 'default'} className={cn(buttonVariants({ variant, size, className }))} {...props} />
}
