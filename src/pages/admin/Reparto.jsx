import { useState } from 'react'
import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { routeFits } from '../../domain/rules'
import { grams, fmtDay, localDate } from '../../lib/format'
import { waLink } from '../../lib/whatsapp'
import { Badge, Button, Card, Empty, ErrorBanner, Field, H1, H2, Input, Label, Loading, LoadError, Notice, Progress, Select, Sheet } from '../../components/ui'
import { OrderDetailSheet } from '../../components/OrderDetail'

export default function Reparto() {
  const [fecha, setFecha] = useState(localDate())
  const board = useAsync(() => rpc('route_board', { p_date: fecha }), [fecha])
  const zones = useAsync(async () => (await supabase.from('zones').select('id, name').eq('active', true).order('sort')).data, [])
  const cmd = useCommand()
  const [crear, setCrear] = useState(false)
  const [asignar, setAsignar] = useState(null)
  const [open, setOpen] = useState(null)
  const b = board.data

  async function assign(order, route, confirmo = false) {
    const r = await cmd.run('asignar_a_recorrido', { recorrido_id: route.id, pedido_id: order.id, confirmo_reintento: confirmo || undefined }, route.revision)
    if (r?.ok) { setAsignar(null); board.reload() }
  }
  const hojaRuta = (r) => `Recorrido ${r.zona} ${r.franja} (${fmtDay(fecha)}):\n` + r.paradas.map((s) => `${s.orden}. #${s.numero} ${s.nombre} — ${s.direccion} — ${grams(s.gramos)}${s.cobrar ? ' — COBRAR' : ''}`).join('\n')

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <H1>Reparto</H1>
        <div className="flex gap-2">
          <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className="rounded-2xl border border-cafe/15 bg-white px-3 py-2 text-sm" />
          <Button size="sm" onClick={() => setCrear(true)}>Nuevo recorrido</Button>
        </div>
      </div>
      {board.loading && !b && <Loading />}
      {board.error && <LoadError error={board.error} onRetry={board.reload} />}
      <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); board.reload() }} />
      {b && (
        <div className="grid gap-4 lg:grid-cols-2">
          <div className="space-y-3">
            <H2>Recorridos</H2>
            {b.recorridos.length === 0 && <Empty title="No hay recorridos este día" />}
            {b.recorridos.map((r) => (
              <Card key={r.id}>
                <div className="flex items-start justify-between">
                  <div><Label>{r.franja} h · {r.repartidor || 'Sin repartidor'}</Label><div className="font-display text-xl font-extrabold">{r.zona}</div></div>
                  <Badge status={r.estado} />
                </div>
                <div className="mt-2 flex justify-between text-sm"><span>{grams(r.carga_g)} de {grams(r.capacidad_g)}</span><span>libre {grams(r.capacidad_g - r.carga_g)}</span></div>
                <Progress value={r.carga_g} max={r.capacidad_g} />
                <ul className="mt-3 divide-y divide-cafe/10 text-sm">
                  {r.paradas.map((s) => (
                    <li key={s.id} className="flex items-center justify-between gap-2 py-2">
                      <button className="text-left" onClick={() => setOpen(s.pedido_id)}>{s.orden}. #{s.numero} {s.nombre}<div className="text-xs text-cafe/60">{grams(s.gramos)}{s.reposicion && ' · reposición'}</div></button>
                      <div className="flex items-center gap-2">
                        <Badge status={s.resultado === 'pendiente' ? s.estado : s.resultado === 'no_entregado' ? 'Para reprogramar' : 'Entregado'} />
                        {r.estado === 'Planificado' && <button className="text-xs underline" onClick={async () => { const x = await cmd.run('quitar_de_recorrido', { parada_id: s.id }, r.revision); if (x?.ok) board.reload() }}>Quitar</button>}
                      </div>
                    </li>
                  ))}
                </ul>
                <div className="mt-3 grid grid-cols-2 gap-2">
                  <a href={waLink(hojaRuta(r))} target="_blank" rel="noreferrer"><Button size="sm" variant="whatsapp" className="w-full">Hoja de ruta</Button></a>
                  {r.estado === 'Planificado' && <Button size="sm" busy={cmd.busy} disabled={!r.paradas.length} onClick={async () => { const x = await cmd.run('iniciar_recorrido', { recorrido_id: r.id }, r.revision); if (x?.ok) board.reload() }}>Salir</Button>}
                </div>
              </Card>
            ))}
          </div>
          <div className="space-y-3">
            <H2>Pedidos para repartir</H2>
            <p className="text-sm text-cafe/70">Se cargan los «Listo» y los «Para reprogramar». Los confirmados aparecen para que los prepares.</p>
            {b.pendientes.length === 0 && <Empty title="No hay pedidos pendientes de envío" />}
            {b.pendientes.map((o) => (
              <Card key={o.id} className="flex items-center justify-between gap-2">
                <button className="min-w-0 text-left" onClick={() => setOpen(o.id)}>
                  <div className="font-medium">#{o.numero} · {o.nombre}</div>
                  <div className="text-xs text-cafe/60">{o.zona} · {grams(o.gramos)} · {fmtDay(o.fecha)}{o.reposicion && ' · reposición'}</div>
                  {o.intentos_fallidos > 0 && <div className="text-xs font-semibold text-[#b5432f]">{o.intentos_fallidos} intento(s) fallido(s)</div>}
                </button>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  <Badge status={o.estado} />
                  {['Listo', 'Para reprogramar'].includes(o.estado) && <Button size="sm" variant="ghost" onClick={() => setAsignar(o)}>Asignar</Button>}
                </div>
              </Card>
            ))}
          </div>
        </div>
      )}

      <Sheet open={!!asignar} onClose={() => { setAsignar(null); cmd.clearError() }} title={asignar ? `Asignar #${asignar.numero}` : ''}>
        {asignar && (
          <div className="space-y-2">
            <div className="text-sm">{asignar.nombre} · {asignar.zona} · {grams(asignar.gramos)}</div>
            {asignar.intentos_fallidos >= 2 && <Notice tone="warn">Ya falló {asignar.intentos_fallidos} veces. Si lo reasignás confirmás un intento más; si no, cancelalo desde el detalle y se libera la reserva.</Notice>}
            {b.recorridos.filter((r) => r.estado === 'Planificado').map((r) => {
              const fit = routeFits(r.carga_g, asignar.gramos, r.capacidad_g)
              return (
                <button key={r.id} disabled={!fit.fits || cmd.busy} onClick={() => assign(asignar, r, asignar.intentos_fallidos >= 2)}
                  className="flex w-full items-center justify-between rounded-2xl border border-cafe/15 bg-white p-3 text-left disabled:opacity-50">
                  <span>{r.zona} · {r.franja}{r.zona_id !== asignar.zona_id && <span className="block text-xs text-canela">Otra zona</span>}</span>
                  <span className="text-sm">{fit.fits ? `queda en ${grams(fit.after)}` : `no entra (libre ${grams(fit.free)})`}</span>
                </button>
              )
            })}
            {b.recorridos.filter((r) => r.estado === 'Planificado').length === 0 && <Notice>No hay recorridos planificados para este día. Creá uno.</Notice>}
            <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); board.reload() }} />
          </div>
        )}
      </Sheet>
      <NuevoRecorrido open={crear} onClose={() => setCrear(false)} fecha={fecha} zones={zones.data || []} drivers={b?.repartidores || []} onDone={() => { setCrear(false); board.reload() }} />
      <OrderDetailSheet orderId={open} role="admin" onClose={() => setOpen(null)} onChanged={board.reload} />
    </div>
  )
}

function NuevoRecorrido({ open, onClose, fecha, zones, drivers, onDone }) {
  const [f, setF] = useState({ zona_id: '', franja: '15-18', repartidor_id: '', capacidad_kg: '40' })
  const cmd = useCommand()
  return (
    <Sheet open={open} onClose={onClose} title={`Nuevo recorrido · ${fmtDay(fecha)}`}>
      <div className="space-y-3">
        <Field label="Zona"><Select value={f.zona_id} onChange={(e) => setF({ ...f, zona_id: e.target.value })}><option value="">Elegí</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}</Select></Field>
        <Field label="Franja"><Select value={f.franja} onChange={(e) => setF({ ...f, franja: e.target.value })}><option value="10-13">10 a 13</option><option value="15-18">15 a 18</option></Select></Field>
        <Field label="Repartidor"><Select value={f.repartidor_id} onChange={(e) => setF({ ...f, repartidor_id: e.target.value })}><option value="">Sin asignar</option>{drivers.map((d) => <option key={d.id} value={d.id}>{d.nombre}</option>)}</Select></Field>
        <Field label="Capacidad (kg)"><Input inputMode="numeric" value={f.capacidad_kg} onChange={(e) => setF({ ...f, capacidad_kg: e.target.value.replace(/\D/g, '') })} /></Field>
        <ErrorBanner error={cmd.error} onRefresh={onDone} />
        <Button size="lg" className="w-full" busy={cmd.busy} disabled={!f.zona_id}
          onClick={async () => { const r = await cmd.run('crear_recorrido', { fecha, zona_id: f.zona_id, franja: f.franja, repartidor_id: f.repartidor_id || null, capacidad_g: Number(f.capacidad_kg || 40) * 1000 }); if (r?.ok) onDone() }}>Crear</Button>
      </div>
    </Sheet>
  )
}
