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
    }).catch(error => { if (active) toast(error instanceof Error ? error.message : '无法加载 Bucket Policy', 'error') }).finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [api, bucketName, toast])
  async function save() {
    try { JSON.parse(document) } catch { toast('Policy JSON 格式无效', 'error'); return }
    setSaving(true)
    try {
      const result = await api.putBucketPolicy(bucketName, document)
      setSaved(result.document); setDocument(result.document)
      toast('Bucket Policy 已保存')
    } catch (error) { toast(error instanceof Error ? error.message : '保存失败', 'error') }
    finally { setSaving(false) }
  }
  async function remove() {
    if (!await confirm({ title: '删除 Bucket Policy', message: '删除后，这份资源策略提供的授权与拒绝都将移除。其他身份策略和匿名访问配置继续生效。', confirmLabel: '删除', danger: true })) return
    setSaving(true)
    try { await api.deleteBucketPolicy(bucketName); setSaved(''); setDocument(emptyDocument); toast('Bucket Policy 已删除') }
    catch (error) { toast(error instanceof Error ? error.message : '删除失败', 'error') }
    finally { setSaving(false) }
  }
  return <FieldGroup>
    <Field><FieldLabel htmlFor="bucket-policy-document">Bucket Policy</FieldLabel><FieldDescription>资源策略必须包含 Principal，Resource 只能指向当前桶及其对象。实际访问还会校验用户、Key 限制与请求条件。</FieldDescription><Textarea id="bucket-policy-document" rows={14} spellCheck={false} value={document} disabled={!ready || loading || saving} onChange={event => setDocument(event.target.value)} /></Field>
    <div className="flex gap-2"><Button disabled={!ready || loading || saving || document === saved} onClick={() => void save()}>Save Policy</Button><Button variant="destructive" disabled={!ready || loading || saving || !saved} onClick={() => void remove()}>Delete Policy</Button></div>
  </FieldGroup>
}
