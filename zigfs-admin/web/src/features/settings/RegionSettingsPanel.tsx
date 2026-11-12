import { useEffect, useState } from 'react'
import { t } from '@/locales'
import { ApiError, type ApiClient, type RegionSettings } from '../../api/client'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '../../components/ui/field'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../../components/ui/Card'
import { Alert, AlertDescription } from '../../components/ui/alert'
import { useToast } from '../../components/ToastProvider'

export function RegionSettingsPanel({ api, observedAt }: { api: ApiClient; observedAt: Date | null }) {
  const [saved, setSaved] = useState<RegionSettings | null>(null)
  const [region, setRegion] = useState('')
  const [busy, setBusy] = useState(false)
  const [invalid, setInvalid] = useState(false)
  const toast = useToast()
  function apply(value: RegionSettings) { setSaved(value); setRegion(value.pending_s3_region) }
  useEffect(() => {
    let active = true
    setBusy(true); setInvalid(false)
    api.regionSettings().then(value => { if (active) apply(value) }).catch(() => {
      if (active) { setSaved(null); toast(t('settings.regionLoadFailed'), 'error') }
    }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [api, observedAt, toast])
  return <Card className="system-settings-form"><CardHeader><CardTitle>{t('settings.defaultRegion')}</CardTitle><CardDescription>{t('settings.regionSaveHelp')}</CardDescription></CardHeader><CardContent>
    <form onSubmit={async event => {
      event.preventDefault()
      if (busy || !saved) return
      setInvalid(false)
      const next = region.trim()
      if (next.length < 1 || next.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(next)) {
        setInvalid(true); toast(t('settings.invalidRegion'), 'error'); return
      }
      setBusy(true)
      try {
        const value = await api.saveRegionSettings(next)
        apply(value)
        toast(t(value.restart_required ? 'settings.regionSavedRestart' : 'settings.regionSaved'))
      } catch (reason) {
        const bad = reason instanceof ApiError && reason.body.code === 'InvalidRegion'
        setInvalid(bad); toast(t(bad ? 'settings.invalidRegion' : 'settings.regionSaveFailed'), 'error')
      } finally { setBusy(false) }
    }}><FieldGroup>
      <Field><FieldLabel htmlFor="region-effective">{t('settings.currentRegion')}</FieldLabel><Input id="region-effective" readOnly value={saved?.s3_region ?? '—'} /></Field>
      <Field data-invalid={invalid}><FieldLabel htmlFor="region-draft">{t('settings.defaultRegion')}</FieldLabel><Input id="region-draft" disabled={busy || !saved} value={region} placeholder="us-east-1" onChange={e => { setRegion(e.target.value); setInvalid(false) }} aria-invalid={invalid} aria-describedby="region-help" /><FieldDescription id="region-help">{t('settings.regionFormatHelp')}</FieldDescription></Field>
      {saved?.restart_required && <Alert><AlertDescription>{t('settings.regionPending', { region: saved.pending_s3_region })}</AlertDescription></Alert>}
      <Button type="submit" disabled={busy || !saved || region.trim() === saved.pending_s3_region}>{t('settings.saveNetwork')}</Button>
    </FieldGroup></form>
  </CardContent></Card>
}
