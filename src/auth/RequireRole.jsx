import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from './AuthProvider'
import { Loading } from '../components/ui'

export function RequireRole({ roles, children }) {
  const { session, role, ready } = useAuth()
  const loc = useLocation()
  if (!ready) return <Loading />
  if (!session) return <Navigate to={`/ingresar?volver=${encodeURIComponent(loc.pathname)}`} replace />
  if (!role) return <div className="p-6">Tu cuenta no tiene un rol asignado. Pedile a administración que lo cargue.</div>
  // El chequeo en pantalla es solo navegación: los permisos reales los aplica la base (RLS + funciones).
  if (!roles.includes(role)) return <Navigate to="/" replace />
  return children
}
