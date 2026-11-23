import { Link } from 'react-router-dom'
import { Card, H1 } from '../../components/ui'

const LINKS = [
  ['/admin/devoluciones', 'Devoluciones', 'Reclamos, merma, reposición y notas de crédito'],
  ['/admin/lotes', 'Lotes', 'Stock por lote y bloqueo para mayoristas'],
  ['/admin/caja', 'Caja y propuestas', 'Cierres de barra y correcciones'],
  ['/admin/precios', 'Precios', 'Listas con vigencia desde una fecha'],
  ['/admin/zonas', 'Zonas de reparto', 'Lista editable'],
  ['/admin/informes', 'Informes', 'Ventas por canal, merma, deudores y CSV'],
  ['/admin/auditoria', 'Auditoría', 'Comandos y eventos'],
]
export default function Mas() {
  return (
    <div className="space-y-3">
      <H1>Más</H1>
      {LINKS.map(([to, t, d]) => (
        <Link key={to} to={to}><Card className="mb-2"><div className="font-display text-lg font-extrabold">{t}</div><div className="text-sm text-cafe/70">{d}</div></Card></Link>
      ))}
    </div>
  )
}
