import { lazy, Suspense } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { PublicLayout, StaffLayout } from './components/Layouts'
import { RequireRole } from './auth/RequireRole'
import { supabaseConfigured } from './lib/supabase'
import { Notice, Loading } from './components/ui'

import Catalogo from './pages/publico/Catalogo'
import Carrito from './pages/publico/Carrito'
import Seguimiento from './pages/publico/Seguimiento'
import Ingresar from './pages/publico/Ingresar'
const Comprar = lazy(() => import('./pages/mayorista/Comprar'))
const MisPedidos = lazy(() => import('./pages/mayorista/Pedidos'))
const Cuenta = lazy(() => import('./pages/mayorista/Cuenta'))
const Caja = lazy(() => import('./pages/barra/Caja'))
const Retiros = lazy(() => import('./pages/barra/Retiros'))
const Stock = lazy(() => import('./pages/barra/Stock'))
const Lotes = lazy(() => import('./pages/tostaduria/Lotes'))
const Tostar = lazy(() => import('./pages/tostaduria/Tostar'))
const Verde = lazy(() => import('./pages/tostaduria/Verde'))
const Insumos = lazy(() => import('./pages/tostaduria/Insumos'))
const Hoy = lazy(() => import('./pages/reparto/Hoy'))
const Inicio = lazy(() => import('./pages/admin/Inicio'))
const Pedidos = lazy(() => import('./pages/admin/Pedidos'))
const RepartoAdmin = lazy(() => import('./pages/admin/Reparto'))
const Devoluciones = lazy(() => import('./pages/admin/Devoluciones'))
const Cuentas = lazy(() => import('./pages/admin/Cuentas'))
const CajaAdmin = lazy(() => import('./pages/admin/Caja'))
const Precios = lazy(() => import('./pages/admin/Precios'))
const Zonas = lazy(() => import('./pages/admin/Zonas'))
const Informes = lazy(() => import('./pages/admin/Informes'))
const Auditoria = lazy(() => import('./pages/admin/Auditoria'))
const Mas = lazy(() => import('./pages/admin/Mas'))

const staff = (roles, el) => <RequireRole roles={roles}>{el}</RequireRole>

export default function App() {
  return (
    <>
      {!supabaseConfigured && (
        <Notice tone="dark" className="rounded-none text-center">Falta configurar Supabase: copiá <code>.env.example</code> como <code>.env.local</code> con la URL y la clave pública de tu proyecto.</Notice>
      )}
      <Suspense fallback={<Loading />}>
      <Routes>
        <Route element={<PublicLayout />}>
          <Route index element={<Catalogo />} />
          <Route path="carrito" element={<Carrito />} />
          <Route path="seguimiento" element={<Seguimiento />} />
          <Route path="pedido/:numero" element={<Seguimiento />} />
          <Route path="ingresar" element={<Ingresar />} />
        </Route>
        <Route element={<StaffLayout />}>
          <Route path="mayorista" element={staff(['mayorista'], <Comprar />)} />
          <Route path="mayorista/pedidos" element={staff(['mayorista'], <MisPedidos />)} />
          <Route path="mayorista/cuenta" element={staff(['mayorista'], <Cuenta />)} />
          <Route path="barra" element={staff(['barra', 'admin'], <Caja />)} />
          <Route path="barra/retiros" element={staff(['barra', 'admin'], <Retiros />)} />
          <Route path="barra/stock" element={staff(['barra', 'admin'], <Stock />)} />
          <Route path="tostaduria" element={staff(['tostaduria', 'admin'], <Lotes />)} />
          <Route path="tostaduria/tostar" element={staff(['tostaduria', 'admin'], <Tostar />)} />
          <Route path="tostaduria/verde" element={staff(['tostaduria', 'admin'], <Verde />)} />
          <Route path="tostaduria/insumos" element={staff(['tostaduria', 'admin'], <Insumos />)} />
          <Route path="reparto" element={staff(['reparto', 'admin'], <Hoy />)} />
          <Route path="admin" element={staff(['admin'], <Inicio />)} />
          <Route path="admin/pedidos" element={staff(['admin'], <Pedidos />)} />
          <Route path="admin/reparto" element={staff(['admin'], <RepartoAdmin />)} />
          <Route path="admin/devoluciones" element={staff(['admin'], <Devoluciones />)} />
          <Route path="admin/cuentas" element={staff(['admin'], <Cuentas />)} />
          <Route path="admin/lotes" element={staff(['admin'], <Lotes mode="admin" />)} />
          <Route path="admin/caja" element={staff(['admin'], <CajaAdmin />)} />
          <Route path="admin/precios" element={staff(['admin'], <Precios />)} />
          <Route path="admin/zonas" element={staff(['admin'], <Zonas />)} />
          <Route path="admin/informes" element={staff(['admin'], <Informes />)} />
          <Route path="admin/auditoria" element={staff(['admin'], <Auditoria />)} />
          <Route path="admin/mas" element={staff(['admin'], <Mas />)} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </Suspense>
    </>
  )
}
