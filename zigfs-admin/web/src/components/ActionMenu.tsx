import { Ellipsis } from 'lucide-react'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

export function ActionMenu({ label, children }: { label: string; children: ReactNode }) {
  const [open, setOpen] = useState(false)
  const [position, setPosition] = useState({ top: 0, right: 0, above: false })
  const buttonRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  function toggle() {
    const button = buttonRef.current
    if (!button || open) {
      setOpen(false)
      return
    }
    const rect = button.getBoundingClientRect()
    const above = rect.bottom + 190 > window.innerHeight
    setPosition({
      top: above ? rect.top - 6 : rect.bottom + 6,
      right: Math.max(8, window.innerWidth - rect.right),
      above,
    })
    setOpen(true)
  }

  useEffect(() => {
    if (!open) return
    function closeOnOutsideClick(event: MouseEvent) {
      const target = event.target as Node
      if (!buttonRef.current?.contains(target) && !menuRef.current?.contains(target)) setOpen(false)
    }
    const close = () => setOpen(false)
    document.addEventListener('mousedown', closeOnOutsideClick)
    window.addEventListener('resize', close)
    window.addEventListener('scroll', close, true)
    return () => {
      document.removeEventListener('mousedown', closeOnOutsideClick)
      window.removeEventListener('resize', close)
      window.removeEventListener('scroll', close, true)
    }
  }, [open])

  const portalTarget = document.querySelector('.app-shell') ?? document.body

  return (
    <>
      <button ref={buttonRef} className="icon-button action-menu-trigger" type="button" aria-label={label} title={label} aria-expanded={open} onClick={toggle}>
        <Ellipsis aria-hidden="true" />
      </button>
      {open && createPortal(
        <div
          ref={menuRef}
          className="action-menu-popover"
          role="menu"
          style={{ top: position.top, right: position.right, transform: position.above ? 'translateY(-100%)' : undefined }}
          onClick={(event) => {
            if ((event.target as HTMLElement).closest('button:not(:disabled), a')) setOpen(false)
          }}
        >
          {children}
        </div>,
        portalTarget,
      )}
    </>
  )
}
