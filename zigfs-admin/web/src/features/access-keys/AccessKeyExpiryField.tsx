import { useId, useState } from 'react'
import { CalendarDays, Clock3, X } from 'lucide-react'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Field, FieldDescription, FieldLabel } from '../../components/ui/field'
import { Calendar } from '../../components/ui/calendar'
import { Popover, PopoverContent, PopoverTrigger } from '../../components/ui/popover'
import { Separator } from '../../components/ui/separator'

export function AccessKeyExpiryField({ value, onChange, disabled, invalid }: { value?: Date; onChange: (value?: Date) => void; disabled?: boolean; invalid?: boolean }) {
  const id = useId()
  const [open, setOpen] = useState(false)
  const today = new Date(); today.setHours(0, 0, 0, 0)
  function selectDate(date?: Date) {
    if (!date) return
    const time = value ?? new Date(Date.now() + 60 * 60 * 1000)
    const next = new Date(date)
    next.setHours(time.getHours(), time.getMinutes(), 0, 0)
    onChange(next)
  }
  function changeTime(part: 'hours' | 'minutes', raw: string) {
    if (!value || raw === '') return
    const number = Number(raw)
    if (!Number.isInteger(number) || number < 0 || number > (part === 'hours' ? 23 : 59)) return
    const next = new Date(value)
    if (part === 'hours') next.setHours(number)
    else next.setMinutes(number)
    next.setSeconds(0, 0)
    onChange(next)
  }
  return <Field data-invalid={invalid || undefined}>
    <FieldLabel htmlFor={id}>Expiry</FieldLabel>
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild><Button id={id} type="button" variant="outline" disabled={disabled} aria-invalid={invalid} data-align="start"><CalendarDays data-icon="inline-start" />{value ? value.toLocaleString(undefined, { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }) : 'Select expiry date and time'}</Button></PopoverTrigger>
      <PopoverContent align="start" className="expiry-popover">
        <Calendar mode="single" required selected={value} defaultMonth={value} onSelect={selectDate} disabled={{ before: today }} />
        <Separator />
        <div className="expiry-time-row">
          <Clock3 aria-hidden="true" />
          <Field orientation="horizontal"><FieldLabel htmlFor={`${id}-hours`} className="sr-only">Hours (0–23)</FieldLabel><Input id={`${id}-hours`} type="number" min={0} max={23} step={1} disabled={!value} value={value ? String(value.getHours()).padStart(2, '0') : ''} placeholder="HH" onChange={event => changeTime('hours', event.target.value)} /></Field>
          <span aria-hidden="true">:</span>
          <Field orientation="horizontal"><FieldLabel htmlFor={`${id}-minutes`} className="sr-only">Minutes (0–59)</FieldLabel><Input id={`${id}-minutes`} type="number" min={0} max={59} step={1} disabled={!value} value={value ? String(value.getMinutes()).padStart(2, '0') : ''} placeholder="MM" onChange={event => changeTime('minutes', event.target.value)} /></Field>
          <Button type="button" variant="ghost" size="icon-sm" aria-label="Clear expiry" disabled={!value} onClick={() => { onChange(undefined); setOpen(false) }}><X /></Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>Done</Button>
        </div>
      </PopoverContent>
    </Popover>
    <FieldDescription>{value ? 'Date and time use your local timezone.' : 'Empty indicates permanent validity.'}</FieldDescription>
  </Field>
}
