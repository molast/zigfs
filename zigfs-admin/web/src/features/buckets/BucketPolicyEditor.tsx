import { t } from '@/locales'
import { useEffect, useState } from 'react'
import type { ApiClient } from '../../api/client'
import { Button } from '../../components/ui/Button'
import { Textarea } from '../../components/ui/Textarea'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { useToast } from '../../components/ToastProvider'
import { useConfirm } from '../../components/ConfirmProvider'

const emptyDocument = JSON.stringify({ Version: '2012-10-17', Statement: [] }, null, 2)

export function BucketPolicyEditor({ api, bucketName }: { api: ApiClient; bucketName: string }) {
  const toast = useToast()
  const confirm = useConfirm()
  const [document, setDocument] = useState(emptyDocument)
  const [saved, setSaved] = useState('')
  const [loading, setLoading] = useState(true)
  const [ready, setReady] = useState(false)
  const [saving, setSaving] = useState(false)
  useEffect(() => {
    let active = true
    setLoading(true); setReady(false)
    api.getBucketPolicy(bucketName).then(value => {
      if (active) { setReady(true); setSaved(value.document); setDocument(value.document || emptyDocument) }
    }).catch(error => { if (active) toast(error instanceof Error ? error.message : t('buckets.unableToLoadBucketPolicy'), 'error') }).finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [api, bucketName, toast])
  async function save() {
    try { JSON.parse(document) } catch { toast(t('buckets.invalidPolicyJson'), 'error'); return }
    setSaving(true)
    try {
      const result = await api.putBucketPolicy(bucketName, document)
      setSaved(result.document); setDocument(result.document)
      toast(t('buckets.bucketPolicySaved'))
    } catch (error) { toast(error instanceof Error ? error.message : t('buckets.saveFailed'), 'error') }
    finally { setSaving(false) }
  }
  async function remove() {
    if (!await confirm({ title: t('buckets.deleteBucketPolicy'), message: t('buckets.deletingThisResourcePolicyRemovesItsGrantsAndDenials'), confirmLabel: t('buckets.delete'), danger: true })) return
    setSaving(true)
    try { await api.deleteBucketPolicy(bucketName); setSaved(''); setDocument(emptyDocument); toast(t('buckets.bucketPolicyDeleted')) }
    catch (error) { toast(error instanceof Error ? error.message : t('buckets.deletionFailed'), 'error') }
    finally { setSaving(false) }
  }
  return <FieldGroup>
    <Field><FieldLabel htmlFor="bucket-policy-document">{t('buckets.bucketPolicy')}</FieldLabel><FieldDescription>{t('buckets.resourcePoliciesRequirePrincipalAndMustTargetThisBucket')}</FieldDescription><Textarea id="bucket-policy-document" rows={14} spellCheck={false} value={document} disabled={!ready || loading || saving} onChange={event => setDocument(event.target.value)} /></Field>
    <div className="flex gap-2"><Button disabled={!ready || loading || saving || document === saved} onClick={() => void save()}>{t('buckets.savePolicy')}</Button><Button variant="destructive" disabled={!ready || loading || saving || !saved} onClick={() => void remove()}>{t('buckets.deletePolicy')}</Button></div>
  </FieldGroup>
}
