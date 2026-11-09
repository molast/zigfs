import { t, getFormatLocale } from '@/locales'
import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, Folder, FolderPlus, Trash2, X } from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
import { ToolbarControls, ToolbarCreateButton, ToolbarRefreshButton, ToolbarSearch } from '../../components/ui/ToolbarControls'
import { Button } from '../../components/ui/Button'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '../../components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table'
import type { Bucket } from '../../types/api'

interface BucketsViewProps {
  api: ApiClient
  onOpenBucket: (name: string) => void
}

export function BucketsView({ api, onOpenBucket }: BucketsViewProps) {
  const confirm = useConfirm()
  const { startLoading } = useLoading()
  const showToast = useToast()
  const [buckets, setBuckets] = useState<Bucket[]>([])
  const [name, setName] = useState('')
  const [versioning, setVersioning] = useState(false)
  const [objectLocking, setObjectLocking] = useState(false)
  const [quotaEnabled, setQuotaEnabled] = useState(false)
  const [maxBytes, setMaxBytes] = useState('')
  const [maxObjects, setMaxObjects] = useState('')
  const [query, setQuery] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const notifyError = useErrorToast()

  const refresh = useCallback(async () => {
    const stopLoading = startLoading(t('buckets.loadingBuckets'))
    try {
      setRefreshing(true)
      setBuckets(await api.listBuckets())
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

  useEffect(() => {
    if (!showCreate) return
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') setShowCreate(false)
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [showCreate])

  const filteredBuckets = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return buckets
    return buckets.filter((bucket) => bucket.name.toLowerCase().includes(needle) || bucket.owner.toLowerCase().includes(needle))
  }, [buckets, query])

  async function create(event: FormEvent) {
    event.preventDefault()
    const stopLoading = startLoading(t('buckets.creatingBucket'))
    try {
      const createdName = name.trim()
      await api.createBucket({ name: createdName, versioning: versioning || objectLocking, object_locking: objectLocking, ...(quotaEnabled && maxBytes ? { max_bytes: Number(maxBytes) } : {}), ...(quotaEnabled && maxObjects ? { max_objects: Number(maxObjects) } : {}) })
      setName('')
      setVersioning(false)
      setObjectLocking(false)
      setQuotaEnabled(false)
      setMaxBytes(''); setMaxObjects('')
      setShowCreate(false)
      await refresh()
      showToast(t('buckets.createdBucketValue', { '0': createdName }))
    } catch (reason) {
      notifyError((reason as Error).message)
    } finally {
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
        <h2>{t('navigation.objectBrowser')}</h2>
        <ToolbarControls className="buckets-header-actions">
          <ToolbarSearch label={t('buckets.searchBuckets')} placeholder={t('buckets.searchByBucketOrOwner')} value={query} onChange={(event) => setQuery(event.target.value)} />
          <ToolbarCreateButton label={t('buckets.createBucket')} onClick={() => setShowCreate(true)} aria-haspopup="dialog" aria-expanded={showCreate} />
          <ToolbarRefreshButton label={t('buckets.refresh')} onClick={() => void refresh()} busy={refreshing} />
        </ToolbarControls>
      </header>
      {showCreate && (
        <div className="modal-backdrop" role="presentation">
          <section className="lifecycle-modal credential-modal bucket-create-modal" role="dialog" aria-modal="true" aria-labelledby="bucket-create-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><FolderPlus aria-hidden="true" /><h3 id="bucket-create-dialog-title">{t('buckets.createBucket')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('buckets.close')} onClick={() => setShowCreate(false)}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={create}>
              <p className="credential-modal-description">{t('buckets.theNameCannotBeChangedAfterCreationTheBucket')}</p>
              <div className="credential-modal-fields bucket-create-fields">
                <label>{t('buckets.bucketName')}<input aria-label={t('buckets.bucketName')} placeholder="bucket-name" value={name} onChange={(event) => setName(event.target.value)} required autoFocus /></label>
                <label className="bucket-create-toggle">{t('buckets.versioning')}<button type="button" role="switch" aria-checked={versioning} className={versioning ? 'active' : ''} onClick={() => setVersioning(value => !value)}><span /></button></label>
                <label className="bucket-create-toggle">{t('buckets.objectLocking')}<button type="button" role="switch" aria-checked={objectLocking} className={objectLocking ? 'active' : ''} onClick={() => setObjectLocking(value => !value)}><span /></button></label>
                <label className="bucket-create-toggle">{t('buckets.bucketQuota')}<button type="button" role="switch" aria-checked={quotaEnabled} className={quotaEnabled ? 'active' : ''} onClick={() => setQuotaEnabled(value => !value)}><span /></button></label>
                {quotaEnabled && <div className="bucket-create-quota-fields"><input type="number" min="1" placeholder={t('buckets.byteQuota')} value={maxBytes} onChange={event => setMaxBytes(event.target.value)} /><input type="number" min="1" placeholder={t('buckets.objectCountQuota')} value={maxObjects} onChange={event => setMaxObjects(event.target.value)} /></div>}
              </div>
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setShowCreate(false)}>{t('buckets.cancel')}</button>
                <button className="primary-button" type="submit">{t('buckets.create')}</button>
              </footer>
            </form>
          </section>
        </div>
      )}
      <div className="data-table-frame">
        <Table>
          <TableHeader><TableRow>
            <TableHead>{t('buckets.bucket')}</TableHead>
            <TableHead>{t('buckets.owner')}</TableHead>
            <TableHead>{t('buckets.creationDate')}</TableHead>
            <TableHead className="bucket-actions-cell">{t('buckets.actions')}</TableHead>
          </TableRow></TableHeader>
          <TableBody>
            {filteredBuckets.map((bucket) => (
              <TableRow key={bucket.name}>
                <TableCell><div className="bucket-cell"><Folder className="bucket-symbol" aria-hidden="true" /><button className="link-button bucket-link" type="button" onClick={() => onOpenBucket(bucket.name)}>{bucket.name}</button></div></TableCell>
                <TableCell>{bucket.owner}</TableCell>
                <TableCell>{new Date(bucket.created_at).toLocaleString(getFormatLocale())}</TableCell>
                <TableCell className="bucket-actions-cell"><div className="flex items-center justify-center gap-2">
                  <Button variant="outline" size="sm" type="button" onClick={() => onOpenBucket(bucket.name)}><ArrowRight data-icon="inline-start" />{t('buckets.open')}</Button>
                  <Button variant="destructive" size="sm" type="button" onClick={() => void remove(bucket.name)}><Trash2 data-icon="inline-start" />{t('buckets.delete')}</Button>
                </div></TableCell>
              </TableRow>
            ))}
            {filteredBuckets.length === 0 && <TableRow><TableCell colSpan={4} className="data-table-empty-cell"><Empty><EmptyHeader>
              <EmptyTitle>{buckets.length === 0 ? t('buckets.noBucketsYet') : t('buckets.noMatchingBuckets')}</EmptyTitle>
              <EmptyDescription>{buckets.length === 0 ? t('buckets.createYourFirstBucketToSeeItHere') : t('buckets.adjustYourSearchAndTryAgain')}</EmptyDescription>
            </EmptyHeader></Empty></TableCell></TableRow>}
          </TableBody>
        </Table>
      </div>
    </section>
  )
}
