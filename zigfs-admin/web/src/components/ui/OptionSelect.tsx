import type { ComponentProps, ReactNode } from 'react'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from './select'

interface OptionSelectProps extends Pick<ComponentProps<typeof SelectTrigger>, 'id' | 'className' | 'aria-label' | 'aria-labelledby' | 'aria-describedby' | 'aria-invalid'> {
  value: string
  onValueChange: (value: string) => void
  options: { value: string; label: ReactNode; disabled?: boolean }[]
  placeholder?: string
  disabled?: boolean
  required?: boolean
  name?: string
}

export function OptionSelect({ value, onValueChange, options, placeholder, disabled, required, name, ...triggerProps }: OptionSelectProps) {
  return (
    <Select value={value} onValueChange={onValueChange} disabled={disabled} required={required} name={name}>
      <SelectTrigger {...triggerProps}><SelectValue placeholder={placeholder} /></SelectTrigger>
      <SelectContent position="popper" align="start">
        <SelectGroup>
          {options.map(option => <SelectItem key={option.value} value={option.value} disabled={option.disabled}>{option.label}</SelectItem>)}
        </SelectGroup>
      </SelectContent>
    </Select>
  )
}
