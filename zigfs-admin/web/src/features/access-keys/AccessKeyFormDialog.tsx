import { t } from '@/locales'
import { cn } from '@/lib/utils'
import type { FormEvent, ReactNode } from 'react'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Textarea } from '../../components/ui/Textarea'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../components/ui/Dialog'
import { Field, FieldContent, FieldDescription, FieldGroup, FieldLabel } from '../../components/ui/field'
import { Switch } from '../../components/ui/switch'
import { AccessKeyExpiryField } from './AccessKeyExpiryField'

interface Props {
  id: string
  title: string
  descriptionText: string
  children: ReactNode
  statusField?: ReactNode
  statusAfterInheritance?: boolean
  expiry?: Date
  onExpiryChange: (value: Date | undefined) => void
  name: string
  nameRequired?: boolean
  onNameChange: (value: string) => void
  description: string
  onDescriptionChange: (value: string) => void
  inherit: boolean
  showInheritanceControl?: boolean
  alwaysShowPolicy?: boolean
  onInheritChange: (value: boolean) => void
  inheritDescription: string
  document: string
  onDocumentChange: (value: string) => void
  saving: boolean
  invalid: string | null
  onSubmit: (event: FormEvent) => Promise<void>
  onClose: () => void
}

export function AccessKeyFormDialog(props: Props) {
  const { id, saving, invalid, inherit } = props
  const showPolicy = props.alwaysShowPolicy || !inherit
  return <Dialog open onOpenChange={open => { if (!open && !saving) props.onClose() }}>
    <DialogContent className={cn('identity-dialog access-key-form-dialog', showPolicy && 'access-key-form-dialog-with-policy')}>
      <DialogHeader><DialogTitle>{props.title}</DialogTitle><DialogDescription className="sr-only">{props.descriptionText}</DialogDescription></DialogHeader>
      <form className="identity-form" onSubmit={event => void props.onSubmit(event)} noValidate>
        <div className={cn('identity-form-body', showPolicy && 'access-key-form-fields')}>
          <FieldGroup>
            {props.children}
            <AccessKeyExpiryField value={props.expiry} onChange={props.onExpiryChange} disabled={saving} invalid={invalid === 'expiry'} />
            <Field data-invalid={invalid === 'name' || undefined}><FieldLabel htmlFor={`${id}-name`}>{t('access_keys.name')}</FieldLabel><Input id={`${id}-name`} value={props.name} required={props.nameRequired} aria-required={props.nameRequired} maxLength={128} disabled={saving} aria-invalid={invalid === 'name'} onChange={event => props.onNameChange(event.target.value)} /></Field>
            <Field data-invalid={invalid === 'description' || undefined}><FieldLabel htmlFor={`${id}-description`}>{t('access_keys.description')}</FieldLabel><Textarea id={`${id}-description`} value={props.description} maxLength={1024} disabled={saving} aria-invalid={invalid === 'description'} onChange={event => props.onDescriptionChange(event.target.value)} /></Field>
            {!props.statusAfterInheritance && props.statusField}
            {props.showInheritanceControl !== false && <Field orientation="horizontal" className="rounded-md border border-border p-4"><FieldContent><FieldLabel htmlFor={`${id}-inherit`}>{t('access_keys.useParentAccountPermissions')}</FieldLabel><FieldDescription>{props.inheritDescription}</FieldDescription></FieldContent><Switch id={`${id}-inherit`} checked={inherit} disabled={saving} onCheckedChange={props.onInheritChange} /></Field>}
            {props.statusAfterInheritance && props.statusField}
          </FieldGroup>
          {showPolicy && <Field data-invalid={invalid === 'policy' || undefined} className="access-key-form-policy">
            <FieldLabel htmlFor={`${id}-policy`}>{t('access_keys.policy')}</FieldLabel>
            <Textarea id={`${id}-policy`} value={props.document} disabled={saving} spellCheck={false} aria-invalid={invalid === 'policy'} onChange={event => props.onDocumentChange(event.target.value)} />
          </Field>}
        </div>
        <footer className="identity-form-footer"><Button type="button" variant="outline" disabled={saving} onClick={props.onClose}>{t('access_keys.cancel')}</Button><Button type="submit" disabled={saving}>{saving ? t('access_keys.submitting') : t('access_keys.submit')}</Button></footer>
      </form>
    </DialogContent>
  </Dialog>
}
