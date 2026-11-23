import { useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, fmtDay, fmtDateTime, MOLIENDAS } from '../../lib/format'
import { Badge, Button, Card, ErrorBanner, Field, H1, Input, Loading, LoadError, Select, Sheet, Empty } from '../../components/ui'
import { OrderDetailSheet } from '../../components/OrderDetail'

const ESTADOS = ['Borrador', 'Confirmado', 'En preparación', 'Listo', 'En reparto', 'Entregado', 'Entregado parcial', 'Para reprogramar', 'Cancelado', 'Retenido']

export default function Pedidos() {
  const [canal, setCanal] = useState('')
  const [estado, setEstado] = useState('')
  const [q, setQ] = useState('')
  const [open, setOpen] = useState(null)
  const [nuevo, setNuevo] = useState(false)
  const orders = useAsync(async () => {
    let query = supabase.from('orders').select('id, number, channel, status, total, retail_name, scheduled_date, created_at, fulfillment, replacement_for_return_id, wholesale_customers(name)').order('created_at', { ascending: false }).limit(200)
    if (canal) query = query.eq('channel', canal)
    if (estado) query = query.eq('status', estado)
    const { data, error } = await query
    if (error) throw error
    return data
  }, [canal, estado])
  const list = useMemo(() => (orders.data || []).filter((o) => !q || String(o.number).includes(q) || (o.wholesale_customers?.name || o.retail_name || '').toLowerCase().includes(q.toLowerCase())), [orders.data, q])
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2"><H1>Pedidos</H1><Button size="sm" onClick={() => setNuevo(true)}>Nuevo mayorista</Button></div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        <Select value={canal} onChange={(e) => setCanal(e.target.value)}><option value="">Todos los canales</option><option value="barra">Barra</option><option value="web">Web</option><option value="mayorista">Mayorista</option></Select>
        <Select value={estado} onChange={(e) => setEstado(e.target.value)}><option value="">Todos los estados</option>{ESTADOS.map((s) => <option key={s}>{s}</option>)}</Select>
        <Input className="col-span-2 sm:col-span-1" placeholder="Buscar número o nombre" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      {orders.loading && <Loading />}
      {orders.error && <LoadError error={orders.error} onRetry={orders.reload} />}
      {list.length === 0 && !orders.loading && <Empty title="Sin pedidos con ese filtro" />}
      <div className="space-y-2">
        {list.map((o) => (
          <button key={o.id} className="block w-full text-left" onClick={() => setOpen(o.id)}>
            <Card className="flex items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <div className="font-medium">#{o.number} · {o.wholesale_customers?.name || o.retail_name || 'Barra'}</div>
                <div className="text-xs capitalize text-cafe/60">{o.channel}{o.fulfillment !== 'barra' && ` · ${o.fulfillment}`}{o.replacement_for_return_id && ' · reposición'} · {o.channel === 'barra' ? fmtDateTime(o.created_at) : fmtDay(o.scheduled_date)}</div>
              </div>
              <div className="shrink-0 text-right"><Badge status={o.status} /><div className="num mt-1 text-sm">{o.total != null ? ars(o.total) : '—'}</div></div>
            </Card>
          </button>
        ))}
      </div>
      <OrderDetailSheet orderId={open} role="admin" onClose={() => setOpen(null)} onChanged={orders.reload} />
      <NuevoMayorista open={nuevo} onClose={() => setNuevo(false)} onDone={(id) => { setNuevo(false); orders.reload(); setOpen(id) }} />
    </div>
  )
}

function NuevoMayorista({ open, onClose, onDone }) {
  const data = useAsync(async () => {
    const [c, k] = await Promise.all([
      supabase.from('wholesale_customers').select('id, name').eq('active', true).order('name'),
      supabase.from('coffees').select('id, name').eq('active', true).order('sort'),
    ])
    return { customers: c.data || [], coffees: k.data || [] }
  }, [])
  const [cliente, setCliente] = useState('')
  const [items, setItems] = useState([{ cafe_id: '', presentacion: 'kg_grano', molienda: 'grano', cantidad: 2 }])
  const [confirmar, setConfirmar] = useState(true)
  const cmd = useCommand()
  const valid = cliente && items.every((i) => i.cafe_id && i.cantidad > 0)
  return (
    <Sheet open={open} onClose={onClose} title="Nuevo pedido mayorista">
      {!data.data ? <Loading /> : (
        <div className="space-y-3">
          <Field label="Cliente"><Select value={cliente} onChange={(e) => setCliente(e.target.value)}><option value="">Elegí</option>{data.data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          {items.map((it, i) => (
            <div key={i} className="grid grid-cols-6 gap-2">
              <div className="col-span-6"><Select value={it.cafe_id} onChange={(e) => setItems(items.map((x, j) => j === i ? { ...x, cafe_id: e.target.value } : x))}><option value="">Café</option>{data.data.coffees.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></div>
              <div className="col-span-3"><Select value={it.presentacion} onChange={(e) => setItems(items.map((x, j) => j === i ? { ...x, presentacion: e.target.value, molienda: e.target.value === 'kg_grano' ? 'grano' : 'espresso' } : x))}><option value="kg_grano">En grano</option><option value="kg_molido">Molido</option></Select></div>
              <div className="col-span-2"><Select value={it.molienda} disabled={it.presentacion === 'kg_grano'} onChange={(e) => setItems(items.map((x, j) => j === i ? { ...x, molienda: e.target.value } : x))}>{MOLIENDAS.map((m) => <option key={m}>{m}</option>)}</Select></div>
              <div className="col-span-1"><Input inputMode="numeric" value={it.cantidad} onChange={(e) => setItems(items.map((x, j) => j === i ? { ...x, cantidad: Number(e.target.value.replace(/\D/g, '')) } : x))} /></div>
            </div>
          ))}
          <button className="text-sm underline" onClick={() => setItems([...items, { cafe_id: '', presentacion: 'kg_grano', molienda: 'grano', cantidad: 1 }])}>Agregar línea</button>
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={confirmar} onChange={(e) => setConfirmar(e.target.checked)} /> Confirmar y reservar ahora</label>
          <ErrorBanner error={cmd.error} onRefresh={data.reload} />
          <Button size="lg" className="w-full" busy={cmd.busy} disabled={!valid}
            onClick={async () => { const r = await cmd.run('crear_pedido_mayorista', { cliente_id: cliente, confirmar, items }); if (r?.ok) onDone(r.pedido_id) }}>
            {confirmar ? 'Confirmar pedido' : 'Guardar borrador'}
          </Button>
        </div>
      )}
    </Sheet>
  )
}
