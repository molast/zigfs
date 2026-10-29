import { useId, useState } from 'react'
import { ChevronDown } from 'lucide-react'
import { Button } from '../../components/ui/Button'
import { Input } from '../../components/ui/Input'
import { Checkbox } from '../../components/ui/checkbox'
import { Field, FieldLabel } from '../../components/ui/field'
import { Popover, PopoverContent, PopoverTrigger } from '../../components/ui/popover'

export function MultiChoice({ title, placeholder, options, selected, onChange, disabled }: { title: string; placeholder: string; options: string[]; selected: string[]; onChange: (names: string[]) => void; disabled?: boolean }) {
  const id = useId()
  const [query, setQuery] = useState('')
  const filtered = [...new Set([...options, ...selected])].filter(name => name.toLowerCase().includes(query.toLowerCase())).sort()
  return <Field><FieldLabel htmlFor={id}>{title}</FieldLabel><Popover><PopoverTrigger asChild><Button id={id} type="button" variant="outline" disabled={disabled} className="identity-multi-trigger"><span>{selected.length ? selected.join(', ') : placeholder}</span><ChevronDown /></Button></PopoverTrigger>
    <PopoverContent align="start" className="identity-multi-content"><Input aria-label={`Search ${title}`} placeholder="Search..." value={query} onChange={event => setQuery(event.target.value)} /><div className="identity-choices">{filtered.length ? filtered.map((name, index) => <Field key={name} orientation="horizontal"><Checkbox id={`${id}-${index}`} disabled={disabled} checked={selected.includes(name)} onCheckedChange={checked => onChange(checked === true ? [...new Set([...selected, name])] : selected.filter(item => item !== name))} /><FieldLabel htmlFor={`${id}-${index}`}>{name}{!options.includes(name) ? ' (unavailable)' : ''}</FieldLabel></Field>) : <span className="identity-muted">No results</span>}</div></PopoverContent>
  </Popover></Field>
}
