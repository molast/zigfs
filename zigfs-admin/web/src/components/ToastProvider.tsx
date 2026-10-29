import { useEffect, useState, type ReactNode } from 'react'
import { toast } from 'sonner'
import { Toaster } from './ui/sonner'

type ShowToast = (message: string, variant?: 'success' | 'error') => void

const showToast: ShowToast = (message, variant = 'success') => {
  if (message) toast[variant](message, { duration: variant === 'error' ? 6000 : 3200 })
}
const showErrorToast = (message: string) => showToast(message, 'error')

export function ToastProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<'light' | 'dark'>(() => document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light')
  useEffect(() => {
    const updateTheme = () => setTheme(document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light')
    updateTheme()
    const observer = new MutationObserver(updateTheme)
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
    return () => observer.disconnect()
  }, [])

  return <>{children}<Toaster theme={theme} position="top-center" richColors closeButton /></>
}

export function useToast(): ShowToast {
  return showToast
}

export function useErrorToast(): (message: string) => void {
  return showErrorToast
}
