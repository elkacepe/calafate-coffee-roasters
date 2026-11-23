import { NavLink, Link, Outlet, useNavigate } from 'react-router-dom'
import { useAuth, HOME } from '../auth/AuthProvider'
import { Logo, Mountains, cx } from './ui'
import { useStoredState } from '../lib/cart'

export function PublicLayout() {
  const [cart] = useStoredState('calafate.carrito', [])
  const { role } = useAuth()
  const count = cart.reduce((a, i) => a + i.cantidad, 0)
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-30 border-b border-cafe/10 bg-crema/90 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
          <Link to="/"><Logo /></Link>
          <nav className="flex items-center gap-1 text-sm">
            <NavLink to="/seguimiento" className="whitespace-nowrap rounded-full px-3 py-2 hover:bg-cafe/5">Mi pedido</NavLink>
            <NavLink to="/carrito" className="relative rounded-full bg-cafe px-4 py-2 font-medium text-crema">
              Carrito{count > 0 && <span className="ml-2 rounded-full bg-ambar px-2 text-noche">{count}</span>}
            </NavLink>
          </nav>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-4 pb-24 pt-4"><Outlet /></main>
      <footer className="relative mt-8 bg-cafe text-crema">
        <Mountains className="absolute -top-10 left-0 h-12 w-full" />
        <div className="mx-auto max-w-5xl px-4 py-8 text-sm">
          <Logo light />
          <p className="mt-3 max-w-md text-crema/80">Tostamos en el local los lunes, miércoles y viernes. Abrimos de lunes a sábado de 9 a 20.</p>
          <div className="mt-4 flex gap-4 text-crema/70">
            <Link to={role ? HOME[role] : '/ingresar'} className="underline underline-offset-4">{role ? 'Ir a mi panel' : 'Ingreso equipo y mayoristas'}</Link>
          </div>
        </div>
      </footer>
    </div>
  )
}

const NAV = {
  admin: [
    { to: '/admin', label: 'Inicio', end: true }, { to: '/admin/pedidos', label: 'Pedidos' }, { to: '/admin/reparto', label: 'Reparto' },
    { to: '/admin/cuentas', label: 'Cuentas' }, { to: '/admin/mas', label: 'Más', mobileOnly: true },
    { to: '/admin/devoluciones', label: 'Devoluciones', desktop: true }, { to: '/admin/lotes', label: 'Lotes', desktop: true },
    { to: '/admin/caja', label: 'Caja y propuestas', desktop: true }, { to: '/admin/precios', label: 'Precios', desktop: true },
    { to: '/admin/zonas', label: 'Zonas', desktop: true }, { to: '/admin/informes', label: 'Informes', desktop: true },
    { to: '/admin/auditoria', label: 'Auditoría', desktop: true },
  ],
  mayorista: [{ to: '/mayorista', label: 'Comprar', end: true }, { to: '/mayorista/pedidos', label: 'Pedidos' }, { to: '/mayorista/cuenta', label: 'Cuenta' }],
  barra: [{ to: '/barra', label: 'Caja', end: true }, { to: '/barra/retiros', label: 'Retiros' }, { to: '/barra/stock', label: 'Stock' }],
  tostaduria: [{ to: '/tostaduria', label: 'Lotes', end: true }, { to: '/tostaduria/tostar', label: 'Tostar' }, { to: '/tostaduria/verde', label: 'Verde' }, { to: '/tostaduria/insumos', label: 'Insumos' }],
  reparto: [{ to: '/reparto', label: 'Hoy', end: true }],
}
const ROLE_NAME = { admin: 'Administración', mayorista: 'Portal mayorista', barra: 'Barra', tostaduria: 'Tostaduría y depósito', reparto: 'Reparto' }

export function StaffLayout() {
  const { role, profile, signOut } = useAuth()
  const nav = NAV[role] || []
  const navigate = useNavigate()
  return (
    <div className="min-h-screen pb-24 lg:pb-0">
      <header className="sticky top-0 z-30 bg-cafe text-crema">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <Link to={HOME[role] || '/'}><Logo light /></Link>
          <div className="flex items-center gap-3 text-right text-xs">
            <div className="hidden sm:block">
              <div className="font-medium">{profile?.full_name}</div>
              <div className="text-ambar">{ROLE_NAME[role]}</div>
            </div>
            <button onClick={async () => { await signOut(); navigate('/') }} className="rounded-full border border-crema/30 px-3 py-2">Salir</button>
          </div>
        </div>
      </header>
      <div className="mx-auto flex max-w-6xl gap-6 px-4 pt-4">
        <aside className="sticky top-20 hidden h-fit w-52 shrink-0 lg:block">
          <div className="mb-3 text-xs font-semibold uppercase tracking-widest text-canela">{ROLE_NAME[role]}</div>
          <nav className="flex flex-col gap-1">
            {nav.filter((n) => !n.mobileOnly).map((n) => (
              <NavLink key={n.to} to={n.to} end={n.end}
                className={({ isActive }) => cx('rounded-2xl px-4 py-2.5 text-sm', isActive ? 'bg-cafe font-medium text-crema' : 'hover:bg-cafe/5')}>
                {n.label}
              </NavLink>
            ))}
          </nav>
        </aside>
        <main className="min-w-0 flex-1 pb-8"><Outlet /></main>
      </div>
      <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-cafe/10 bg-crema/95 pb-[env(safe-area-inset-bottom)] backdrop-blur lg:hidden">
        <div className="mx-auto grid max-w-lg" style={{ gridTemplateColumns: `repeat(${nav.filter((n) => !n.desktop).length}, minmax(0,1fr))` }}>
          {nav.filter((n) => !n.desktop).map((n) => (
            <NavLink key={n.to} to={n.to} end={n.end}
              className={({ isActive }) => cx('flex h-16 flex-col items-center justify-center text-xs font-medium', isActive ? 'text-cafe' : 'text-cafe/50')}>
              {({ isActive }) => (<><span className={cx('mb-1 h-1.5 w-6 rounded-full', isActive ? 'bg-ambar' : 'bg-transparent')} />{n.label}</>)}
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  )
}
