import { t } from '@/locales'
import { cn } from "@/lib/utils"
import { Loader2Icon } from "lucide-react"

function Spinner({ className, ...props }: React.ComponentProps<"svg">) {
  return (
    <Loader2Icon
      role="status"
      aria-label={t('ui.loading')}
      className={cn("size-4 animate-spin", className)}
      {...props}
    />
  )
}

export { Spinner }
