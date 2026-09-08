import { CheckCircle2, X } from 'lucide-react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

interface ToastMessage {
  id: number
  message: string
}

type ShowToast = (message: string) => void

const ToastContext = createContext<ShowToast | null>(null)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<ToastMessage | null>(null)
  const nextId = useRef(1)

  const showToast = useCallback<ShowToast>((message) => {
    setToast({ id: nextId.current++, message })
  }, [])

  useEffect(() => {
    if (!toast) return
    const timer = window.setTimeout(() => setToast((current) => current?.id === toast.id ? null : current), 3200)
    return () => window.clearTimeout(timer)
  }, [toast])

  const value = useMemo(() => showToast, [showToast])
  const portalTarget = document.querySelector('.app-shell') ?? document.body

  return (
    <ToastContext.Provider value={value}>
      {children}
      {createPortal(<div className="toast-region" aria-live="polite" aria-atomic="true">
        {toast && (
          <div className="toast-message" role="status">
            <CheckCircle2 aria-hidden="true" />
            <span>{toast.message}</span>
            <button type="button" aria-label="关闭消息" onClick={() => setToast(null)}><X aria-hidden="true" /></button>
          </div>
        )}
      </div>, portalTarget)}
    </ToastContext.Provider>
  )
}

export function useToast(): ShowToast {
  const context = useContext(ToastContext)
  if (!context) throw new Error('useToast must be used within ToastProvider')
  return context
}
