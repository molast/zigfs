import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { ArrowDownUp, Copy, Download, Eye, History, Maximize2, Minimize2, RotateCcw, Tags, Trash2, X } from 'lucide-react'
import type { ApiClient } from '@/api/client'
import type { ObjectSummary, ObjectVersion, PresignObjectResponse } from '@/types/api'
import { t } from '@/locales'
import { formatDateTime } from '@/lib/dateTime'
import { cn } from '@/lib/utils'
import { useConfirm } from '@/components/ConfirmProvider'
import { useErrorToast, useToast } from '@/components/ToastProvider'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/Dialog'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/Tabs'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from '@/components/ui/table'
import { Badge } from '@/components/ui/Badge'
import { Switch } from '@/components/ui/switch'
import { Skeleton } from '@/components/ui/skeleton'
import { Empty, EmptyHeader, EmptyTitle, EmptyDescription } from '@/components/ui/empty'
import { InputGroup, InputGroupInput, InputGroupAddon, InputGroupButton } from '@/components/ui/input-group'
import { formatBytes } from './multipart-upload'

type Tag = { key: string; value: string }
type Preview = { url: string; versionId?: string }
interface Props {
  api: ApiClient
  bucket: string
  object: ObjectSummary
  versionId: string | null
  initialTagsOpen?: boolean
  onClose: () => void
  onChanged: () => Promise<void>
}

export function ObjectDetailsSheet({ api, bucket, object, versionId, initialTagsOpen = false, onClose, onChanged }: Props) {
  const notifyError = useErrorToast()
  const toast = useToast()
  const confirm = useConfirm()
  const alive = useRef(true)
  const tagsTrigger = useRef<HTMLButtonElement>(null)
  const versionsTrigger = useRef<HTMLButtonElement>(null)
  const previewTrigger = useRef<HTMLElement | null>(null)
  const [headers, setHeaders] = useState<Headers | null>(null)
  const [headLoading, setHeadLoading] = useState(true)
  const [headError, setHeadError] = useState('')
  const [summary, setSummary] = useState(object)
  const [legalHold, setLegalHold] = useState(object.legal_hold ?? false)
  const [busy, setBusy] = useState('')
  const [tagsOpen, setTagsOpen] = useState(false)
  const [tagsLoading, setTagsLoading] = useState(false)
  const [tagsError, setTagsError] = useState('')
  const [tags, setTags] = useState<Tag[]>([])
  const [tagDraft, setTagDraft] = useState<Tag>({ key: '', value: '' })
  const [invalidTag, setInvalidTag] = useState<'key' | 'value' | null>(null)
  const [versionsOpen, setVersionsOpen] = useState(false)
  const [versionsLoading, setVersionsLoading] = useState(false)
  const [versionsError, setVersionsError] = useState('')
  const [versions, setVersions] = useState<ObjectVersion[]>([])
  const [sort, setSort] = useState<{ field: 'last_modified' | 'size'; ascending: boolean }>({ field: 'last_modified', ascending: false })
  const [preview, setPreview] = useState<Preview | null>(null)
  const [previewError, setPreviewError] = useState(false)
  const [maximized, setMaximized] = useState(false)
  const [duration, setDuration] = useState({ days: '0', hours: '2', minutes: '0' })
  const [durationInvalid, setDurationInvalid] = useState(false)
  const [link, setLink] = useState<PresignObjectResponse | null>(null)
  const options = versionId === null ? {} : { versionId }
  const selectedVersionId = versionId ?? headers?.get('x-amz-version-id') ?? 'null'
  const contentType = headers?.get('content-type') ?? '—'
  const metadata = headers ? [...headers.entries()].filter(([key]) => key === 'content-type' || key.startsWith('x-amz-meta-')) : []
  const totalSeconds = Number(duration.days) * 86400 + Number(duration.hours) * 3600 + Number(duration.minutes) * 60

  const totalMinutes = Number.isFinite(totalSeconds) ? Math.max(0, Math.floor(totalSeconds / 60)) : 0
  const durationText = [
    { unit: 'days', value: Math.floor(totalMinutes / 1440) },
    { unit: 'hours', value: Math.floor(totalMinutes % 1440 / 60) },
    { unit: 'minutes', value: totalMinutes % 60 },
  ].filter(part => part.value > 0).map(part => `${part.value} ${t(`objectDetails.${part.unit}` as 'objectDetails.days' | 'objectDetails.hours' | 'objectDetails.minutes')}`).join(' ') || `0 ${t('objectDetails.minutes')}`

  useEffect(() => {
    alive.current = true
    const abort = new AbortController()
    if (initialTagsOpen) void loadTags()
    void (async () => {
      try {
        const signed = await api.presignObject('', bucket, object.key, 'HEAD', 900, versionId === null ? {} : { versionId })
        if (abort.signal.aborted) return
        const response = await fetch(signed.url, { method: 'HEAD', headers: signed.required_headers, credentials: 'omit', signal: abort.signal })
        if (!response.ok) throw new Error(t('objectDetails.requestFailed', { status: response.status }))
        setHeaders(response.headers)
      } catch (reason) {
        if (!abort.signal.aborted) setHeadError((reason as Error).message)
      } finally { if (!abort.signal.aborted) setHeadLoading(false) }
    })()
    return () => { alive.current = false; abort.abort() }
  }, [api, bucket, object.key, versionId, initialTagsOpen])

  async function run(name: string, action: () => Promise<void>) {
    if (busy) return
    setBusy(name)
    try { await action() } catch (reason) { if (alive.current) notifyError((reason as Error).message) }
    finally { if (alive.current) setBusy('') }
  }
  async function copy(value: string) {
    try { await navigator.clipboard.writeText(value); toast(t('objectDetails.copied')) }
    catch { notifyError(t('objectDetails.copyFailed')) }
  }
  async function download(id?: string) {
    await run('download', async () => {
      const signed = await api.presignObject('', bucket, object.key, 'GET', 900, { download: true, ...(id !== undefined ? { versionId: id } : options) })
      if (!alive.current) return
      const anchor = document.createElement('a')
      anchor.href = signed.url
      anchor.download = object.key.split('/').pop() || object.key
      anchor.target = '_blank'
      anchor.rel = 'noopener noreferrer'
      document.body.appendChild(anchor)
      anchor.click()
      anchor.remove()
    })
  }
  async function openPreview(id?: string) {
    previewTrigger.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    await run('preview', async () => {
      const signed = await api.presignObject('', bucket, object.key, 'GET', 900, id !== undefined ? { versionId: id } : options)
      if (!alive.current) return
      setPreviewError(false)
      setMaximized(false)
      setPreview({ url: signed.url, versionId: id })
    })
  }
  async function loadTags() {
    setTagsOpen(true)
    setTagsLoading(true)
    setTagsError('')
    setTagDraft({ key: '', value: '' })
    setInvalidTag(null)
    try {
      const signed = await api.presignObject('', bucket, object.key, 'GET', 900, { ...options, tagging: true })
      const response = await fetch(signed.url, { headers: signed.required_headers, credentials: 'omit' })
      await checkResponse(response)
      const xml = new DOMParser().parseFromString(await response.text(), 'application/xml')
      if (xml.querySelector('parsererror')) throw new Error(t('objectDetails.invalidTagsResponse'))
      const result = [...xml.querySelectorAll('Tag')].map(tag => ({ key: tag.querySelector('Key')?.textContent ?? '', value: tag.querySelector('Value')?.textContent ?? '' }))
      if (alive.current) setTags(result)
    } catch (reason) { if (alive.current) setTagsError((reason as Error).message) }
    finally { if (alive.current) setTagsLoading(false) }
  }
  async function saveTags(event: FormEvent) {
    event.preventDefault()
    if (tagsLoading || tagsError || busy) return
    const invalid = !tagDraft.key || new TextEncoder().encode(tagDraft.key).length > 128 || /[\u0000-\u001f\u007f]/.test(tagDraft.key) || tags.some(tag => tag.key === tagDraft.key)
      ? 'key'
      : new TextEncoder().encode(tagDraft.value).length > 256 || /[\u0000-\u001f\u007f]/.test(tagDraft.value) ? 'value' : null
    if (invalid) {
      setInvalidTag(invalid)
      document.getElementById(`object-tag-${invalid}`)?.focus()
      notifyError(t('objectDetails.invalidTag'))
      return
    }
    if (tags.length >= 10) {
      notifyError(t('objectDetails.tagLimit'))
      return
    }
    await run('tags', async () => {
      await persistTags([...tags, tagDraft])
      if (alive.current) {
        setTagDraft({ key: '', value: '' })
        setInvalidTag(null)
        toast(t('objects.objectTagsSaved'))
        requestAnimationFrame(() => { if (alive.current) document.getElementById('object-tag-key')?.focus() })
      }
    })
  }
  async function removeTag(key: string) {
    await run('tags', async () => {
      await persistTags(tags.filter(tag => tag.key !== key))
      if (alive.current) {
        setInvalidTag(null)
        toast(t('objects.objectTagsDeleted'))
      }
    })
  }
  async function persistTags(entries: Tag[]) {
    const method = entries.length ? 'PUT' : 'DELETE'
    const signed = await api.presignObject('', bucket, object.key, method, 900, { ...options, tagging: true })
    const response = await fetch(signed.url, {
      method, credentials: 'omit', headers: { ...signed.required_headers, ...(entries.length ? { 'content-type': 'application/xml' } : {}) },
      ...(entries.length ? { body: `<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet>${entries.map(tag => `<Tag><Key>${escapeXml(tag.key)}</Key><Value>${escapeXml(tag.value)}</Value></Tag>`).join('')}</TagSet></Tagging>` } : {}),
    })
    await checkResponse(response)
    if (alive.current) setTags(entries)
  }
  async function loadVersions() {
    setVersionsLoading(true)
    setVersionsError('')
    try {
      const result = await api.listObjectVersions(bucket, object.key)
      if (alive.current) {
        const matching = result.filter(version => version.key === object.key)
        setVersions(matching)
        const selected = matching.find(version => versionId === null ? version.is_latest : version.version_id === versionId)
        if (selected && !selected.is_delete_marker) {
          setSummary({ ...selected, etag: object.etag })
          setLegalHold(selected.legal_hold ?? false)
        }
      }
    } catch (reason) { if (alive.current) setVersionsError((reason as Error).message) }
    finally { if (alive.current) setVersionsLoading(false) }
  }
  async function mutateVersion(version: ObjectVersion, restore: boolean) {
    if (!await confirm({
      title: t(restore ? 'objectDetails.restoreVersion' : 'objects.permanentlyDeleteVersion'),
      message: t(restore ? 'objectDetails.restoreDescription' : 'objectDetails.deleteDescription'),
      confirmLabel: t(restore ? 'objects.restore' : 'objects.delete'), danger: !restore,
    })) return
    await run('version', async () => {
      const method = restore ? 'PUT' : 'DELETE'
      const signed = await api.presignObject('', bucket, object.key, method, 900, restore
        ? { copySource: { bucket, key: object.key, versionId: version.version_id } }
        : { versionId: version.version_id })
      const response = await fetch(signed.url, { method, headers: signed.required_headers, credentials: 'omit' })
      await checkResponse(response)
      // S3 CopyObject can report an error in a successful HTTP response.
      if (restore) {
        const xml = new DOMParser().parseFromString(await response.text(), 'application/xml')
        if (!xml.querySelector('CopyObjectResult') || xml.querySelector('Error, parsererror')) throw new Error(t('objectDetails.restoreFailed'))
      }
      if (!alive.current) return
      toast(t(restore ? 'objectDetails.restored' : 'objectDetails.deleted'))
      await loadVersions()
      await onChanged()
      // Current object details may have changed; keep the versions dialog visible.
      if (versionId === null) {
        const head = await api.presignObject('', bucket, object.key, 'HEAD', 900)
        const response = await fetch(head.url, { method: 'HEAD', credentials: 'omit' })
        if (alive.current) {
          setHeaders(response.ok ? response.headers : null)
          setHeadError(response.ok ? '' : t('objectDetails.currentUnavailable'))
          setLink(null)
        }
      } else if (!restore && version.version_id === versionId) { onClose() }
    })
  }
  async function generateLink(event: FormEvent) {
    event.preventDefault()
    if (Object.values(duration).some(value => !/^\d+$/.test(value)) || totalSeconds <= 0 || totalSeconds > 604800) {
      setDurationInvalid(true)
      notifyError(t('objectDetails.invalidDuration'))
      return
    }
    setDurationInvalid(false)
    await run('link', async () => {
      const signed = await api.presignObject('', bucket, object.key, 'GET', totalSeconds, options)
      if (alive.current) setLink(signed)
    })
  }
  const sortedVersions = [...versions].sort((a, b) => {
    const delta = sort.field === 'size' ? a.size - b.size : Date.parse(a.last_modified) - Date.parse(b.last_modified)
    return sort.ascending ? delta : -delta
  })
  function sortBy(field: 'size' | 'last_modified') {
    setSort(current => ({ field, ascending: current.field === field ? !current.ascending : false }))
  }
  function row(label: string, value: ReactNode) {
    return <div><dt>{label}</dt><dd>{value}</dd></div>
  }

  return <Sheet open onOpenChange={open => { if (!open && !busy) onClose() }}>
    <SheetContent className="object-details-sheet" onInteractOutside={event => { if (busy) event.preventDefault() }}>
      <SheetHeader><SheetTitle>{t('objects.objectDetails')}</SheetTitle><SheetDescription className="break-all">{object.key}</SheetDescription></SheetHeader>
      <div className="object-details-body">
        <div className="object-details-toolbar">
          <Button variant="outline" size="sm" disabled={!!busy} onClick={() => void download()}><Download data-icon="inline-start" />{t('objects.download')}</Button>
          <Button variant="outline" size="sm" disabled={!!busy} onClick={() => void openPreview()}><Eye data-icon="inline-start" />{t('objectDetails.preview')}</Button>
          <Button ref={tagsTrigger} variant="outline" size="sm" disabled={!!busy || tagsLoading} onClick={() => void loadTags()}><Tags data-icon="inline-start" />{t('objectDetails.setTags')}</Button>
          <Button ref={versionsTrigger} variant="outline" size="sm" disabled={!!busy} onClick={() => { setVersionsOpen(true); void loadVersions() }}><History data-icon="inline-start" />{t('objectDetails.versions')}</Button>
        </div>
        <Tabs defaultValue="information" className="object-details-tabs">
          <TabsList><TabsTrigger value="information">{t('objectDetails.information')}</TabsTrigger><TabsTrigger value="metadata">{t('objectDetails.metadata')}</TabsTrigger></TabsList>
          <TabsContent value="information">
            <dl className="object-details-list">
              {row(t('objectDetails.name'), <span className="object-details-copy"><span>{object.key}</span><Button variant="ghost" size="icon-xs" aria-label={t('objectDetails.copyName')} onClick={() => void copy(object.key)}><Copy /></Button></span>)}
              {row(t('objects.size'), formatBytes(headers?.has('content-length') ? Number(headers.get('content-length')) : summary.size))}
              {row(t('objectDetails.contentType'), headLoading ? <Skeleton className="h-4 w-32" /> : contentType)}
              {row('ETag', <code>{headers?.get('etag')?.replace(/^"|"$/g, '') || object.etag || '—'}</code>)}
              {row(t('objects.modified'), formatDateTime(headers?.get('last-modified') || summary.last_modified))}
              {row(t('objectDetails.legalHold'), <Switch size="sm" checked={legalHold} disabled={!!busy || headLoading || !!headError} aria-label={t('objectDetails.legalHold')} onCheckedChange={enabled => void run('hold', async () => {
                const result = await api.setObjectLegalHold(bucket, object.key, selectedVersionId, enabled)
                if (alive.current) setLegalHold(result.legal_hold)
                await onChanged()
              })} />)}
              {row(t('objectDetails.retention'), summary.retention_until_unix_seconds ? <span>{summary.retention_mode}<br />{formatDateTime(new Date(summary.retention_until_unix_seconds * 1000).toISOString())}</span> : t('objectDetails.notConfigured'))}
            </dl>
          </TabsContent>
          <TabsContent value="metadata">
            {headLoading ? <Skeleton className="m-4 h-20" /> : <dl className="object-details-list">{metadata.map(([key, value]) => <div key={key}><dt>{key === 'content-type' ? 'Content-Type' : key}</dt><dd>{value}</dd></div>)}{!metadata.length && row(t('objectDetails.metadata'), '—')}</dl>}
          </TabsContent>
        </Tabs>
        {headError && <p className="object-details-error" role="alert">{headError}</p>}
        <form className="object-details-link" onSubmit={event => void generateLink(event)} noValidate>
          <h3>{t('objectDetails.linkDuration')}</h3>
          <FieldGroup density="compact">
            <div className="object-details-duration">
              {(['days', 'hours', 'minutes'] as const).map((unit, index) => <Field key={unit} orientation="horizontal" data-invalid={durationInvalid && index === 0}>
                <Input id={`link-${unit}`} type="number" min="0" step="1" value={duration[unit]} aria-invalid={durationInvalid && index === 0} onChange={event => { setDuration(current => ({ ...current, [unit]: event.target.value })); setDurationInvalid(false) }} />
                <FieldLabel htmlFor={`link-${unit}`}>{t(`objectDetails.${unit}`)}</FieldLabel>
              </Field>)}
              <Button type="submit" size="sm" disabled={!!busy}>{t('objectDetails.generateLink')}</Button>
            </div>
            <FieldDescription>{t('objectDetails.totalDuration', { duration: durationText })}</FieldDescription>
            <Field><FieldLabel htmlFor="object-generated-link">{t('objectDetails.link')}</FieldLabel><InputGroup><InputGroupInput id="object-generated-link" readOnly value={link?.url ?? ''} placeholder={t('objectDetails.linkPlaceholder')} /><InputGroupAddon align="inline-end"><InputGroupButton size="icon-xs" aria-label={t('objects.copyLink')} disabled={!link} onClick={() => link && void copy(link.url)}><Copy /></InputGroupButton></InputGroupAddon></InputGroup>
              <FieldDescription>{link ? t('objectDetails.expiry', { date: formatDateTime(link.expires_at) }) : t('objectDetails.linkHelp')}</FieldDescription>
            </Field>
          </FieldGroup>
        </form>
      </div>
      <Dialog open={tagsOpen} onOpenChange={open => { if (busy !== 'tags') setTagsOpen(open) }}><DialogContent layout="form" className="object-tags-dialog" onCloseAutoFocus={event => { event.preventDefault(); tagsTrigger.current?.focus() }}>
        <DialogHeader><DialogTitle>{t('objectDetails.setTags')}</DialogTitle><DialogDescription className="sr-only">{object.key}</DialogDescription></DialogHeader>
        {tagsLoading ? <Skeleton className="h-20" /> : tagsError ? <Empty><EmptyHeader><EmptyTitle>{t('objectDetails.loadFailed')}</EmptyTitle><EmptyDescription>{tagsError}</EmptyDescription></EmptyHeader><Button variant="outline" onClick={() => void loadTags()}>{t('objectDetails.retry')}</Button></Empty> : <form onSubmit={event => void saveTags(event)} noValidate>
          {tags.length > 0 && <div className="object-tag-chips" aria-label={t('objectDetails.setTags')}>
            {tags.map(tag => <Badge className="object-tag-chip" key={tag.key}>
              <span>{tag.key}: {tag.value}</span>
              <Button type="button" variant="ghost" size="icon-xs" disabled={!!busy} aria-label={t('objectDetails.removeTag', { key: tag.key })} onClick={() => void removeTag(tag.key)}><X /></Button>
            </Badge>)}
          </div>}
          <FieldGroup density="compact" className="object-tag-fields">
            <Field data-invalid={invalidTag === 'key'}>
              <FieldLabel htmlFor="object-tag-key">{t('objectDetails.tagKey')}</FieldLabel>
              <Input id="object-tag-key" autoFocus value={tagDraft.key} placeholder={t('objectDetails.tagKeyPlaceholder')} aria-invalid={invalidTag === 'key'} disabled={!!busy} onChange={event => { setInvalidTag(null); setTagDraft(current => ({ ...current, key: event.target.value })) }} />
            </Field>
            <Field data-invalid={invalidTag === 'value'}>
              <FieldLabel htmlFor="object-tag-value">{t('objectDetails.tagValue')}</FieldLabel>
              <Input id="object-tag-value" value={tagDraft.value} placeholder={t('objectDetails.tagValuePlaceholder')} aria-invalid={invalidTag === 'value'} disabled={!!busy} onChange={event => { setInvalidTag(null); setTagDraft(current => ({ ...current, value: event.target.value })) }} />
            </Field>
          </FieldGroup>
          <footer className="object-dialog-footer"><Button type="submit" disabled={!!busy}>{t('objectDetails.add')}</Button></footer>
        </form>}
      </DialogContent></Dialog>
      <Dialog open={versionsOpen} onOpenChange={open => { if (!busy) setVersionsOpen(open) }}><DialogContent className="object-versions-dialog" onCloseAutoFocus={event => { event.preventDefault(); versionsTrigger.current?.focus() }}>
        <DialogHeader><DialogTitle>{t('objectDetails.objectVersions')}</DialogTitle><DialogDescription className="sr-only">{object.key}</DialogDescription></DialogHeader>
        {versionsLoading ? <Skeleton className="h-32" /> : versionsError ? <Empty><EmptyHeader><EmptyTitle>{t('objectDetails.loadFailed')}</EmptyTitle><EmptyDescription>{versionsError}</EmptyDescription></EmptyHeader><Button variant="outline" onClick={() => void loadVersions()}>{t('objectDetails.retry')}</Button></Empty> : <>
          <div className="object-versions-summary"><span>{t('objectDetails.versionCount')}: <strong>{versions.length}</strong></span><span>{t('objectDetails.totalSize')}: <strong>{formatBytes(versions.reduce((total, version) => total + (version.is_delete_marker ? 0 : version.size), 0))}</strong></span></div>
          <Table><colgroup><col className="object-version-column-id" /><col className="object-version-column-modified" /><col className="object-version-column-size" /><col className="object-version-column-actions" /></colgroup><TableHeader><TableRow><TableHead>{t('objectDetails.versionId')}</TableHead><TableHead aria-sort={sort.field === 'last_modified' ? sort.ascending ? 'ascending' : 'descending' : 'none'}><Button variant="ghost" size="sm" onClick={() => sortBy('last_modified')}>{t('objectDetails.lastModified')}<ArrowDownUp data-icon="inline-end" /></Button></TableHead><TableHead aria-sort={sort.field === 'size' ? sort.ascending ? 'ascending' : 'descending' : 'none'}><Button variant="ghost" size="sm" onClick={() => sortBy('size')}>{t('objects.size')}<ArrowDownUp data-icon="inline-end" /></Button></TableHead><TableHead>{t('objectDetails.actions')}</TableHead></TableRow></TableHeader><TableBody>
            {sortedVersions.map(version => <TableRow key={version.version_id}><TableCell><div className="object-version-id"><code>{version.version_id}</code><Button variant="ghost" size="icon-xs" aria-label={t('objectDetails.copyVersion')} onClick={() => void copy(version.version_id)}><Copy /></Button>{version.is_latest && <Badge>{t('objectDetails.current')}</Badge>}{version.is_delete_marker && <Badge>{t('objectDetails.deleteMarker')}</Badge>}</div></TableCell><TableCell>{formatDateTime(version.last_modified)}</TableCell><TableCell>{version.is_delete_marker ? '—' : formatBytes(version.size)}</TableCell><TableCell><div className="object-version-actions">
              {!version.is_delete_marker && <><Button variant="outline" size="sm" disabled={!!busy} onClick={() => void openPreview(version.version_id)}><Eye data-icon="inline-start" />{t('objectDetails.preview')}</Button>{!version.is_latest && <Button variant="outline" size="sm" disabled={!!busy} onClick={() => void mutateVersion(version, true)}><RotateCcw data-icon="inline-start" />{t('objects.restore')}</Button>}<Button variant="outline" size="sm" disabled={!!busy} onClick={() => void download(version.version_id)}><Download data-icon="inline-start" />{t('objects.download')}</Button></>}
              <Button variant="destructive" size="sm" disabled={!!busy} onClick={() => void mutateVersion(version, false)}><Trash2 data-icon="inline-start" />{t('objects.delete')}</Button>
            </div></TableCell></TableRow>)}{!versions.length && <TableRow><TableCell colSpan={4}>{t('objectDetails.noVersions')}</TableCell></TableRow>}
          </TableBody></Table>
        </>}
      </DialogContent></Dialog>
      <Dialog open={preview !== null} onOpenChange={open => { if (!open) setPreview(null) }}><DialogContent className={cn('object-preview-dialog', maximized && 'object-preview-maximized')} onCloseAutoFocus={event => { if (previewTrigger.current?.isConnected) { event.preventDefault(); previewTrigger.current.focus() } }}>
        <DialogHeader><DialogTitle>{t('objectDetails.preview')}</DialogTitle><DialogDescription>{object.key}</DialogDescription></DialogHeader>
        <Button className="object-preview-expand" size="icon-sm" variant="ghost" aria-label={t(maximized ? 'objectDetails.minimize' : 'objectDetails.maximize')} onClick={() => setMaximized(value => !value)}>{maximized ? <Minimize2 /> : <Maximize2 />}</Button>
        <div className="object-preview-content">{preview && (/\.(avif|bmp|gif|jpe?g|png|svg|webp)$/i.test(object.key) || contentType.startsWith('image/')) && !previewError ? <img src={preview.url} alt={object.key} onError={() => setPreviewError(true)} /> : <Empty><EmptyHeader><EmptyTitle>{t('objects.previewIsNotAvailableForThisFormat')}</EmptyTitle><EmptyDescription>{t('objectDetails.downloadToView')}</EmptyDescription></EmptyHeader><Button variant="outline" disabled={!!busy} onClick={() => void download(preview?.versionId)}><Download data-icon="inline-start" />{t('objects.download')}</Button></Empty>}</div>
      </DialogContent></Dialog>
    </SheetContent>
  </Sheet>
}

async function checkResponse(response: Response) {
  if (response.ok) return
  throw new Error(t('objectDetails.requestFailed', { status: response.status }))
}
function escapeXml(value: string) {
  return value.replace(/[<>&'\"]/g, character => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[character] ?? character))
}
