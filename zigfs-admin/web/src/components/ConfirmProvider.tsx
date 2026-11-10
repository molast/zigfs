import { t, useLocale } from '@/locales'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Checkbox } from './ui/checkbox'
import { Field, FieldLabel } from './ui/field'
import { AlertDialog, AlertDialogContent, AlertDialogHeader, AlertDialogTitle, AlertDialogDescription, AlertDialogFooter, AlertDialogCancel, AlertDialogAction } from './ui/alert-dialog'

export interface ConfirmOptions {
  title: string
  message: string
  details?: string
  checkbox?: { label: string; onCheckedChange: (checked: boolean) => void }
  confirmLabel?: string
  cancelLabel?: string
  danger?: boolean
  hideConfirm?: boolean
}

type ConfirmRequest = {
  options: ConfirmOptions
  resolve: (confirmed: boolean) => void
}

type Confirm = (options: ConfirmOptions) => Promise<boolean>

const ConfirmContext = createContext<Confirm | null>(null)

export function ConfirmProvider({ children }: { children: ReactNode }) {
  useLocale()
  const [checked, setChecked] = useState(false)
  const [request, setRequest] = useState<ConfirmRequest | null>(null)
  const requestRef = useRef<ConfirmRequest | null>(null)

  const confirm = useCallback<Confirm>((options) => new Promise((resolve) => {
    // A confirmation is modal and should never be silently orphaned if a
    // second request arrives before the first one has been answered.
    requestRef.current?.resolve(false)
    setChecked(false)
    const next = { options, resolve }
    requestRef.current = next
    setRequest(next)
  }), [])

  const close = useCallback((confirmed: boolean) => {
    const current = requestRef.current
    if (!current) return
    requestRef.current = null
    current.resolve(confirmed)
    setRequest(null)
  }, [])

  useEffect(() => () => {
    requestRef.current?.resolve(false)
    requestRef.current = null
  }, [])

  const value = useMemo(() => confirm, [confirm])

  return (
    <ConfirmContext.Provider value={value}>
      {children}
      <AlertDialog open={Boolean(request)} onOpenChange={open => { if (!open) close(false) }}>
        {request && <AlertDialogContent>
          <AlertDialogHeader><AlertDialogTitle>{request.options.title}</AlertDialogTitle><AlertDialogDescription>{request.options.message}</AlertDialogDescription></AlertDialogHeader>
          {request.options.details && <p className="break-all font-mono text-sm">{request.options.details}</p>}
          {request.options.checkbox && <Field orientation="horizontal">
            <Checkbox id="confirm-option" checked={checked} onCheckedChange={value => { setChecked(value === true); request.options.checkbox?.onCheckedChange(value === true) }} />
            <FieldLabel htmlFor="confirm-option">{request.options.checkbox.label}</FieldLabel>
          </Field>}
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => close(false)}>{request.options.cancelLabel ?? t('common.cancel')}</AlertDialogCancel>
            {!request.options.hideConfirm && <AlertDialogAction variant={request.options.danger ? 'destructive' : 'default'} onClick={() => close(true)}>{request.options.confirmLabel ?? t('common.confirm')}</AlertDialogAction>}
          </AlertDialogFooter>
        </AlertDialogContent>}
      </AlertDialog>
    </ConfirmContext.Provider>
  )
}

export function useConfirm(): Confirm {
  const context = useContext(ConfirmContext)
  if (!context) throw new Error('useConfirm must be used within ConfirmProvider')
  return context
}
