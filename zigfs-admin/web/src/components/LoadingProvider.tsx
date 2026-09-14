import { LoaderCircle } from 'lucide-react'
import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

type LoadingTask = {
  id: number
  message: string
}

interface LoadingContextValue {
  startLoading: (message: string) => () => void
  withLoading: <T>(message: string, task: () => Promise<T>) => Promise<T>
}

const LoadingContext = createContext<LoadingContextValue | null>(null)

export function LoadingProvider({ children }: { children: ReactNode }) {
  const [tasks, setTasks] = useState<LoadingTask[]>([])
  const nextId = useRef(1)

  const start = useCallback((message: string) => {
    const task = { id: nextId.current++, message }
    setTasks((current) => [...current, task])
    return () => setTasks((current) => current.filter((item) => item.id !== task.id))
  }, [])

  const withLoading = useCallback<LoadingContextValue['withLoading']>(async (message, task) => {
    const stop = start(message)
    try {
      return await task()
    } finally {
      stop()
    }
  }, [start])

  const value = useMemo(() => ({ startLoading: start, withLoading }), [start, withLoading])
  const activeTask = tasks[tasks.length - 1]
  const portalTarget = document.querySelector('.app-shell') ?? document.body

  return (
    <LoadingContext.Provider value={value}>
      {children}
      {activeTask && createPortal(
        <div className="loading-backdrop" role="presentation">
          <section className="loading-modal" role="status" aria-live="polite" aria-busy="true" aria-label={activeTask.message}>
            <LoaderCircle className="loading-spinner" aria-hidden="true" />
            <span>{activeTask.message}</span>
          </section>
        </div>,
        portalTarget,
      )}
    </LoadingContext.Provider>
  )
}

export function useLoading(): LoadingContextValue {
  const context = useContext(LoadingContext)
  if (!context) throw new Error('useLoading must be used within LoadingProvider')
  return context
}
