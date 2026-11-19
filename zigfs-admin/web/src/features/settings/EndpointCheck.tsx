import { useEffect, useRef, useState } from 'react'
import { Check, LoaderCircle, X } from 'lucide-react'
import { Button } from '@/components/ui/Button'
import { useErrorToast } from '@/components/ToastProvider'
import { t } from '@/locales'
import { checkEndpointFromBrowser } from './networkProbe'

interface EndpointCheckProps {
  endpoint: string
  deploymentId?: string
  disabled?: boolean
}

export function EndpointCheck(props: EndpointCheckProps) {
  // A changed address or deployment must never retain an earlier result.
  return <EndpointCheckState key={`${props.endpoint}:${props.deploymentId ?? ''}`} {...props} />
}

function EndpointCheckState({ endpoint, deploymentId, disabled }: EndpointCheckProps) {
  const [status, setStatus] = useState<'idle' | 'checking' | 'success' | 'error'>('idle')
  const request = useRef<AbortController | null>(null)
  const errorToast = useErrorToast()

  useEffect(() => () => request.current?.abort(), [])

  async function check() {
    if (request.current) return
    const controller = new AbortController()
    request.current = controller
    setStatus('checking')
    try {
      await checkEndpointFromBrowser(endpoint, controller.signal, deploymentId)
      if (!controller.signal.aborted) setStatus('success')
    } catch {
      if (!controller.signal.aborted) {
        setStatus('error')
        errorToast(t('settings.endpointCheckFailed'))
      }
    } finally {
      request.current = null
    }
  }

  const checking = status === 'checking'
  return (
    <div className="flex shrink-0 items-center gap-2">
      <Button
        type="button"
        variant="outline"
        size="sm"
        disabled={disabled || !endpoint.trim() || checking}
        aria-label={t('settings.checkEndpoint', { endpoint })}
        onClick={() => void check()}
      >
        {checking && <LoaderCircle data-icon="inline-start" className="animate-spin" />}
        {t(checking ? 'settings.endpointChecking' : 'settings.endpointCheck')}
      </Button>
      <span role="status" aria-live="polite">
        {status === 'success' && (
          <Check className="size-5 text-[var(--success)]" aria-hidden="true" />
        )}
        {status === 'error' && <X className="size-5 text-destructive" aria-hidden="true" />}
        <span className="sr-only">
          {status === 'success' && t('settings.endpointReachable')}
          {status === 'error' && t('settings.endpointUnreachable')}
        </span>
      </span>
    </div>
  )
}
