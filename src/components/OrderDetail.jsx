import { useState } from 'react'
import { rpc } from '../lib/supabase'
import { useAsync } from '../lib/useAsync'
import { useCommand } from '../lib/commands'
import { returnAllowed } from '../domain/rules'
import { ars, fmtDateTime, fmtDay, grams, PRESENTACION, CONDICION, RESOLUCION, roastedLabel } from '../lib/format'
import { waLink } from '../lib/whatsapp'
import { Badge, Button, ErrorBanner, Field, Input, Label, Loading, LoadError, Notice, Select, Sheet, Textarea } from './ui'

/**
 * Detalle de pedido. role: 'admin' | 'mayorista' | 'barra'
 * Acciones según estado y rol; todas por comando con la revisión que se está viendo.
 */
export function OrderDetailSheet({ orderId, role, onClose, onChanged }) {
  const { data: o, error, loading, reload } = useAsync(() => (orderId ? rpc('order_detail', { p_order: orderId }) : null), [orderId])
  const cmd = useCommand()
  const [reclamo, setReclamo] = useState(null)
  const [motivo, setMotivo] = useState('')

  async function act(type, payload = {}) {
    const res = await cmd.run(type, { pedido_id: o.id, ...payload }, o.revision)
    if (res?.ok) { await reload(); onChanged?.() }
    return res
  }
  const canReturn = o && ['Entregado', 'Entregado parcial'].includes(o.status) && returnAllowed(o.delivered_at, new Date())
  const avisoTexto = o && `Hola${o.cliente ? ' ' + o.cliente : o.retail_name ? ' ' + o.retail_name.split(' ')[0] : ''}, tu pedido #${o.number} de Calafate Coffee Roasters está «${o.status}». ${o.status === 'Retenido' ? 'Quedó retenido por la cuenta corriente: cuando registremos el pago lo liberamos.' : ''}`

  return (
    <Sheet open={!!orderId} onClose={onClose} title={o ? `Pedido #${o.number}` : 'Pedido'}>
      {loading && <Loading />}
      {error && <LoadError error={error} onRetry={reload} />}
      {o && (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge status={o.status} />
            <span className="rounded-full bg-cafe/5 px-2.5 py-1 text-xs capitalize">{o.channel}</span>
            {o.replacement_for_return_id && <span className="rounded-full bg-glaciar/40 px-2.5 py-1 text-xs">Reposición</span>}
            <span className="text-xs text-cafe/60">v{o.revision}</span>
          </div>
          <div className="text-sm">
            <div className="font-medium">{o.cliente || o.retail_name || 'Barra'}</div>
            {o.retail_phone && <div>{o.retail_phone}</div>}
            {o.fulfillment === 'envio' && <div>{o.address} · {o.zona}</div>}
            {o.fulfillment === 'retiro' && <div>Retiro en el local</div>}
            {o.scheduled_date && <div>Para el {fmtDay(o.scheduled_date)}</div>}
            {o.hold_reason && <Notice tone="dark" className="mt-2">Retenido: {o.hold_reason === 'deuda_vencida' ? 'deuda vencida de más de 15 días' : o.hold_reason === 'limite_credito' ? 'límite de crédito superado' : o.hold_reason}</Notice>}
            {o.intentos_fallidos > 0 && <Notice tone="warn" className="mt-2">{o.intentos_fallidos} intento(s) de entrega fallido(s).{o.intentos_fallidos >= 2 && ' Administración decide si se cancela o se reintenta.'}</Notice>}
          </div>
          <ul className="divide-y divide-cafe/10 rounded-2xl bg-white/70 px-3">
            {o.lineas.map((l) => (
              <li key={l.id} className="py-3 text-sm">
                <div className="flex justify-between gap-2">
                  <span>{l.cantidad} × {l.cafe || l.bebida} {l.presentacion && <span className="text-cafe/60">· {PRESENTACION[l.presentacion]} · <span className="capitalize">{l.molienda}</span></span>}</span>
                  <span className="num">{l.total != null ? ars(l.total) : '—'}</span>
                </div>
                {l.lotes.length > 0 && (
                  <div className="mt-1 flex flex-wrap gap-1">
                    {l.lotes.map((lt, i) => (
                      <span key={i} className="rounded-full bg-ambar/25 px-2 py-0.5 text-[11px]">
                        {lt.codigo} · {grams(lt.gramos)} · {roastedLabel(lt.tostado_el)}{lt.estado !== 'reservada' && ` · ${lt.estado}`}
                      </span>
                    ))}
                  </div>
                )}
                {canReturn && l.tipo === 'cafe' && (role === 'mayorista' || role === 'admin') && (
                  <button className="mt-1 text-xs underline" onClick={() => setReclamo({ linea_id: l.id, bolsas: 1, condicion: 'mal_sellada', motivo: '', max: l.cantidad })}>Reclamar una bolsa</button>
                )}
              </li>
            ))}
          </ul>
          <div className="flex justify-between font-display text-xl font-extrabold"><span>Total</span><span className="num">{o.total != null ? ars(o.total) : 'Se calcula al confirmar'}</span></div>
          {o.shipping_fee > 0 && <div className="-mt-3 text-xs text-cafe/60">Incluye envío {ars(o.shipping_fee)}</div>}
          {o.devoluciones.length > 0 && (
            <div className="space-y-1 text-sm">
              <Label>Devoluciones</Label>
              {o.devoluciones.map((d) => (
                <div key={d.id} className="flex items-center justify-between rounded-2xl bg-white/70 px-3 py-2">
                  <span>#{d.numero} · {d.bolsas} bolsa(s) · {CONDICION[d.condicion]}</span><Badge status={d.estado} />
                </div>
              ))}
            </div>
          )}
          <div className="text-xs text-cafe/60">Creado {fmtDateTime(o.created_at)}{o.confirmed_at && ` · confirmado ${fmtDateTime(o.confirmed_at)}`}{o.delivered_at && ` · entregado ${fmtDateTime(o.delivered_at)}`}</div>

          <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); reload() }} />

          <div className="grid gap-2">
            {o.status === 'Borrador' && (role === 'mayorista' || role === 'admin') && (
              <Button size="lg" busy={cmd.busy} onClick={() => act('confirmar_pedido')}>Confirmar y reservar</Button>
            )}
            {role === 'admin' && o.status === 'Retenido' && <Button size="lg" busy={cmd.busy} onClick={() => act('liberar_retenido')}>Liberar y reservar</Button>}
            {role === 'admin' && o.status === 'Confirmado' && o.channel !== 'barra' && <Button busy={cmd.busy} onClick={() => act('cambiar_estado_pedido', { a: 'En preparación' })}>Pasar a En preparación</Button>}
            {role === 'admin' && o.status === 'En preparación' && <Button busy={cmd.busy} onClick={() => act('cambiar_estado_pedido', { a: 'Listo' })}>Marcar Listo</Button>}
            {(role === 'admin' || role === 'barra') && o.channel === 'web' && o.fulfillment === 'retiro' && o.status === 'Listo' && (
              <RetiroButton busy={cmd.busy} onGo={(metodo) => act('entregar_retiro', { metodo })} />
            )}
            {o.channel !== 'barra' && o.retail_phone && (
              <a href={waLink(avisoTexto, o.retail_phone)} target="_blank" rel="noreferrer"><Button variant="whatsapp" className="w-full">Avisar por WhatsApp</Button></a>
            )}
            {(((role === 'admin') && ['Borrador', 'Confirmado', 'En preparación', 'Listo', 'Retenido', 'Para reprogramar'].includes(o.status))
              || (role === 'mayorista' && ['Borrador', 'Confirmado'].includes(o.status))) && (
              <div className="mt-2 rounded-2xl border border-cafe/10 p-3">
                <Field label="Cancelar pedido" hint="Libera la reserva de café."><Input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Motivo" /></Field>
                <Button variant="danger" className="mt-2 w-full" busy={cmd.busy} disabled={motivo.trim().length < 3} onClick={() => act('cancelar_pedido', { motivo })}>Cancelar pedido</Button>
              </div>
            )}
          </div>
        </div>
      )}

      <Sheet open={!!reclamo} onClose={() => setReclamo(null)} title="Reclamo">
        {reclamo && (
          <div className="space-y-3">
            <Field label="Bolsas"><Input type="number" min={1} max={reclamo.max} value={reclamo.bolsas} onChange={(e) => setReclamo({ ...reclamo, bolsas: Number(e.target.value) })} /></Field>
            <Field label="¿Cómo está la bolsa?">
              <Select value={reclamo.condicion} onChange={(e) => setReclamo({ ...reclamo, condicion: e.target.value })}>
                {Object.entries(CONDICION).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </Select>
            </Field>
            <Field label="Contanos qué pasó"><Textarea value={reclamo.motivo} onChange={(e) => setReclamo({ ...reclamo, motivo: e.target.value })} /></Field>
            <Notice tone="info">Se aceptan hasta 7 días desde la entrega. Cerrada y en buen estado vuelve al stock; abierta, defectuosa o mal sellada se registra como merma.</Notice>
            <ErrorBanner error={cmd.error} onRefresh={reload} />
            <Button size="lg" className="w-full" busy={cmd.busy} disabled={reclamo.motivo.trim().length < 3}
              onClick={async () => { const r = await act('pedir_devolucion', { linea_id: reclamo.linea_id, bolsas: reclamo.bolsas, condicion: reclamo.condicion, motivo: reclamo.motivo }); if (r?.ok) setReclamo(null) }}>
              Enviar reclamo
            </Button>
          </div>
        )}
      </Sheet>
    </Sheet>
  )
}

function RetiroButton({ onGo, busy }) {
  const [m, setM] = useState('efectivo')
  return (
    <div className="flex gap-2">
      <Select value={m} onChange={(e) => setM(e.target.value)}>
        <option value="efectivo">Efectivo</option><option value="tarjeta">Tarjeta</option><option value="transferencia">Transferencia</option><option value="qr">QR</option>
      </Select>
      <Button className="shrink-0" busy={busy} onClick={() => onGo(m)}>Entregar y cobrar</Button>
    </div>
  )
}

export const RESOL_LABEL = RESOLUCION
