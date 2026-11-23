import { useEffect, useState } from 'react'
import { useLocation, useParams, useSearchParams } from 'react-router-dom'
import { rpc } from '../../lib/supabase'
import { ars, fmtDay, roastedLabel, PRESENTACION } from '../../lib/format'
import { waLink } from '../../lib/whatsapp'
import { Badge, Button, Card, Field, H1, Input, Label, Notice, Loading } from '../../components/ui'

const PASOS = ['Confirmado', 'En preparación', 'Listo', 'En reparto', 'Entregado']

export default function Seguimiento() {
  const params = useParams()
  const loc = useLocation()
  const [sp] = useSearchParams()
  const [numero, setNumero] = useState(params.numero || sp.get('n') || '')
  const [celular, setCelular] = useState(loc.state?.celular || '')
  const [pedido, setPedido] = useState(null)
  const [msg, setMsg] = useState(null)
  const [loading, setLoading] = useState(false)
  const recien = Boolean(loc.state?.celular)

  async function buscar(e) {
    e?.preventDefault()
    setLoading(true); setMsg(null)
    try {
      const data = await rpc('track_order', { p_number: Number(numero), p_phone: celular })
      if (!data) setMsg('No encontramos un pedido con ese número y celular. Revisá los dos datos.')
      setPedido(data)
    } catch (err) { setMsg(err.message) } finally { setLoading(false) }
  }
  useEffect(() => { if (numero && celular) buscar() }, []) // eslint-disable-line

  const texto = pedido && `Mi pedido #${pedido.numero} en Calafate Coffee Roasters: ${pedido.lineas.map((l) => `${l.cantidad}× ${l.cafe}`).join(', ')}. Total ${ars(pedido.total)}. ${pedido.entrega === 'retiro' ? 'Retiro' : 'Envío'} el ${fmtDay(pedido.fecha)}.`
  const idx = pedido ? PASOS.indexOf(pedido.estado === 'Entregado parcial' ? 'Entregado' : pedido.estado) : -1

  return (
    <div className="mx-auto max-w-xl">
      {recien && pedido && (
        <div className="mb-6 rounded-3xl bg-cafe p-6 text-crema">
          <Label className="text-ambar">¡Listo, {pedido.nombre}!</Label>
          <div className="mt-1 font-display text-4xl font-extrabold">Pedido #{pedido.numero}</div>
          <p className="mt-2 text-crema/80">Tu café ya está reservado. Guardá el número: con él y tu celular lo seguís desde acá.</p>
          <a href={waLink(texto)} target="_blank" rel="noreferrer"><Button variant="whatsapp" className="mt-4 w-full">Guardarlo en WhatsApp</Button></a>
        </div>
      )}
      {!recien && <H1>Seguí tu pedido</H1>}
      {!pedido && (
        <form onSubmit={buscar} className="mt-4 space-y-4">
          <Field label="Número de pedido"><Input inputMode="numeric" value={numero} onChange={(e) => setNumero(e.target.value)} placeholder="1234" /></Field>
          <Field label="Tu celular"><Input inputMode="tel" value={celular} onChange={(e) => setCelular(e.target.value)} /></Field>
          {msg && <Notice tone="warn">{msg}</Notice>}
          <Button size="lg" className="w-full" busy={loading} disabled={!numero || !celular}>Buscar</Button>
        </form>
      )}
      {loading && !pedido && <Loading />}
      {pedido && (
        <div className="space-y-4">
          <Card>
            <div className="flex items-center justify-between"><Label>Pedido #{pedido.numero}</Label><Badge status={pedido.estado} /></div>
            {pedido.estado !== 'Cancelado' && (
              <ol className="mt-4 grid grid-cols-5 gap-1">
                {PASOS.filter((p) => pedido.entrega === 'envio' || p !== 'En reparto').map((p, i) => (
                  <li key={p} className="text-center text-[10px] leading-tight">
                    <div className={`mb-1 h-2 rounded-full ${i <= idx ? 'bg-canela' : 'bg-cafe/10'}`} />{p}
                  </li>
                ))}
              </ol>
            )}
            {pedido.estado === 'Para reprogramar' && <Notice tone="warn" className="mt-3">No pudimos entregarlo. Te escribimos para coordinar otro día: tu café sigue reservado.</Notice>}
          </Card>
          <Card>
            <ul className="divide-y divide-cafe/10">
              {pedido.lineas.map((l, i) => (
                <li key={i} className="py-2">
                  <div className="flex justify-between text-sm"><span>{l.cantidad} × {l.cafe}</span><span className="num">{ars(l.total)}</span></div>
                  <div className="text-xs capitalize text-cafe/60">{PRESENTACION[l.presentacion]} · {l.molienda}</div>
                  {l.tostado_el && <div className="mt-1 inline-block rounded-full bg-ambar/30 px-2 py-0.5 text-xs font-semibold">{roastedLabel(l.tostado_el, 'Tu café se tostó')}</div>}
                </li>
              ))}
            </ul>
            <div className="mt-2 flex justify-between border-t border-cafe/10 pt-2 font-display text-xl font-extrabold"><span>Total</span><span className="num">{ars(pedido.total)}</span></div>
            {pedido.envio > 0 && <div className="text-xs text-cafe/60">Incluye envío {ars(pedido.envio)}</div>}
          </Card>
          <Card className="text-sm">{pedido.entrega === 'retiro' ? 'Retirás en el local' : `Envío · ${pedido.zona}`} · {fmtDay(pedido.fecha)}</Card>
          <Button variant="ghost" className="w-full" onClick={() => setPedido(null)}>Buscar otro pedido</Button>
        </div>
      )}
    </div>
  )
}
