import { useState } from 'react'
import { Link } from 'react-router-dom'
import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { ars, grams, fmtDay } from '../../lib/format'
import { Badge, Card, H1, H2, Label, Loading, LoadError, Notice, Stat } from '../../components/ui'
import { OrderDetailSheet } from '../../components/OrderDetail'

export default function Inicio() {
  // Abrir el panel recalcula estados de lotes y, los lunes desde las 8, reserva los recurrentes (idempotente).
  const panel = useAsync(() => rpc('admin_open_panel'), [])
  const data = useAsync(async () => {
    const [orders, returns, proposals, debtors, lots, board] = await Promise.all([
      supabase.from('orders').select('id, number, status, channel, total, customer_id, hold_reason, wholesale_customers(name)').not('status', 'in', '("Entregado","Cancelado","Entregado parcial")').order('number'),
      supabase.from('returns').select('id', { count: 'exact', head: true }).in('status', ['Pedida', 'En revisión']),
      supabase.from('change_proposals').select('id', { count: 'exact', head: true }).eq('status', 'pendiente'),
      rpc('report_debtors'), rpc('lot_panel'), rpc('route_board', { p_date: null }),
    ])
    return { orders: orders.data || [], returns: returns.count, proposals: proposals.count, debtors, lots, board }
  }, [panel.data])
  const [open, setOpen] = useState(null)
  const d = data.data
  const rec = panel.data?.recurrentes
  const by = (s) => d?.orders.filter((o) => o.status === s) || []
  const vencidos = d?.debtors.filter((x) => x.credito.dias_vencido > 15) || []

  return (
    <div className="space-y-5">
      <H1>Hoy en Calafate</H1>
      {panel.error && <LoadError error={panel.error} onRetry={panel.reload} />}
      {rec?.ok && rec.pedidos?.length > 0 && !rec.repetido && (
        <Notice tone="info">Se reservaron los recurrentes del lunes: {rec.pedidos.map((p) => `${p.cliente} (${p.estado})`).join(', ')}.</Notice>
      )}
      {data.loading && !d && <Loading />}
      {d && (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Stat label="Confirmados" value={by('Confirmado').length} />
            <Stat label="Listos" value={by('Listo').length} />
            <Stat label="Para reprogramar" value={by('Para reprogramar').length} tone="ambar" />
            <Stat label="Retenidos" value={by('Retenido').length} tone="ambar" />
          </div>
          {by('Retenido').length > 0 && (
            <Card>
              <H2>Pedidos retenidos</H2>
              <ul className="mt-2 space-y-2">
                {by('Retenido').map((o) => (
                  <li key={o.id}><button className="flex w-full items-center justify-between rounded-2xl bg-noche px-4 py-3 text-left text-crema" onClick={() => setOpen(o.id)}>
                    <span>#{o.number} · {o.wholesale_customers?.name}<span className="block text-xs text-ambar">{o.hold_reason === 'deuda_vencida' ? 'Deuda vencida > 15 días' : o.hold_reason}</span></span>
                    <span className="text-xs underline">Ver</span>
                  </button></li>
                ))}
              </ul>
              <div className="mt-2 text-xs">Registrá el pago en <Link to="/admin/cuentas" className="underline">Cuentas</Link> y después liberá el pedido.</div>
            </Card>
          )}
          <div className="grid gap-3 sm:grid-cols-3">
            <Link to="/admin/devoluciones"><Stat label="Devoluciones por decidir" value={d.returns} hint="Pedidas y en revisión" /></Link>
            <Link to="/admin/caja"><Stat label="Propuestas pendientes" value={d.proposals} /></Link>
            <Link to="/admin/cuentas"><Stat label="Mayoristas con deuda vencida" value={vencidos.length} hint={vencidos.map((v) => v.cliente).join(', ') || 'Nadie'} /></Link>
          </div>
          <Card>
            <div className="flex items-center justify-between"><H2>Recorridos de hoy</H2><Link className="text-sm underline" to="/admin/reparto">Armar</Link></div>
            <ul className="mt-2 space-y-2 text-sm">
              {d.board.recorridos.map((r) => (
                <li key={r.id} className="flex items-center justify-between rounded-2xl bg-white px-3 py-2"><span>{r.zona} · {r.franja} · {grams(r.carga_g)} / {grams(r.capacidad_g)}</span><Badge status={r.estado} /></li>
              ))}
              {d.board.recorridos.length === 0 && <li className="text-cafe/60">Sin recorridos.</li>}
            </ul>
            {d.board.pendientes.length > 0 && <div className="mt-2 text-xs">{d.board.pendientes.length} pedido(s) de envío sin recorrido.</div>}
          </Card>
          <Card>
            <H2>Lotes</H2>
            <div className="mt-2 flex flex-wrap gap-2">
              {['En reposo', 'Disponible', 'Solo barra', 'Agotado'].map((s) => (
                <Link key={s} to="/admin/lotes"><Badge status={s}>{s} · {d.lots.filter((l) => l.estado === s).length}</Badge></Link>
              ))}
            </div>
            {d.lots.filter((l) => l.estado === 'En reposo').map((l) => <div key={l.id} className="mt-2 text-sm">{l.codigo} · {l.cafe}: {grams(l.tostado_g)} en reposo.</div>)}
          </Card>
        </>
      )}
      <OrderDetailSheet orderId={open} role="admin" onClose={() => setOpen(null)} onChanged={data.reload} />
    </div>
  )
}
