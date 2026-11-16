import type { CSSProperties } from 'react'
import { Meter } from '@base-ui/react/meter'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'

type LevelMeterProps = {
  value: number | null
  max: number
  peak: number
  rising: boolean
  frozen?: boolean
  label: string
  valueText: string
  description: string
}

/** A horizontal sample-driven level meter. No autonomous or simulated activity. */
export function LevelMeter({ value, max, peak, rising, frozen, label, valueText, description }: LevelMeterProps) {
  const style = { '--level-peak': `${Math.min(100, peak / max * 100)}%` } as CSSProperties
  return <Tooltip>
    <TooltipTrigger asChild>
      <Meter.Root className="ui-level-meter" value={value ?? 0} min={0} max={max}
        aria-label={label} aria-valuetext={valueText} tabIndex={0} style={style}
        data-slot="level-meter" data-rising={rising} data-frozen={frozen || undefined} data-unavailable={value == null || undefined}>
        <Meter.Track className="ui-level-meter-track">
          {value != null && <span className="ui-level-meter-trail" />}
          <Meter.Indicator className="ui-level-meter-fill" />
        </Meter.Track>
        {value != null && peak > 0 && <span className="ui-level-meter-peak" aria-hidden="true" />}
      </Meter.Root>
    </TooltipTrigger>
    <TooltipContent>{description}</TooltipContent>
  </Tooltip>
}
