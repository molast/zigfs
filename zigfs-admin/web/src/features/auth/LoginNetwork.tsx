import { useEffect, useRef } from 'react'

type Node = {
  homeX: number
  homeY: number
  x: number
  y: number
  phase: number
  accent: boolean
}

function scatter(seed: number) {
  const value = Math.sin(seed * 127.1) * 43758.5453
  return value - Math.floor(value)
}

export function LoginNetwork() {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    const container = canvas?.parentElement
    const context = canvas?.getContext('2d')
    if (!canvas || !container || !context) return

    const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)')
    const pointer = { x: 0, y: 0, targetX: 0, targetY: 0, strength: 0, inside: false }
    let nodes: Node[] = []
    let width = 0
    let height = 0
    let frame = 0

    function draw(time: number) {
      if (!context) return
      context.clearRect(0, 0, width, height)
      pointer.x += (pointer.targetX - pointer.x) * 0.07
      pointer.y += (pointer.targetY - pointer.y) * 0.07
      pointer.strength += ((pointer.inside ? 1 : 0) - pointer.strength) * 0.035

      for (const node of nodes) {
        const driftX = Math.sin(time * 0.0004 + node.phase) * 7
        const driftY = Math.cos(time * 0.00033 + node.phase * 1.3) * 8
        const dx = pointer.x - node.homeX
        const dy = pointer.y - node.homeY
        const distance = Math.hypot(dx, dy)
        const influence = Math.max(0, 1 - distance / 260) ** 2 * pointer.strength
        const targetX = node.homeX + driftX + (dx * 0.1 - dy * 0.16) * influence
        const targetY = node.homeY + driftY + (dy * 0.1 + dx * 0.16) * influence
        node.x += (targetX - node.x) * 0.055
        node.y += (targetY - node.y) * 0.055
      }

      for (let index = 0; index < nodes.length; index++) {
        const first = nodes[index]
        for (let other = index + 1; other < nodes.length; other++) {
          const second = nodes[other]
          const distance = Math.hypot(first.x - second.x, first.y - second.y)
          if (distance > 145) continue
          const proximity = Math.max(0, 1 - Math.hypot((first.x + second.x) / 2 - pointer.x, (first.y + second.y) / 2 - pointer.y) / 270)
          context.strokeStyle = `rgba(111, 207, 207, ${(1 - distance / 145) * (0.14 + proximity * pointer.strength * 0.24)})`
          context.beginPath()
          context.moveTo(first.x, first.y)
          context.lineTo(second.x, second.y)
          context.stroke()
        }
      }

      for (const node of nodes) {
        const nearPointer = Math.max(0, 1 - Math.hypot(node.x - pointer.x, node.y - pointer.y) / 240) * pointer.strength
        context.fillStyle = node.accent
          ? `rgba(246, 185, 91, ${0.45 + nearPointer * 0.35})`
          : `rgba(135, 216, 213, ${0.38 + nearPointer * 0.42})`
        context.beginPath()
        context.arc(node.x, node.y, node.accent ? 2.2 : 1.6 + nearPointer * 0.7, 0, Math.PI * 2)
        context.fill()
      }
    }

    function animate(time: number) {
      frame = 0
      draw(time)
      if (!motionPreference.matches && !document.hidden) frame = window.requestAnimationFrame(animate)
    }

    function start() {
      if (!frame && !motionPreference.matches && !document.hidden) frame = window.requestAnimationFrame(animate)
    }

    function resize() {
      if (!canvas || !container || !context) return
      const bounds = container.getBoundingClientRect()
      width = bounds.width
      height = bounds.height
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2)
      canvas.width = Math.round(width * pixelRatio)
      canvas.height = Math.round(height * pixelRatio)
      context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
      nodes = []
      const spacing = 105
      for (let row = 0; row <= Math.ceil(height / spacing); row++) {
        for (let column = 0; column <= Math.ceil(width / spacing); column++) {
          const seed = row * 101 + column + 1
          const homeX = column * spacing + (scatter(seed) - 0.5) * 42
          const homeY = row * spacing + (scatter(seed + 37) - 0.5) * 42
          nodes.push({ homeX, homeY, x: homeX, y: homeY, phase: scatter(seed + 71) * Math.PI * 2, accent: seed % 13 === 0 })
        }
      }
      draw(performance.now())
    }

    function movePointer(event: PointerEvent) {
      if (event.pointerType === 'touch' || !container) return
      const bounds = container.getBoundingClientRect()
      pointer.targetX = event.clientX - bounds.left
      pointer.targetY = event.clientY - bounds.top
      if (!pointer.inside) {
        pointer.x = pointer.targetX
        pointer.y = pointer.targetY
      }
      pointer.inside = true
    }

    function leavePointer() { pointer.inside = false }
    function updateMotion() {
      if (frame) window.cancelAnimationFrame(frame)
      frame = 0
      draw(performance.now())
      start()
    }

    const observer = new ResizeObserver(resize)
    observer.observe(container)
    container.addEventListener('pointermove', movePointer)
    container.addEventListener('pointerleave', leavePointer)
    motionPreference.addEventListener('change', updateMotion)
    document.addEventListener('visibilitychange', updateMotion)
    resize()
    start()

    return () => {
      if (frame) window.cancelAnimationFrame(frame)
      observer.disconnect()
      container.removeEventListener('pointermove', movePointer)
      container.removeEventListener('pointerleave', leavePointer)
      motionPreference.removeEventListener('change', updateMotion)
      document.removeEventListener('visibilitychange', updateMotion)
    }
  }, [])

  return <canvas ref={canvasRef} className="login-network" aria-hidden="true" />
}
