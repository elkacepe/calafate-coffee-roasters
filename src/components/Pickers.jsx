import { Children, createContext, isValidElement, useCallback, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

const cx = (...c) => c.filter(Boolean).join(' ')

/** Etiqueta del Field que envuelve al selector: se usa como título de la hoja en móvil. */
export const FieldLabelContext = createContext(null)

function useIsMobile() {
  const q = '(max-width: 639px)'
  const [m, setM] = useState(() => typeof window !== 'undefined' && window.matchMedia(q).matches)
  useEffect(() => {
    const mq = window.matchMedia(q)
    const on = () => setM(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])
  return m
}

/** Posición fija bajo el disparador (o arriba si no entra). Se recalcula al hacer scroll o resize. */
function usePopoverPosition(open, anchorRef, popRef, minWidth = 0) {
  const [style, setStyle] = useState({ visibility: 'hidden' })
  const place = useCallback(() => {
    const a = anchorRef.current
    const p = popRef.current
    if (!a || !p) return
    const r = a.getBoundingClientRect()
    const h = p.offsetHeight
    const w = Math.max(r.width, minWidth)
    const below = window.innerHeight - r.bottom
    const top = below < h + 12 && r.top > below ? r.top - h - 6 : r.bottom + 6
    const left = Math.min(Math.max(8, r.left), window.innerWidth - w - 8)
    setStyle({ position: 'fixed', top, left, width: w, visibility: 'visible' })
  }, [anchorRef, popRef, minWidth])
  useLayoutEffect(() => {
    if (!open) return
    place()
    window.addEventListener('resize', place)
    window.addEventListener('scroll', place, true)
    return () => { window.removeEventListener('resize', place); window.removeEventListener('scroll', place, true) }
  }, [open, place])
  return style
}

function useOutside(open, refs, onClose) {
  useEffect(() => {
    if (!open) return
    const h = (e) => { if (!refs.some((r) => r.current?.contains(e.target))) onClose() }
    document.addEventListener('pointerdown', h)
    return () => document.removeEventListener('pointerdown', h)
  }, [open, refs, onClose])
}

const Chevron = ({ open, className }) => (
  <svg viewBox="0 0 20 20" className={cx('h-4 w-4 shrink-0 transition-transform', open && 'rotate-180', className)} aria-hidden>
    <path d="M5 7.5l5 5 5-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)
const Check = () => (
  <svg viewBox="0 0 20 20" className="h-4 w-4 shrink-0" aria-hidden><path d="M4.5 10.5l3.5 3.5 7.5-8" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>
)

/** Hoja inferior para móvil (una mano): opciones grandes y fondo oscurecido. */
function MobileSheet({ title, onClose, children, panelRef }) {
  useEffect(() => {
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = '' }
  }, [])
  return createPortal(
    <div className="fixed inset-0 z-[70] flex items-end">
      <div className="absolute inset-0 bg-noche/50" onClick={onClose} />
      <div ref={panelRef} className="relative max-h-[75vh] w-full overflow-y-auto rounded-t-3xl bg-crema pb-[max(1rem,env(safe-area-inset-bottom))] shadow-card">
        <div className="sticky top-0 z-10 flex items-center justify-between bg-crema px-5 pb-2 pt-4">
          <span className="text-[11px] font-semibold uppercase tracking-[.14em] text-canela">{title}</span>
          <button type="button" onClick={onClose} className="-m-2 rounded-full p-2 text-cafe/60" aria-label="Cerrar">✕</button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  )
}

/* ============================== SELECT ============================== */

function flattenOptions(children) {
  const out = []
  Children.toArray(children).forEach((c) => {
    if (!isValidElement(c)) return
    if (c.type === 'option') {
      const label = Children.toArray(c.props.children).join('')
      out.push({ value: c.props.value ?? label, label, disabled: !!c.props.disabled })
    } else if (c.props?.children) out.push(...flattenOptions(c.props.children))
  })
  return out
}

/**
 * Reemplazo con estilo de marca para <select>. Misma API: value, onChange(e) con e.target.value,
 * hijos <option>, disabled. tone="dark" para fondos oscuros (barra).
 */
export function Select({ value, onChange, children, disabled, className, tone = 'light', label: labelProp, name, ...rest }) {
  const label = labelProp || useContext(FieldLabelContext)
  const options = useMemo(() => flattenOptions(children), [children])
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const btnRef = useRef(null)
  const popRef = useRef(null)
  const listId = useId()
  const isMobile = useIsMobile()
  const selected = options.find((o) => String(o.value) === String(value ?? ''))
  const style = usePopoverPosition(open && !isMobile, btnRef, popRef)
  const close = useCallback(() => setOpen(false), [])
  useOutside(open && !isMobile, [btnRef, popRef], close)

  const choose = (o) => {
    if (o.disabled) return
    onChange?.({ target: { value: o.value, name }, currentTarget: { value: o.value, name } })
    setOpen(false)
    btnRef.current?.focus()
  }
  const openList = () => {
    if (disabled) return
    setActive(Math.max(0, options.findIndex((o) => o === selected)))
    setOpen(true)
  }
  const move = (dir) => {
    let i = active
    for (let n = 0; n < options.length; n++) {
      i = (i + dir + options.length) % options.length
      if (!options[i].disabled) break
    }
    setActive(i)
  }
  const onKey = (e) => {
    if (disabled) return
    if (!open && ['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(e.key)) { e.preventDefault(); openList(); return }
    if (!open) return
    if (e.key === 'Escape') { e.preventDefault(); setOpen(false) }
    else if (e.key === 'ArrowDown') { e.preventDefault(); move(1) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1) }
    else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (options[active]) choose(options[active]) }
    else if (e.key === 'Tab') setOpen(false)
    else if (e.key.length === 1) {
      const i = options.findIndex((o) => !o.disabled && o.label.toLowerCase().startsWith(e.key.toLowerCase()))
      if (i >= 0) setActive(i)
    }
  }
  useEffect(() => {
    if (open && active >= 0) popRef.current?.querySelector(`[data-i="${active}"]`)?.scrollIntoView({ block: 'nearest' })
  }, [open, active])

  const dark = tone === 'dark'
  const list = (
    <ul role="listbox" id={listId} className={cx('py-1', isMobile ? 'px-3' : '')}>
      {options.map((o, i) => {
        const isSel = o === selected
        return (
          <li key={`${o.value}-${i}`} data-i={i} role="option" aria-selected={isSel} aria-disabled={o.disabled}
            onPointerEnter={() => setActive(i)} onClick={() => choose(o)}
            className={cx('flex cursor-pointer items-center justify-between gap-3 rounded-xl px-3 first-letter:uppercase',
              isMobile ? 'min-h-[52px] text-base' : 'min-h-[42px] text-sm',
              o.disabled && 'cursor-not-allowed opacity-40',
              isSel ? 'bg-cafe font-medium text-crema' : i === active ? 'bg-ambar/25 text-cafe' : 'text-cafe')}>
            <span className="truncate">{o.label || '—'}</span>
            {isSel && <Check />}
          </li>
        )
      })}
    </ul>
  )

  return (
    <>
      <button ref={btnRef} type="button" disabled={disabled} onClick={() => (open ? setOpen(false) : openList())} onKeyDown={onKey}
        aria-haspopup="listbox" aria-expanded={open} aria-controls={listId} aria-label={label} {...rest}
        className={cx('flex w-full items-center justify-between gap-2 text-left transition focus:outline-none focus:ring-2 focus:ring-ambar/50 disabled:cursor-not-allowed disabled:opacity-50',
          dark ? 'h-14 rounded-2xl bg-crema/10 px-4 text-crema' : 'min-h-[50px] rounded-2xl border bg-white px-4 py-3 text-base text-noche',
          !dark && (open ? 'border-canela' : 'border-cafe/15'), className)}>
        <span className={cx('truncate first-letter:uppercase', !selected?.label && 'text-cafe/40')}>{selected?.label || 'Elegí una opción'}</span>
        <Chevron open={open} className={dark ? 'text-ambar' : 'text-canela'} />
      </button>
      {open && !isMobile && createPortal(
        <div ref={popRef} style={style}
          className="z-[70] max-h-72 overflow-y-auto rounded-2xl bg-crema p-1 shadow-card ring-1 ring-cafe/10">
          {list}
        </div>, document.body)}
      {open && isMobile && (
        <MobileSheet title={label || 'Elegí una opción'} onClose={close} panelRef={popRef}>{list}</MobileSheet>
      )}
    </>
  )
}

/* ============================== FECHA ============================== */

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
const DIAS = ['lu', 'ma', 'mi', 'ju', 'vi', 'sá', 'do']
const DIAS_LARGO = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

// Fechas como 'YYYY-MM-DD' en UTC: sin corrimientos por zona horaria.
const parse = (s) => { const [y, m, d] = s.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)) }
const fmt = (d) => d.toISOString().slice(0, 10)
const todayStr = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires' }).format(new Date())
export function prettyDate(s) {
  if (!s) return ''
  const d = parse(s)
  return `${DIAS_LARGO[d.getUTCDay()]} ${d.getUTCDate()} de ${MESES[d.getUTCMonth()]}`
}

/**
 * Selector de fecha con calendario de marca. Misma API que <input type="date">:
 * value 'YYYY-MM-DD', onChange(e) con e.target.value, min, max. disableSundays para días sin reparto.
 */
export function DateInput({ value, onChange, min, max, disableSundays, disabled, className, label: labelProp, compact, name }) {
  const label = labelProp || useContext(FieldLabelContext)
  const [open, setOpen] = useState(false)
  const today = todayStr()
  const base = value || (min && min > today ? min : today)
  const [view, setView] = useState(() => base.slice(0, 7))
  const btnRef = useRef(null)
  const popRef = useRef(null)
  const isMobile = useIsMobile()
  const style = usePopoverPosition(open && !isMobile, btnRef, popRef, 300)
  const close = useCallback(() => setOpen(false), [])
  useOutside(open && !isMobile, [btnRef, popRef], close)
  useEffect(() => { if (open) setView((value || base).slice(0, 7)) }, [open]) // eslint-disable-line

  const isOff = (s) => (min && s < min) || (max && s > max) || (disableSundays && parse(s).getUTCDay() === 0)
  const pick = (s) => {
    if (isOff(s)) return
    onChange?.({ target: { value: s, name }, currentTarget: { value: s, name } })
    setOpen(false)
    btnRef.current?.focus()
  }

  const first = parse(view + '-01')
  const offset = (first.getUTCDay() + 6) % 7 // lunes primero
  const daysInMonth = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate()
  const cells = Array.from({ length: offset + daysInMonth }, (_, i) => (i < offset ? null : fmt(new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), i - offset + 1)))))
  const shift = (n) => { const d = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + n, 1)); setView(fmt(d).slice(0, 7)) }
  const prevDisabled = min && fmt(new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), 0))) < min
  const nextDisabled = max && fmt(new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 1))) > max

  const onKey = (e) => {
    if (!open) { if (['ArrowDown', 'Enter', ' '].includes(e.key)) { e.preventDefault(); setOpen(true) } return }
    if (e.key === 'Escape') { e.preventDefault(); setOpen(false); return }
    const cur = value || base
    const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[e.key]
    if (step) {
      e.preventDefault()
      const d = parse(cur); d.setUTCDate(d.getUTCDate() + step)
      const s = fmt(d)
      if (!isOff(s)) { onChange?.({ target: { value: s, name } }); setView(s.slice(0, 7)) }
    } else if (e.key === 'Enter') { e.preventDefault(); setOpen(false) }
  }

  const calendar = (
    <div className={cx('select-none', isMobile ? 'px-4 pb-2' : 'p-3')}>
      <div className="mb-2 flex items-center justify-between">
        <button type="button" onClick={() => shift(-1)} disabled={prevDisabled} aria-label="Mes anterior"
          className="grid h-10 w-10 place-items-center rounded-full text-cafe hover:bg-cafe/5 disabled:opacity-30"><Chevron className="rotate-90" /></button>
        <div className="font-display text-lg font-extrabold capitalize text-cafe">{MESES[first.getUTCMonth()]} {first.getUTCFullYear()}</div>
        <button type="button" onClick={() => shift(1)} disabled={nextDisabled} aria-label="Mes siguiente"
          className="grid h-10 w-10 place-items-center rounded-full text-cafe hover:bg-cafe/5 disabled:opacity-30"><Chevron className="-rotate-90" /></button>
      </div>
      <div className="grid grid-cols-7 gap-1 text-center">
        {DIAS.map((d, i) => <div key={d} className={cx('pb-1 text-[11px] font-semibold uppercase tracking-wider', i === 6 && disableSundays ? 'text-cafe/30' : 'text-canela')}>{d}</div>)}
        {cells.map((s, i) => {
          if (!s) return <div key={`x${i}`} />
          const off = isOff(s)
          const sel = s === value
          const isToday = s === today
          const sunday = disableSundays && i % 7 === 6
          return (
            <button key={s} type="button" disabled={off} onClick={() => pick(s)} aria-pressed={sel} aria-label={prettyDate(s)}
              className={cx('num mx-auto grid place-items-center rounded-full text-sm transition',
                isMobile ? 'h-11 w-11' : 'h-9 w-9',
                sel ? 'bg-cafe font-semibold text-crema' : off ? cx('text-cafe/25', sunday && 'line-through decoration-cafe/20') : 'text-cafe hover:bg-ambar/30',
                isToday && !sel && 'ring-2 ring-inset ring-ambar')}>
              {parse(s).getUTCDate()}
            </button>
          )
        })}
      </div>
      <div className="mt-3 flex items-center justify-between border-t border-cafe/10 pt-2 text-sm">
        <button type="button" disabled={isOff(today)} onClick={() => pick(today)} className="rounded-full px-3 py-2 font-medium text-canela hover:bg-cafe/5 disabled:opacity-30">Hoy</button>
        {disableSundays && <span className="text-xs text-cafe/50">Domingos cerrado</span>}
      </div>
    </div>
  )

  return (
    <>
      <button ref={btnRef} type="button" disabled={disabled} onClick={() => setOpen((o) => !o)} onKeyDown={onKey}
        aria-haspopup="dialog" aria-expanded={open} aria-label={label}
        className={cx('flex w-full items-center gap-3 rounded-2xl border bg-white text-left text-noche transition focus:outline-none focus:ring-2 focus:ring-ambar/50 disabled:opacity-50',
          compact ? 'h-10 px-3 text-sm' : 'min-h-[50px] px-4 py-3 text-base', open ? 'border-canela' : 'border-cafe/15', className)}>
        <svg viewBox="0 0 20 20" className="h-4 w-4 shrink-0 text-canela" aria-hidden>
          <rect x="3" y="4.5" width="14" height="12" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.8" />
          <path d="M3 8.5h14M7 3v3M13 3v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
        </svg>
        <span className={cx('truncate first-letter:uppercase', !value && 'text-cafe/40')}>{value ? prettyDate(value) : 'Elegí una fecha'}</span>
      </button>
      {open && !isMobile && createPortal(
        <div ref={popRef} style={style} role="dialog" aria-label={label || 'Calendario'}
          className="z-[70] rounded-3xl bg-crema shadow-card ring-1 ring-cafe/10">{calendar}</div>, document.body)}
      {open && isMobile && <MobileSheet title={label || 'Elegí una fecha'} onClose={close} panelRef={popRef}>{calendar}</MobileSheet>}
    </>
  )
}
