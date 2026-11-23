import { useState } from 'react'
import { useLocation } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { ars, fmtDay, CONDICION, RESOLUCION } from '../../lib/format'
import { Badge, Card, Empty, H1, H2, Loading, LoadError, Notice } from '../../components/ui'
import { OrderDetailSheet } from '../../components/OrderDetail'

export default function MisPedidos() {
  const loc = useLocation()
  const [open, setOpen] = useState(loc.state?.nuevo || null)
  const orders = useAsync(async () => {
    const { data, error } = await supabase.from('orders').select('id, number, status, total, scheduled_date, created_at, recurring_id, replacement_for_return_id').order('created_at', { ascending: false }).limit(60)
    if (error) throw error
    return data
  }, [])
  const returns = useAsync(async () => (await supabase.from('returns').select('id, number, status, bags, condition, resolution, amount, requested_at').order('requested_at', { ascending: false })).data, [])
  return (
    <div className="space-y-4">
      <H1>Tus pedidos</H1>
      {loc.state?.nuevo && <Notice tone="ok">¡Pedido enviado! Te mostramos el detalle con los lotes reservados.</Notice>}
      {orders.loading && <Loading />}
      {orders.error && <LoadError error={orders.error} onRetry={orders.reload} />}
      {orders.data?.length === 0 && <Empty title="Todavía no hay pedidos" />}
      <div className="space-y-2">
        {orders.data?.map((o) => (
          <button key={o.id} onClick={() => setOpen(o.id)} className="block w-full text-left">
            <Card className="flex items-center justify-between gap-3">
              <div>
                <div className="font-medium">#{o.number} {o.recurring_id && <span className="text-xs text-canela">· recurrente</span>}{o.replacement_for_return_id && <span className="text-xs text-canela">· reposición</span>}</div>
                <div className="text-xs text-cafe/60">Entrega {fmtDay(o.scheduled_date)}</div>
              </div>
              <div className="text-right"><Badge status={o.status} /><div className="num mt-1 text-sm">{o.total != null ? ars(o.total) : '—'}</div></div>
            </Card>
          </button>
        ))}
      </div>
      {returns.data?.length > 0 && (
        <div className="space-y-2">
          <H2>Reclamos y devoluciones</H2>
          {returns.data.map((r) => (
            <Card key={r.id} className="flex items-center justify-between gap-2 text-sm">
              <div>#{r.number} · {r.bags} bolsa(s) · {CONDICION[r.condition]}{r.resolution && <div className="text-xs text-cafe/60">{RESOLUCION[r.resolution]}</div>}</div>
              <Badge status={r.status} />
            </Card>
          ))}
        </div>
      )}
      <OrderDetailSheet orderId={open} role="mayorista" onClose={() => setOpen(null)} onChanged={orders.reload} />
    </div>
  )
}
