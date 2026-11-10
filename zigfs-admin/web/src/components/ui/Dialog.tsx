import { t } from '@/locales'
import * as DialogPrimitive from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import type { ComponentPropsWithoutRef } from 'react'
import { cn } from '@/lib/utils'

export const Dialog = DialogPrimitive.Root
export const DialogTrigger = DialogPrimitive.Trigger
export const DialogClose = DialogPrimitive.Close
export function DialogDescription({ className, ...props }: ComponentPropsWithoutRef<typeof DialogPrimitive.Description>) {
  return <DialogPrimitive.Description className={cn('ui-dialog-description', className)} {...props} />
}

export function DialogContent({ className, children, showCloseButton = true, layout = 'default', ...props }: ComponentPropsWithoutRef<typeof DialogPrimitive.Content> & { showCloseButton?: boolean; layout?: 'default' | 'form' }) {
  return <DialogPrimitive.Portal><DialogPrimitive.Overlay className="ui-dialog-backdrop" /><DialogPrimitive.Content className={cn('ui-dialog-content', layout === 'form' && 'ui-dialog-form', className)} {...props}>{children}{showCloseButton && <DialogPrimitive.Close className="ui-dialog-close" aria-label={t('ui.close')}><X aria-hidden="true" /></DialogPrimitive.Close>}</DialogPrimitive.Content></DialogPrimitive.Portal>
}
export function DialogHeader({ className, ...props }: ComponentPropsWithoutRef<'div'>) { return <div className={cn('ui-dialog-header', className)} {...props} /> }
export function DialogTitle({ className, ...props }: ComponentPropsWithoutRef<typeof DialogPrimitive.Title>) { return <DialogPrimitive.Title className={cn('ui-dialog-title', className)} {...props} /> }
