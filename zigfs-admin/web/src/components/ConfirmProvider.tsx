import { AlertTriangle } from 'lucide-react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

export interface ConfirmOptions {
  title: string
  message: string
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
  const [request, setRequest] = useState<ConfirmRequest | null>(null)
  const requestRef = useRef<ConfirmRequest | null>(null)
  const confirmButtonRef = useRef<HTMLButtonElement>(null)

  const confirm = useCallback<Confirm>((options) => new Promise((resolve) => {
    // A confirmation is modal and should never be silently orphaned if a
    // second request arrives before the first one has been answered.
    requestRef.current?.resolve(false)
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

  useEffect(() => {
    if (!request) return
    confirmButtonRef.current?.focus()
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') close(false)
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [close, request])

  useEffect(() => () => {
    requestRef.current?.resolve(false)
    requestRef.current = null
  }, [])

  const value = useMemo(() => confirm, [confirm])
  const portalTarget = document.querySelector('.app-shell') ?? document.body

  return (
    <ConfirmContext.Provider value={value}>
      {children}
      {request && createPortal(
        <div className="modal-backdrop confirm-backdrop" role="presentation" onMouseDown={() => close(false)}>
          <section
            className={`lifecycle-modal confirm-modal${request.options.danger ? ' danger' : ''}`}
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="confirm-dialog-title"
            aria-describedby="confirm-dialog-message"
            onMouseDown={(event) => event.stopPropagation()}
          >
            <header className="lifecycle-modal-header confirm-modal-header">
              <div className="lifecycle-modal-title">
                <AlertTriangle aria-hidden="true" />
                <h3 id="confirm-dialog-title">{request.options.title}</h3>
              </div>
            </header>
            <p className="confirm-modal-message" id="confirm-dialog-message">{request.options.message}</p>
            <footer className="lifecycle-modal-actions">
              <button className="secondary-button" type="button" onClick={() => close(false)}>
                {request.options.cancelLabel ?? '取消'}
              </button>
              {!request.options.hideConfirm && <button ref={confirmButtonRef} className={request.options.danger ? 'danger-button' : 'primary-button'} type="button" onClick={() => close(true)}>
                {request.options.confirmLabel ?? '确认'}
              </button>}
            </footer>
          </section>
        </div>,
        portalTarget,
      )}
    </ConfirmContext.Provider>
  )
}

export function useConfirm(): Confirm {
  const context = useContext(ConfirmContext)
  if (!context) throw new Error('useConfirm must be used within ConfirmProvider')
  return context
}
