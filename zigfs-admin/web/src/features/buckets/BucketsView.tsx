import { t, getFormatLocale } from '@/locales'
import { type FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, Folder, FolderPlus, Plus, RefreshCw, Search, Trash2, X } from 'lucide-react'
import { ApiError, type ApiClient } from '../../api/client'
import { useConfirm } from '../../components/ConfirmProvider'
import { useLoading } from '../../components/LoadingProvider'
import { useErrorToast, useToast } from '../../components/ToastProvider'
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
      await api.createBucket(name.trim())
      setName('')
      setShowCreate(false)
      await refresh()
      showToast(t('buckets.createdBucketValue', { '0': name.trim() }))
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
      <header className="page-header">
        <div>
          <p className="eyebrow">{t('buckets.buckets')}</p>
          <h2>{t('buckets.buckets')}</h2>
          <p className="page-description">{t('buckets.organizeAndBrowseObjectStorageInZigfs')}</p>
        </div>
        <span className="count-badge">{buckets.length} {t('buckets.bucketCountUnit')}</span>
      </header>
      <div className="page-toolbar">
        <div className="toolbar-leading">
          <label className="search-box">
            <Search aria-hidden="true" />
            <input aria-label={t('buckets.searchBuckets')} placeholder={t('buckets.searchByBucketOrOwner')} value={query} onChange={(event) => setQuery(event.target.value)} />
          </label>
        </div>
        <div className="toolbar-actions">
          <button className="primary-button create-action-button" type="button" onClick={() => { setShowCreate(true) }} aria-haspopup="dialog" aria-expanded={showCreate}>
            <Plus className="button-icon" aria-hidden="true" />{t('buckets.createBucket')}</button>
          <button className="secondary-button refresh-action-button" type="button" onClick={() => void refresh()} disabled={refreshing} aria-busy={refreshing}>
            <RefreshCw className={`button-icon${refreshing ? ' spinning' : ''}`} aria-hidden="true" />{t('buckets.refresh')}</button>
        </div>
      </div>
      {showCreate && (
        <div className="modal-backdrop" role="presentation" onMouseDown={() => setShowCreate(false)}>
          <section className="lifecycle-modal credential-modal bucket-create-modal" role="dialog" aria-modal="true" aria-labelledby="bucket-create-dialog-title" onMouseDown={(event) => event.stopPropagation()}>
            <header className="lifecycle-modal-header">
              <div className="lifecycle-modal-title"><FolderPlus aria-hidden="true" /><h3 id="bucket-create-dialog-title">{t('buckets.createBucket')}</h3></div>
              <button className="icon-button" type="button" aria-label={t('buckets.close')} onClick={() => setShowCreate(false)}><X aria-hidden="true" /></button>
            </header>
            <form className="credential-modal-form" onSubmit={create}>
              <p className="credential-modal-description">{t('buckets.theNameCannotBeChangedAfterCreationTheBucket')}</p>
              <div className="credential-modal-fields">
                <label>{t('buckets.bucketName')}<input aria-label={t('buckets.bucketName')} placeholder="bucket-name" value={name} onChange={(event) => setName(event.target.value)} required autoFocus /></label>
              </div>
              <footer className="lifecycle-modal-actions">
                <button className="secondary-button" type="button" onClick={() => setShowCreate(false)}>{t('buckets.cancel')}</button>
                <button className="primary-button" type="submit">{t('buckets.create')}</button>
              </footer>
            </form>
          </section>
        </div>
      )}
      <section className="panel table-panel">
        <div className="table-wrap">
          <table>
            <thead><tr><th>{t('buckets.bucket')}</th><th>{t('buckets.owner')}</th><th>{t('buckets.creationDate')}</th><th>{t('buckets.actions')}</th></tr></thead>
            <tbody>
              {filteredBuckets.map((bucket) => (
                <tr key={bucket.name}>
                  <td>
                    <div className="bucket-cell"><Folder className="bucket-symbol" aria-hidden="true" /><button className="link-button bucket-link" onClick={() => onOpenBucket(bucket.name)}>{bucket.name}</button></div>
                  </td>
                  <td>{bucket.owner}</td>
                  <td>{new Date(bucket.created_at).toLocaleString(getFormatLocale())}</td>
                  <td className="table-actions">
                    <button className="secondary-button" onClick={() => onOpenBucket(bucket.name)}><ArrowRight className="button-icon" aria-hidden="true" />{t('buckets.open')}</button>
                    <button className="danger-button" onClick={() => void remove(bucket.name)}><Trash2 className="button-icon" aria-hidden="true" />{t('buckets.delete')}</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {filteredBuckets.length === 0 && (
          <div className="empty-state empty-panel">
            <strong>{buckets.length === 0 ? t('buckets.noBucketsYet') : t('buckets.noMatchingBuckets')}</strong>
            <span>{buckets.length === 0 ? t('buckets.createYourFirstBucketToSeeItHere') : t('buckets.adjustYourSearchAndTryAgain')}</span>
          </div>
        )}
      </section>
    </section>
  )
}
