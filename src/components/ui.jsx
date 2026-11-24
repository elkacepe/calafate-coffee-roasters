import { useEffect } from 'react'

export function cx(...c) {
  return c.filter(Boolean).join(' ')
}

export function Button({ variant = 'primary', size = 'md', className, busy, children, ...props }) {
  const base = 'inline-flex items-center justify-center gap-2 rounded-2xl font-body font-medium transition active:scale-[.98] disabled:opacity-50 disabled:pointer-events-none select-none'
  const sizes = { sm: 'h-9 px-3 text-sm', md: 'h-12 px-5 text-base', lg: 'h-14 px-6 text-lg', xl: 'h-20 px-6 text-xl' }
  const variants = {
    primary: 'bg-cafe text-crema hover:bg-cafe/90',
    secondary: 'bg-canela text-crema hover:bg-canela/90',
    accent: 'bg-ambar text-noche hover:bg-ambar/90',
    glaciar: 'bg-glaciar text-noche hover:bg-glaciar/90',
    ghost: 'bg-transparent text-cafe hover:bg-cafe/5 border border-cafe/20',
    danger: 'bg-noche text-crema hover:bg-noche/90',
    whatsapp: 'bg-[#1f7a4d] text-white hover:bg-[#1a6942]',
  }
  return (
    <button className={cx(base, sizes[size], variants[variant], className)} disabled={busy || props.disabled} {...props}>
      {busy && <span className="h-4 w-4 animate-spin rounded-full border-2 border-current border-t-transparent" />}
      {children}
    </button>
  )
}

export function Card({ className, children, ...p }) {
  return <div className={cx('rounded-3xl bg-white/70 p-4 shadow-card ring-1 ring-cafe/5', className)} {...p}>{children}</div>
}

export function H1({ children, className }) {
  return <h1 className={cx('font-display text-3xl font-extrabold leading-tight text-cafe sm:text-4xl', className)}>{children}</h1>
}
export function H2({ children, className }) {
  return <h2 className={cx('font-display text-xl font-extrabold text-cafe sm:text-2xl', className)}>{children}</h2>
}
export function Label({ children, className }) {
  return <span className={cx('text-[11px] font-semibold uppercase tracking-[.14em] text-canela', className)}>{children}</span>
}

const STATUS = {
  // lotes: colores bien distintos
  'En reposo': 'bg-glaciar text-noche',
  Disponible: 'bg-cafe text-crema',
  'Solo barra': 'bg-ambar text-noche',
  Agotado: 'bg-noche/10 text-noche/60 line-through decoration-noche/40',
  // pedidos
  Borrador: 'bg-noche/10 text-noche',
  Confirmado: 'bg-cafe text-crema',
  'En preparación': 'bg-canela text-crema',
  Listo: 'bg-ambar text-noche',
  'En reparto': 'bg-glaciar text-noche',
  Entregado: 'bg-[#2f5d46] text-crema',
  'Entregado parcial': 'bg-[#2f5d46]/70 text-crema',
  'Para reprogramar': 'bg-[#b5432f] text-crema',
  Cancelado: 'bg-noche/10 text-noche/60 line-through',
  Retenido: 'bg-noche text-ambar',
  // devoluciones
  Pedida: 'bg-ambar text-noche',
  'En revisión': 'bg-glaciar text-noche',
  Aceptada: 'bg-canela text-crema',
  Rechazada: 'bg-noche/10 text-noche/70',
  Resuelta: 'bg-[#2f5d46] text-crema',
  // recorridos
  Planificado: 'bg-ambar text-noche',
  'En curso': 'bg-glaciar text-noche',
  Cerrado: 'bg-noche/10 text-noche/70',
  pendiente: 'bg-ambar text-noche',
  aprobada: 'bg-[#2f5d46] text-crema',
  rechazada: 'bg-noche/10 text-noche/70',
}
export function Badge({ status, children, className }) {
  return (
    <span className={cx('inline-flex items-center whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-semibold', STATUS[status] || 'bg-cafe/10 text-cafe', className)}>
      {children || status}
    </span>
  )
}

export function Field({ label, hint, error, children, className }) {
  return (
    <label className={cx('block', className)}>
      {label && <span className="mb-1 block text-sm font-medium text-cafe">{label}</span>}
      <FieldLabelContext.Provider value={typeof label === 'string' ? label : null}>{children}</FieldLabelContext.Provider>
      {hint && !error && <span className="mt-1 block text-xs text-cafe/70">{hint}</span>}
      {error && <span className="mt-1 block text-xs font-medium text-[#b5432f]">{error}</span>}
    </label>
  )
}
const inputCls = 'w-full rounded-2xl border border-cafe/15 bg-white px-4 py-3 text-base text-noche placeholder:text-cafe/40 focus:border-canela focus:outline-none focus:ring-2 focus:ring-ambar/50'
export function Input({ className, ...props }) {
  return <input className={cx(inputCls, className)} {...props} />
}
export function Textarea({ className, ...props }) {
  return <textarea className={cx(inputCls, 'min-h-[88px]', className)} {...props} />
}
import { FieldLabelContext } from './Pickers'
export { Select, DateInput, prettyDate } from './Pickers'

/** Botones segmentados grandes (ideal con una mano) */
export function Segmented({ options, value, onChange, className, size = 'md' }) {
  return (
    <div className={cx('grid gap-2', className)} style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0,1fr))` }}>
      {options.map((o) => (
        <button key={o.value} type="button" onClick={() => onChange(o.value)}
          className={cx('rounded-2xl border px-2 font-medium transition', size === 'lg' ? 'h-14 text-base' : 'h-11 text-sm',
            value === o.value ? 'border-cafe bg-cafe text-crema' : 'border-cafe/20 bg-white text-cafe')}>
          {o.label}
        </button>
      ))}
    </div>
  )
}

/** Número grande con unidad; null/undefined → «Sin datos» (nunca 0 inventado). */
export function Stat({ label, value, unit, hint, tone = 'cafe', className }) {
  const empty = value == null || value === ''
  return (
    <div className={cx('rounded-3xl bg-white/70 p-4 ring-1 ring-cafe/5', className)}>
      <Label>{label}</Label>
      <div className={cx('mt-1 font-display font-extrabold leading-none', empty ? 'text-xl text-cafe/40' : 'text-4xl', tone === 'ambar' ? 'text-canela' : 'text-cafe')}>
        {empty ? 'Sin datos' : value}
        {!empty && unit && <span className="ml-1 font-body text-base font-normal text-cafe/70">{unit}</span>}
      </div>
      {hint && <div className="mt-1 text-xs text-cafe/70">{hint}</div>}
    </div>
  )
}

/** Error de negocio en la pantalla que originó la acción: qué pasó y qué hacer. */
export function ErrorBanner({ error, onRefresh, onRetry, onClose }) {
  if (!error) return null
  const stale = error.code === 'revision_desactualizada' || error.code === 'comando_conflicto'
  return (
    <div role="alert" className="rounded-2xl border border-[#b5432f]/30 bg-[#b5432f]/10 p-4 text-sm text-noche">
      <div className="font-semibold text-[#8a2f20]">{stale ? 'Los datos cambiaron' : 'No se pudo completar'}</div>
      <p className="mt-1">{error.message}</p>
      <div className="mt-3 flex flex-wrap gap-2">
        {onRefresh && <Button size="sm" variant="ghost" onClick={onRefresh}>Actualizar datos</Button>}
        {error.retryable && onRetry && <Button size="sm" variant="primary" onClick={onRetry}>Reintentar</Button>}
        {onClose && <Button size="sm" variant="ghost" onClick={onClose}>Cerrar</Button>}
      </div>
    </div>
  )
}

export function Notice({ tone = 'info', children, className }) {
  const tones = { info: 'bg-glaciar/25 text-noche', warn: 'bg-ambar/25 text-noche', ok: 'bg-[#2f5d46]/10 text-[#1f3d2e]', dark: 'bg-noche text-crema' }
  return <div className={cx('rounded-2xl p-4 text-sm', tones[tone], className)}>{children}</div>
}

export function Loading({ label = 'Cargando…' }) {
  return (
    <div className="flex items-center gap-3 p-6 text-cafe/70">
      <span className="h-5 w-5 animate-spin rounded-full border-2 border-canela border-t-transparent" />
      {label}
    </div>
  )
}

export function LoadError({ error, onRetry }) {
  return (
    <Notice tone="warn">
      <div className="font-semibold">No pudimos cargar los datos.</div>
      <div className="mt-1">{error}</div>
      {onRetry && <Button className="mt-3" size="sm" variant="ghost" onClick={onRetry}>Reintentar</Button>}
    </Notice>
  )
}

export function Empty({ title, children }) {
  return (
    <div className="flex flex-col items-center gap-2 rounded-3xl border border-dashed border-cafe/20 p-8 text-center text-cafe/70">
      <BeanIcon className="h-8 w-8 text-canela/60" />
      <div className="font-display text-lg font-extrabold text-cafe/80">{title}</div>
      {children && <div className="text-sm">{children}</div>}
    </div>
  )
}

/** Hoja inferior en móvil, modal centrado en escritorio. */
export function Sheet({ open, onClose, title, children, footer }) {
  useEffect(() => {
    if (!open) return
    const onKey = (e) => e.key === 'Escape' && onClose?.()
    window.addEventListener('keydown', onKey)
    document.body.style.overflow = 'hidden'
    return () => { window.removeEventListener('keydown', onKey); document.body.style.overflow = '' }
  }, [open, onClose])
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div className="absolute inset-0 bg-noche/50" onClick={onClose} />
      <div className="relative max-h-[92vh] w-full overflow-y-auto rounded-t-3xl bg-crema p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] sm:max-w-lg sm:rounded-3xl">
        <div className="mb-4 flex items-start justify-between gap-4">
          <H2>{title}</H2>
          <button onClick={onClose} className="-m-2 rounded-full p-2 text-cafe/60 hover:bg-cafe/5" aria-label="Cerrar">✕</button>
        </div>
        {children}
        {footer && <div className="mt-5">{footer}</div>}
      </div>
    </div>
  )
}

export function BeanIcon({ className }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden>
      <ellipse cx="12" cy="12" rx="7" ry="9.5" transform="rotate(30 12 12)" />
      <path d="M8.2 5.6c2.6 2.2 1.2 5.2 2.6 7.6 1.1 1.9 3.4 2.4 4.6 5.2" stroke="#F4EDE3" strokeWidth="1.4" fill="none" strokeLinecap="round" />
    </svg>
  )
}

export function Mountains({ className }) {
  return (
    <svg viewBox="0 0 400 120" className={className} preserveAspectRatio="none" aria-hidden>
      <path d="M0 120 L70 48 L105 78 L165 18 L230 92 L270 60 L330 104 L400 40 L400 120 Z" fill="#7FB7C9" opacity=".55" />
      <path d="M0 120 L55 80 L120 104 L190 54 L260 110 L320 76 L400 98 L400 120 Z" fill="#8C5A3C" opacity=".9" />
      <path d="M152 31 L165 18 L178 33 L170 30 L165 36 L159 30 Z" fill="#F4EDE3" />
      <path d="M388 50 L400 40 L400 54 Z" fill="#F4EDE3" />
    </svg>
  )
}

export function Logo({ className, light }) {
  return (
    <div className={cx('flex items-center gap-2', className)}>
      <svg viewBox="0 0 64 64" className="h-9 w-9 shrink-0" aria-hidden>
        <rect width="64" height="64" rx="16" fill={light ? '#F4EDE3' : '#3B2416'} />
        <path d="M8 46 24 24l8 10 8-14 16 26z" fill="#7FB7C9" />
        <ellipse cx="32" cy="50" rx="7" ry="4.5" fill="#E0A458" />
      </svg>
      <div className="leading-none">
        <div className={cx('font-display text-lg font-extrabold', light ? 'text-crema' : 'text-cafe')}>Calafate</div>
        <div className={cx('text-[10px] font-semibold uppercase tracking-[.2em]', light ? 'text-ambar' : 'text-canela')}>Coffee Roasters</div>
      </div>
    </div>
  )
}

export function Bag({ className, label = '250' }) {
  return (
    <svg viewBox="0 0 80 100" className={className} aria-hidden>
      <path d="M14 12h52l6 80a6 6 0 0 1-6 6H14a6 6 0 0 1-6-6z" fill="#8C5A3C" />
      <path d="M14 12h52l1 10H13z" fill="#3B2416" />
      <rect x="20" y="40" width="40" height="34" rx="4" fill="#F4EDE3" />
      <path d="M24 66 34 52l5 6 5-8 12 16z" fill="#7FB7C9" />
      <circle cx="40" cy="30" r="3" fill="#E0A458" />
      <text x="40" y="90" textAnchor="middle" fontSize="10" fontFamily="Work Sans" fill="#F4EDE3">{label}</text>
    </svg>
  )
}

export function Progress({ value, max, className }) {
  const p = max > 0 ? Math.min(100, (value / max) * 100) : 0
  return (
    <div className={cx('h-3 w-full overflow-hidden rounded-full bg-cafe/10', className)}>
      <div className={cx('h-full rounded-full', p > 90 ? 'bg-[#b5432f]' : p > 70 ? 'bg-ambar' : 'bg-canela')} style={{ width: p + '%' }} />
    </div>
  )
}
