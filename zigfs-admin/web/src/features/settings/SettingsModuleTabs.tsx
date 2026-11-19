import { useState, type ReactNode } from 'react'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/Tabs'

interface SettingsModule {
  value: string
  label: string
  content: ReactNode
}

/** Lazily mount modules, then keep their drafts when switching between tabs. */
export function SettingsModuleTabs({ label, modules }: {
  label: string
  modules: SettingsModule[]
}) {
  const [selected, setSelected] = useState(modules[0]?.value ?? '')
  const [visited, setVisited] = useState(() => new Set([selected]))
  const active = modules.some(module => module.value === selected)
    ? selected
    : modules[0]?.value ?? ''

  function selectModule(value: string) {
    setSelected(value)
    setVisited(current => new Set([...current, value]))
  }

  return (
    <Tabs value={active} onValueChange={selectModule} className="settings-module-tabs">
      <TabsList aria-label={label}>
        {modules.map(module => (
          <TabsTrigger key={module.value} value={module.value}>
            {module.label}
          </TabsTrigger>
        ))}
      </TabsList>
      {modules.map(module => (
        <TabsContent
          key={module.value}
          value={module.value}
          forceMount
          hidden={active !== module.value}
        >
          {(visited.has(module.value) || active === module.value) && module.content}
        </TabsContent>
      ))}
    </Tabs>
  )
}
