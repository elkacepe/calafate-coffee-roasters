import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useStoredState } from '../../lib/cart'
import { useCommand } from '../../lib/commands'
import { cartTotals } from '../../domain/rules'
import { ars, PRESENTACION, localDate, fmtDay } from '../../lib/format'
import { Button, Card, ErrorBanner, Field, H1, Input, Label, Segmented, Select, Textarea, Empty, Notice, cx } from '../../components/ui'

const STEPS = ['Carrito', 'Tus datos', 'Revisión']

export default function Carrito() {
  const [cart, setCart] = useStoredState('calafate.carrito', [])
  const [datos, setDatos] = useStoredState('calafate.datos', { nombre: '', celular: '', entrega: 'retiro', zona_id: '', direccion: '', fecha: '', notas: '' })
  const [step, setStep] = useState(0)
  const catalog = useAsync(() => rpc('public_catalog'), [])
  const { run, busy, error, clearError } = useCommand()
  const navigate = useNavigate()

  // Precios de referencia del catálogo actual; el precio final se congela en la base al confirmar.
  const items = useMemo(() => cart.map((i) => {
    const c = catalog.data?.cafes.find((x) => x.id === i.cafe_id)
    const price = c ? (i.presentacion === 'bolsa_250' ? c.precio_250 : c.precio_1000) : i.precio
    return { ...i, price, qty: i.cantidad, tostado: c?.tostado_el }
  }), [cart, catalog.data])
  const totals = cartTotals(items, datos.entrega, {
    shippingFee: catalog.data?.envio.tarifa ?? 3500, freeShippingFrom: catalog.data?.envio.gratis_desde ?? 50000,
  })
  const today = localDate()
  const fechas = useMemo(() => {
    const out = []
    for (let i = 0; out.length < 6; i++) {
      const d = new Date(Date.parse(today + 'T12:00:00Z') + i * 86400000)
      if (d.getUTCDay() !== 0) out.push(d.toISOString().slice(0, 10))
    }
    return out
  }, [today])

  const datosError = !datos.nombre.trim() ? 'Contanos tu nombre.'
    : datos.celular.replace(/\D/g, '').length < 8 ? 'Revisá tu celular: con característica, solo números.'
    : datos.entrega === 'envio' && (!datos.zona_id || datos.direccion.trim().length < 4) ? 'Para el envío necesitamos zona y dirección.' : null

  async function confirmar() {
    const res = await run('crear_pedido_web', {
      nombre: datos.nombre.trim(), celular: datos.celular, entrega: datos.entrega,
      zona_id: datos.entrega === 'envio' ? datos.zona_id : null, direccion: datos.entrega === 'envio' ? datos.direccion : null,
      fecha: datos.fecha || fechas[0], notas: datos.notas,
      items: cart.map((i) => ({ cafe_id: i.cafe_id, presentacion: i.presentacion, molienda: i.molienda, cantidad: i.cantidad })),
    })
    if (res?.ok) {
      setCart([])
      navigate(`/pedido/${res.numero}`, { state: { celular: datos.celular, total: res.total } })
    }
  }

  if (!cart.length) return (
    <div className="py-6">
      <Empty title="Tu carrito está vacío">Elegí un café del catálogo.</Empty>
      <div className="mt-4 text-center"><Link to="/" className="underline">Ver cafés</Link></div>
    </div>
  )

  return (
    <div className="mx-auto max-w-xl">
      <H1>Tu pedido</H1>
      <ol className="my-4 flex gap-2 text-xs">
        {STEPS.map((s, i) => (
          <li key={s} className={cx('flex-1 rounded-full px-3 py-2 text-center font-medium', i === step ? 'bg-cafe text-crema' : i < step ? 'bg-ambar/40' : 'bg-cafe/5')}>{i + 1}. {s}</li>
        ))}
      </ol>

      {step === 0 && (
        <div className="space-y-3">
          {items.map((i, idx) => (
            <Card key={idx} className="flex items-center justify-between gap-3">
              <div className="min-w-0">
                <div className="font-medium">{i.nombre}</div>
                <div className="text-xs capitalize text-cafe/70">{PRESENTACION[i.presentacion]} · {i.molienda}</div>
                <div className="text-sm">{ars(i.price)} c/u</div>
              </div>
              <div className="flex items-center gap-1">
                <button className="h-10 w-10 rounded-full border border-cafe/20" onClick={() => setCart(cart.map((x, j) => j === idx ? { ...x, cantidad: Math.max(1, x.cantidad - 1) } : x))}>−</button>
                <span className="num w-6 text-center">{i.cantidad}</span>
                <button className="h-10 w-10 rounded-full border border-cafe/20" onClick={() => setCart(cart.map((x, j) => j === idx ? { ...x, cantidad: x.cantidad + 1 } : x))}>+</button>
                <button className="ml-1 h-10 w-10 rounded-full text-cafe/50" aria-label="Quitar" onClick={() => setCart(cart.filter((_, j) => j !== idx))}>✕</button>
              </div>
            </Card>
          ))}
          <Button size="lg" className="w-full" onClick={() => setStep(1)}>Seguir · {ars(totals.subtotal)}</Button>
        </div>
      )}

      {step === 1 && (
        <div className="space-y-4">
          <Field label="Tu nombre"><Input value={datos.nombre} onChange={(e) => setDatos({ ...datos, nombre: e.target.value })} autoComplete="name" /></Field>
          <Field label="Tu celular" hint="Con este número y el del pedido podés seguirlo."><Input inputMode="tel" value={datos.celular} onChange={(e) => setDatos({ ...datos, celular: e.target.value })} autoComplete="tel" placeholder="2966 41-0000" /></Field>
          <div>
            <div className="mb-1 text-sm font-medium">¿Cómo lo recibís?</div>
            <Segmented size="lg" value={datos.entrega} onChange={(v) => setDatos({ ...datos, entrega: v })}
              options={[{ value: 'retiro', label: 'Retiro en el local' }, { value: 'envio', label: 'Envío' }]} />
          </div>
          {datos.entrega === 'envio' && (
            <>
              <Field label="Zona">
                <Select value={datos.zona_id} onChange={(e) => setDatos({ ...datos, zona_id: e.target.value })}>
                  <option value="">Elegí tu zona</option>
                  {catalog.data?.zonas.map((z) => <option key={z.id} value={z.id}>{z.nombre}</option>)}
                </Select>
              </Field>
              <Field label="Dirección"><Input value={datos.direccion} onChange={(e) => setDatos({ ...datos, direccion: e.target.value })} autoComplete="street-address" /></Field>
            </>
          )}
          <Field label={datos.entrega === 'envio' ? '¿Qué día te lo llevamos?' : '¿Qué día retirás?'}>
            <Select value={datos.fecha || fechas[0]} onChange={(e) => setDatos({ ...datos, fecha: e.target.value })}>
              {fechas.map((f) => <option key={f} value={f}>{fmtDay(f)}</option>)}
            </Select>
          </Field>
          <Field label="Notas (opcional)"><Textarea value={datos.notas} onChange={(e) => setDatos({ ...datos, notas: e.target.value })} placeholder="Ej.: retiramos a eso de las 17" /></Field>
          {datosError && <div className="text-sm text-canela">{datosError}</div>}
          <div className="flex gap-2">
            <Button variant="ghost" onClick={() => setStep(0)}>Volver</Button>
            <Button className="flex-1" size="lg" disabled={!!datosError} onClick={() => setStep(2)}>Revisar pedido</Button>
          </div>
        </div>
      )}

      {step === 2 && (
        <div className="space-y-4">
          <Card>
            <Label>Resumen</Label>
            <ul className="mt-2 divide-y divide-cafe/10">
              {items.map((i, idx) => (
                <li key={idx} className="flex justify-between gap-3 py-2 text-sm">
                  <span>{i.cantidad} × {i.nombre} <span className="capitalize text-cafe/60">({PRESENTACION[i.presentacion]}, {i.molienda})</span></span>
                  <span className="num">{ars(i.price * i.cantidad)}</span>
                </li>
              ))}
            </ul>
            <div className="mt-2 space-y-1 border-t border-cafe/10 pt-2 text-sm">
              <div className="flex justify-between"><span>Subtotal</span><span className="num">{ars(totals.subtotal)}</span></div>
              {datos.entrega === 'envio' && <div className="flex justify-between"><span>Envío</span><span className="num">{totals.shipping ? ars(totals.shipping) : 'Gratis'}</span></div>}
              <div className="flex justify-between font-display text-xl font-extrabold"><span>Total</span><span className="num">{ars(totals.total)}</span></div>
            </div>
            {totals.faltaParaEnvioGratis > 0 && <div className="mt-2 text-xs text-canela">Te faltan {ars(totals.faltaParaEnvioGratis)} para el envío gratis.</div>}
          </Card>
          <Card className="text-sm">
            <div><b>{datos.nombre}</b> · {datos.celular}</div>
            <div>{datos.entrega === 'envio' ? `Envío a ${datos.direccion}` : 'Retiro en el local'} · {fmtDay(datos.fecha || fechas[0])}</div>
          </Card>
          <Notice tone="info">Al confirmar reservamos tu café de un lote concreto y te mostramos la fecha de tueste. El precio queda fijo. Pagás al retirar o al recibir.</Notice>
          <ErrorBanner error={error} onRefresh={() => { clearError(); catalog.reload(); setStep(0) }} onRetry={confirmar} />
          <div className="flex gap-2">
            <Button variant="ghost" onClick={() => setStep(1)}>Volver</Button>
            <Button className="flex-1" size="lg" busy={busy} onClick={confirmar}>Confirmar pedido</Button>
          </div>
        </div>
      )}
    </div>
  )
}
