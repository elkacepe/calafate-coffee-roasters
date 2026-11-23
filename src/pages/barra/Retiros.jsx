import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { ars } from '../../lib/format'
import { Badge, Card, Empty, H1, Loading, LoadError } from '../../components/ui'
import { OrderDetailSheet } from '../../components/OrderDetail'

export default function Retiros() {
  const panel = useAsync(() => rpc('shift_panel'), [])
  const [open, setOpen] = useState(null)
  return (
    <div className="space-y-4">
      <H1>Retiros en el local</H1>
      <p className="text-sm">Pedidos web para retirar. Cuando están «Listo», entregás y cobrás desde el detalle.</p>
      {panel.loading && <Loading />}
      {panel.error && <LoadError error={panel.error} onRetry={panel.reload} />}
      {panel.data?.retiros.length === 0 && <Empty title="No hay retiros pendientes" />}
      {panel.data?.retiros.map((o) => (
        <button key={o.id} className="block w-full text-left" onClick={() => setOpen(o.id)}>
          <Card className="flex items-center justify-between">
            <div><div className="font-display text-2xl font-extrabold">#{o.numero}</div><div className="text-sm">{o.nombre} · {o.celular}</div></div>
            <div className="text-right"><Badge status={o.estado} /><div className="num mt-1">{ars(o.total)}</div></div>
          </Card>
        </button>
      ))}
      <OrderDetailSheet orderId={open} role="barra" onClose={() => setOpen(null)} onChanged={panel.reload} />
    </div>
  )
}
