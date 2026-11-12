import { formatDateTime } from '@/lib/dateTime'
import { t, getFormatLocale } from '@/locales'
import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { Settings, Folder, Trash2, ArrowUpDown, ArrowUp, ArrowDown } from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import { ToolbarControls, ToolbarCreateButton, ToolbarRefreshButton, ToolbarSearch } from '../../components/ui/ToolbarControls'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Input } from '../../components/ui/Input'
import { Switch } from '../../components/ui/switch'
import { RadioGroup, RadioGroupItem } from '../../components/ui/radio-group'
import { Button } from '../../components/ui/Button'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '../../components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import type { Bucket, BucketConfiguration, BucketUsage } from '../../types/api'

type BucketRow = Bucket & { usage?: BucketUsage; accessPolicy?: BucketConfiguration['access_policy'] }
type SortField = 'name' | 'created_at' | 'objects' | 'bytes' | 'accessPolicy'

interface BucketsViewProps {
  api: ApiClient
  onOpenBucket: (name: string) => void
  onOpenObjects: (name: string) => void
}

export function BucketsView({ api, onOpenBucket, onOpenObjects }: BucketsViewProps) {
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [buckets, setBuckets] = useState<BucketRow[]>([])
  const [sort, setSort] = useState<{ field: SortField; direction: 1 | -1 } | null>(null)
  const [name, setName] = useState('')
  const [versioning, setVersioning] = useState(false)
  const [objectLocking, setObjectLocking] = useState(false)
  const [quotaEnabled, setQuotaEnabled] = useState(false)
  const [maxBytes, setMaxBytes] = useState('1')
  const [quotaUnit, setQuotaUnit] = useState('GiB')
  const [retention, setRetention] = useState(false)
  const [retentionMode, setRetentionMode] = useState<'COMPLIANCE' | 'GOVERNANCE'>('COMPLIANCE')
  const [validity, setValidity] = useState('180')
  const [validityUnit, setValidityUnit] = useState('day')
  const [creating, setCreating] = useState(false)
  const [maxObjects, setMaxObjects] = useState('')
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    const stopLoading = startLoading(t('buckets.loadingBuckets'))
    try {
      setRefreshing(true)
      const items = await api.listBuckets()
      setBuckets(items)
      let detailsFailed = false
      // Bound concurrent requests when an account has many buckets.
      for (let offset = 0; offset < items.length; offset += 5) {
        const rows = await Promise.all(items.slice(offset, offset + 5).map(async (bucket): Promise<BucketRow> => {
          const [usage, configuration] = await Promise.allSettled([
            api.getBucketUsage(bucket.name),
            api.getBucketConfiguration(bucket.name),
          ])
          if (usage.status === 'rejected' || configuration.status === 'rejected') detailsFailed = true
          return {
            ...bucket,
            usage: usage.status === 'fulfilled' ? usage.value : undefined,
            accessPolicy: configuration.status === 'fulfilled' ? configuration.value.access_policy : undefined,
          }
        }))
        setBuckets(current => current.map(bucket => rows.find(row => row.name === bucket.name) ?? bucket))
      }
      if (detailsFailed) notifyError(t('buckets.listDetailsUnavailable'))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setRefreshing(false)
      stopLoading()
    }
  }, [api, startLoading])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filteredBuckets = useMemo(() => {
    const needle = query.trim().toLowerCase()
    const filtered = buckets.filter((bucket) => !needle || bucket.name.toLowerCase().includes(needle) || bucket.owner.toLowerCase().includes(needle))
    if (!sort) return filtered
    const value = (bucket: BucketRow) => {
      if (sort.field === 'objects' || sort.field === 'bytes') return bucket.usage?.[sort.field]
      if (sort.field === 'created_at') return new Date(bucket.created_at).getTime()
      return bucket[sort.field]
    }
    return filtered.sort((a, b) => {
      const left = value(a)
      const right = value(b)
      if (left === undefined) return right === undefined ? 0 : 1
      if (right === undefined) return -1
      return (typeof left === 'number' && typeof right === 'number' ? left - right : String(left).localeCompare(String(right), getFormatLocale())) * sort.direction
    })
  }, [buckets, query, sort])

  function sortHeader(field: SortField, label: string) {
    const active = sort?.field === field
    const Icon = active ? sort.direction === 1 ? ArrowUp : ArrowDown : ArrowUpDown
    return <TableHead aria-sort={active ? sort.direction === 1 ? 'ascending' : 'descending' : 'none'}>
      <Button variant="ghost" size="sm" onClick={() => setSort({ field, direction: active && sort.direction === 1 ? -1 : 1 })}>
        {label}<Icon data-icon="inline-end" aria-hidden="true" />
      </Button>
    </TableHead>
  }

  async function create(event: FormEvent) {
    event.preventDefault()
    const bytes = Number(maxBytes) * 1024 ** ({ MiB: 2, GiB: 3, TiB: 4, PiB: 5 }[quotaUnit] ?? 3)
    const duration = Number(validity) * 86400 * (validityUnit === 'year' ? 365 : 1)
    if (quotaEnabled && (!Number.isSafeInteger(bytes) || bytes <= 0)) { notifyError(t('buckets.valueMustBeAnIntegerGreaterThanZero', { '0': t('buckets.byteQuota') })); return }
    if (quotaEnabled && maxObjects && (!Number.isSafeInteger(Number(maxObjects)) || Number(maxObjects) <= 0)) { notifyError(t('buckets.valueMustBeAnIntegerGreaterThanZero', { '0': t('buckets.objectCountQuota') })); return }
    if (objectLocking && retention && (!Number.isSafeInteger(Number(validity)) || !Number.isSafeInteger(duration) || duration <= 0)) { notifyError(t('buckets.valueMustBeAnIntegerGreaterThanZero', { '0': t('buckets.duration') })); return }
    setCreating(true)
    const stopLoading = startLoading(t('buckets.creatingBucket'))
    try {
      const createdName = name.trim()
      await api.createBucket({ name: createdName, versioning: versioning || objectLocking, object_locking: objectLocking, ...(quotaEnabled && maxBytes ? { max_bytes: bytes } : {}), ...(quotaEnabled && maxObjects ? { max_objects: Number(maxObjects) } : {}) })
      let retentionFailed = false
      if (objectLocking && retention) {
        try {
          await api.updateBucketConfiguration(createdName, { retention_enabled: true, retention_duration_seconds: duration, retention_mode: retentionMode })
        } catch (reason) {
          retentionFailed = true
          notifyError(t('buckets.createdButRetentionFailed', { name: createdName, error: (reason as Error).message }))
        }
      }
      setName('')
      setVersioning(false)
      setObjectLocking(false)
      setQuotaEnabled(false)
      setMaxBytes('1'); setMaxObjects(''); setQuotaUnit('GiB'); setRetention(false); setRetentionMode('COMPLIANCE'); setValidity('180'); setValidityUnit('day')
      setShowCreate(false)
      await refresh()
      if (!retentionFailed) showToast(t('buckets.createdBucketValue', { '0': createdName }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
      setCreating(false)
      stopLoading()
    }
  }

  async function remove(bucket: string) {
    if (!await confirm({
      title: t('buckets.deleteBucket'),
      message: t('buckets.deleteBucketValueThisCannotBeUndone', { '0': bucket }),
      confirmLabel: t('buckets.delete'),
      danger: true,
    })) return
    const stopLoading = startLoading(t('buckets.deletingBucket'))
    try {
      await api.deleteBucket(bucket)
      await refresh()
      showToast(t('buckets.deletedBucketValue', { '0': bucket }))
    } catch (reason) {
      if (reason instanceof ApiError && reason.body.code === 'BucketNotEmpty') {
        stopLoading()
        await confirm({
          title: t('buckets.unableToDeleteBucket'),
          message: t('buckets.bucketValueMustBeEmptyBeforeDeletionDeleteIts', { '0': bucket }),
          cancelLabel: t('buckets.gotIt'),
          hideConfirm: true,
        })
      } else {
        notifyError((reason as Error).message)
      }
    } finally {
      stopLoading()
    }
  }

  return (
    <section>
      <header className="page-header buckets-header">
        <h2>{t('common.buckets')}</h2>
        <ToolbarControls className="buckets-header-actions">
          <ToolbarSearch label={t('buckets.searchBuckets')} placeholder={t('buckets.searchByBucketOrOwner')} value={query} onChange={(event) => setQuery(event.target.value)} />
          <ToolbarCreateButton label={t('buckets.createBucket')} onClick={() => setShowCreate(true)} aria-haspopup="dialog" aria-expanded={showCreate} />
          <ToolbarRefreshButton label={t('buckets.refresh')} onClick={() => void refresh()} busy={refreshing} />
        </ToolbarControls>
      </header>
      <Dialog open={showCreate} onOpenChange={(open) => { if (!creating) setShowCreate(open) }}>
        <DialogContent className="bucket-create-dialog" onInteractOutside={(event) => event.preventDefault()}>
          <DialogHeader><DialogTitle>{t('buckets.createBucket')}</DialogTitle></DialogHeader>
          <form onSubmit={create}>
            <fieldset disabled={creating} className="bucket-create-body">
              <label className="bucket-create-field" htmlFor="create-bucket-name">{t('buckets.bucketName')}
                <Input id="create-bucket-name" value={name} onChange={(event) => setName(event.target.value)} required autoFocus />
              </label>
              <label className="bucket-create-switch" htmlFor="create-versioning">{t('buckets.versioning')}<Switch id="create-versioning" checked={versioning} disabled={creating || objectLocking} onCheckedChange={setVersioning} /></label>
              <label className="bucket-create-switch" htmlFor="create-lock">{t('buckets.objectLocking')}<Switch id="create-lock" checked={objectLocking} onCheckedChange={(enabled) => { if (enabled) setVersioning(true); setObjectLocking(enabled); if (!enabled) setRetention(false) }} /></label>
              <label className="bucket-create-switch" htmlFor="create-quota">{t('buckets.bucketQuota')}<Switch id="create-quota" checked={quotaEnabled} onCheckedChange={setQuotaEnabled} /></label>
              {quotaEnabled && <fieldset className="bucket-create-section">
                <legend>{t('buckets.bucketQuota')}</legend>
                <label htmlFor="create-quota-size">{t('buckets.quotaSize')}</label>
                <div className="bucket-create-choice-row">
                  <Input id="create-quota-size" type="number" min="0" step="any" required value={maxBytes} onChange={(event) => setMaxBytes(event.target.value)} />
                  <RadioGroup className="bucket-create-options" aria-label={t('buckets.quotaUnit')} value={quotaUnit} onValueChange={setQuotaUnit}>
                    {['MiB', 'GiB', 'TiB', 'PiB'].map(unit => <label key={unit}><RadioGroupItem value={unit} />{unit}</label>)}
                  </RadioGroup>
                </div>
                <label htmlFor="create-max-objects">{t('buckets.maximumObjects')}</label>
                <Input id="create-max-objects" type="number" min="1" step="1" placeholder={t('buckets.unlimited')} value={maxObjects} onChange={(event) => setMaxObjects(event.target.value)} />
              </fieldset>}
              {objectLocking && <fieldset className="bucket-create-section">
                <legend>{t('buckets.objectLocking')}</legend>
                <label className="bucket-create-switch" htmlFor="create-retention">{t('buckets.retention')}<Switch id="create-retention" checked={retention} onCheckedChange={setRetention} /></label>
                {retention && <>
                  <span>{t('buckets.mode')}</span>
                  <RadioGroup className="bucket-create-options" aria-label={t('buckets.retentionMode')} value={retentionMode} onValueChange={(value) => setRetentionMode(value as 'COMPLIANCE' | 'GOVERNANCE')}>
                    {['COMPLIANCE', 'GOVERNANCE'].map(mode => <label key={mode}><RadioGroupItem value={mode} />{mode}</label>)}
                  </RadioGroup>
                  <label htmlFor="create-validity">{t('buckets.retentionValidity')}</label>
                  <div className="bucket-create-choice-row">
                    <Input id="create-validity" type="number" min="1" step="1" required value={validity} onChange={(event) => setValidity(event.target.value)} />
                    <RadioGroup className="bucket-create-options" aria-label={t('buckets.retentionValidityUnit')} value={validityUnit} onValueChange={setValidityUnit}>
                      <label><RadioGroupItem value="day" />{t('buckets.validityDay')}</label>
                      <label><RadioGroupItem value="year" />{t('buckets.validityYear')}</label>
                    </RadioGroup>
                  </div>
                </>}
              </fieldset>}
            </fieldset>
            <div className="ui-dialog-footer"><Button size="sm" variant="outline" type="button" disabled={creating} onClick={() => setShowCreate(false)}>{t('buckets.cancel')}</Button><Button size="sm" type="submit" disabled={creating || !name.trim()}>{t('buckets.create')}</Button></div>
          </form>
        </DialogContent>
      </Dialog>
      <div className="data-table-frame">
        <Table>
          <TableHeader><TableRow>
            {sortHeader('name', t('buckets.bucket'))}
            {sortHeader('created_at', t('buckets.creationDate'))}
            {sortHeader('objects', t('buckets.objectCount'))}
            {sortHeader('bytes', t('buckets.size'))}
            {sortHeader('accessPolicy', t('buckets.accessPolicy'))}
            <TableHead className="bucket-actions-cell">{t('buckets.actions')}</TableHead>
          </TableRow></TableHeader>
          <TableBody>
            {filteredBuckets.map((bucket) => (
              <TableRow key={bucket.name}>
                <TableCell><div className="bucket-cell"><Folder className="bucket-symbol" aria-hidden="true" /><Button variant="link" className="bucket-name-link" type="button" onClick={() => onOpenObjects(bucket.name)}>{bucket.name}</Button></div></TableCell>
                <TableCell>{formatDateTime(bucket.created_at)}</TableCell>
                <TableCell>{bucket.usage?.objects.toLocaleString(getFormatLocale()) ?? '—'}</TableCell>
                <TableCell>{bucket.usage ? formatBucketSize(bucket.usage.bytes) : '—'}</TableCell>
                <TableCell>{bucket.accessPolicy ? t(({ Private: 'buckets.private', Readonly: 'buckets.readonly', Public: 'buckets.public', Custom: 'buckets.customPolicy' } as const)[bucket.accessPolicy]) : '—'}</TableCell>
                <TableCell className="bucket-actions-cell"><div className="flex items-center justify-center gap-2">
                  <Button variant="outline" size="sm" type="button" onClick={() => onOpenBucket(bucket.name)}><Settings data-icon="inline-start" />{t('buckets.settings')}</Button>
                  <Button variant="destructive" size="sm" type="button" onClick={() => void remove(bucket.name)}><Trash2 data-icon="inline-start" />{t('buckets.delete')}</Button>
                </div></TableCell>
              </TableRow>
            ))}
            {filteredBuckets.length === 0 && <TableRow><TableCell colSpan={6} className="data-table-empty-cell"><Empty><EmptyHeader>
              <EmptyTitle>{buckets.length === 0 ? t('buckets.noBucketsYet') : t('buckets.noMatchingBuckets')}</EmptyTitle>
              <EmptyDescription>{buckets.length === 0 ? t('buckets.createYourFirstBucketToSeeItHere') : t('buckets.adjustYourSearchAndTryAgain')}</EmptyDescription>
            </EmptyHeader></Empty></TableCell></TableRow>}
          </TableBody>
        </Table>
      </div>
    </section>
  )
}

function formatBucketSize(bytes: number) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
  const index = bytes > 0 ? Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1) : 0
  return `${(bytes / 1024 ** index).toLocaleString(getFormatLocale(), { maximumFractionDigits: index === 0 ? 0 : 1 })} ${units[index]}`
}
