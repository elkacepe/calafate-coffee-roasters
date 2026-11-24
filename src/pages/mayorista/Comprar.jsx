import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useStoredState } from '../../lib/cart'
import { useCommand } from '../../lib/commands'
import { RULES, wholesaleKg } from '../../domain/rules'
import { ars, fmtDay, grams, roastedLabel, MOLIENDAS, localDate } from '../../lib/format'
import { DateInput, Badge, Button, Card, ErrorBanner, Field, H1, H2, Input, Label, Loading, LoadError, Notice, Segmented, Select, Sheet, Textarea, cx } from '../../components/ui'
import { useAuth } from '../../auth/AuthProvider'

export default function Comprar() {
  const { profile } = useAuth()
  const cat = useAsync(() => rpc('wholesale_catalog'), [])
  const credit = useAsync(() => rpc('credit_status', { p_customer: null }), [])
  const held = useAsync(async () => (await supabase.from('orders').select('id, number, status, hold_reason, scheduled_date, total').in('status', ['Retenido', 'Borrador']).order('created_at', { ascending: false })).data, [])
  const [cart, setCart] = useStoredState(`calafate.mayorista.${profile?.customer_id}`, [])
  const [review, setReview] = useState(false)
  const [fecha, setFecha] = useState('')
  const [notas, setNotas] = useState('')
  const cmd = useCommand()
  const navigate = useNavigate()

  const lines = cart.map((i) => {
    const c = cat.data?.find((x) => x.id === i.cafe_id)
    const price = c ? (i.presentacion === 'kg_grano' ? c.precio_grano : c.precio_molido) : null
    return { ...i, price, qty: i.cantidad }
  })
  const kgTotal = wholesaleKg(lines)
  const subtotal = lines.reduce((a, l) => a + (l.price || 0) * l.qty, 0)
  const blocked = credit.data?.bloqueado
  const tomorrow = new Date(Date.parse(localDate() + 'T12:00:00Z') + 86400000).toISOString().slice(0, 10)

  function add(c, pres, mol, qty) {
    const k = `${c.id}|${pres}|${mol}`
    const ex = cart.find((i) => `${i.cafe_id}|${i.presentacion}|${i.molienda}` === k)
    setCart(ex ? cart.map((i) => (i === ex ? { ...i, cantidad: i.cantidad + qty } : i)) : [...cart, { cafe_id: c.id, nombre: c.nombre, presentacion: pres, molienda: mol, cantidad: qty }])
  }
  async function send(confirmar) {
    const res = await cmd.run('crear_pedido_mayorista', {
      confirmar, fecha: fecha || tomorrow, notas,
      items: cart.map((i) => ({ cafe_id: i.cafe_id, presentacion: i.presentacion, molienda: i.molienda, cantidad: i.cantidad })),
    })
    if (res?.ok) { setCart([]); setReview(false); navigate('/mayorista/pedidos', { state: { nuevo: res.pedido_id } }) }
  }

  return (
    <div className="space-y-4">
      <H1>Hacé tu pedido</H1>
      {credit.data && (
        blocked ? (
          <Notice tone="dark"><div className="font-semibold text-ambar">No podés confirmar pedidos nuevos</div><div className="mt-1">{credit.data.mensaje}</div></Notice>
        ) : (
          <Card className="grid grid-cols-3 gap-2 text-center text-sm">
            <div><Label>Saldo</Label><div className="num font-display text-xl font-extrabold">{ars(credit.data.saldo)}</div></div>
            <div><Label>Límite</Label><div className="num font-display text-xl font-extrabold">{ars(credit.data.limite)}</div></div>
            <div><Label>Disponible</Label><div className="num font-display text-xl font-extrabold">{ars(Math.max(0, credit.data.limite - credit.data.exposicion))}</div></div>
          </Card>
        )
      )}
      {held.data?.filter((o) => o.status === 'Retenido').map((o) => (
        <Notice key={o.id} tone="warn">Tu pedido recurrente #{o.number} quedó <b>retenido</b>{o.hold_reason === 'deuda_vencida' ? ' por deuda vencida' : ''}. Esos kilos no están reservados todavía: cuando administración registre el pago, se libera y se reserva del lote disponible.</Notice>
      ))}
      {cat.loading && <Loading />}
      {cat.error && <LoadError error={cat.error} onRetry={cat.reload} />}
      <div className="grid gap-3 sm:grid-cols-2">
        {cat.data?.map((c) => <WholesaleCard key={c.id} c={c} onAdd={add} />)}
      </div>
      {cart.length > 0 && (
        <div className="fixed inset-x-0 bottom-16 z-30 px-4 lg:bottom-4">
          <div className="mx-auto flex max-w-lg items-center justify-between gap-3 rounded-3xl bg-noche p-3 pl-5 text-crema shadow-card">
            <div className="text-sm"><b>{kgTotal} kg</b> · {ars(subtotal)}</div>
            <Button variant="accent" onClick={() => setReview(true)}>Revisar pedido</Button>
          </div>
        </div>
      )}
      <Sheet open={review} onClose={() => setReview(false)} title="Revisión del pedido">
        <ul className="divide-y divide-cafe/10">
          {lines.map((l, i) => (
            <li key={i} className="flex items-center justify-between gap-2 py-2 text-sm">
              <div>{l.cantidad} kg {l.nombre}<div className="text-xs capitalize text-cafe/60">{l.presentacion === 'kg_grano' ? 'grano' : `molido · ${l.molienda}`} · {ars(l.price)}/kg</div></div>
              <div className="flex items-center gap-1">
                <button className="h-9 w-9 rounded-full border border-cafe/20" onClick={() => setCart(cart.map((x, j) => j === i ? { ...x, cantidad: Math.max(1, x.cantidad - 1) } : x))}>−</button>
                <button className="h-9 w-9 rounded-full border border-cafe/20" onClick={() => setCart(cart.map((x, j) => j === i ? { ...x, cantidad: x.cantidad + 1 } : x))}>+</button>
                <button className="h-9 w-9 text-cafe/50" onClick={() => setCart(cart.filter((_, j) => j !== i))}>✕</button>
              </div>
            </li>
          ))}
        </ul>
        <div className="mt-2 flex justify-between font-display text-xl font-extrabold"><span>{kgTotal} kg</span><span className="num">{ars(subtotal)}</span></div>
        {kgTotal < RULES.minWholesaleKg && <Notice tone="warn" className="mt-2">El pedido mínimo es de {RULES.minWholesaleKg} kg.</Notice>}
        <div className="mt-4 space-y-3">
          <Field label="Entrega"><DateInput label="Entrega" disableSundays min={tomorrow} value={fecha || tomorrow} onChange={(e) => setFecha(e.target.value)} /></Field>
          <Field label="Notas"><Textarea value={notas} onChange={(e) => setNotas(e.target.value)} placeholder="Horario de recepción, etc." /></Field>
          <Notice tone="info">Al confirmar se congela el precio de cada línea y se reserva café de un lote concreto. Pagás a {RULES.paymentTermsDays} días desde la entrega.</Notice>
          <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); cat.reload(); credit.reload() }} onRetry={() => send(true)} />
          <div className="grid grid-cols-2 gap-2">
            <Button variant="ghost" busy={cmd.busy} disabled={!cart.length} onClick={() => send(false)}>Guardar borrador</Button>
            <Button busy={cmd.busy} disabled={kgTotal < RULES.minWholesaleKg || blocked} onClick={() => send(true)}>Confirmar</Button>
          </div>
        </div>
      </Sheet>
    </div>
  )
}

function WholesaleCard({ c, onAdd }) {
  const [pres, setPres] = useState('kg_grano')
  const [mol, setMol] = useState('espresso')
  const [qty, setQty] = useState(2)
  const kgAvail = Math.floor((c.disponible_g || 0) / 1000)
  return (
    <Card>
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="font-display text-xl font-extrabold">{c.nombre}</h2>
          {c.tostado_el ? <div className="text-xs font-semibold text-canela">{roastedLabel(c.tostado_el)}</div> : <div className="text-xs text-cafe/60">Sin lote disponible ahora</div>}
        </div>
        <div className="text-right"><div className="num font-display text-xl font-extrabold">{ars(pres === 'kg_grano' ? c.precio_grano : c.precio_molido)}</div><div className="text-xs">por kg</div></div>
      </div>
      {c.proximo_precio && <div className="mt-1 text-xs text-canela">Desde el {fmtDay(c.proximo_precio.desde)}: {ars(c.proximo_precio.precio)}/kg en grano. Lo confirmado antes no cambia.</div>}
      <div className="mt-3 space-y-2">
        <Segmented value={pres} onChange={setPres} options={[{ value: 'kg_grano', label: 'En grano' }, { value: 'kg_molido', label: 'Molido' }]} />
        {pres === 'kg_molido' && (
          <Select value={mol} onChange={(e) => setMol(e.target.value)}>{MOLIENDAS.filter((m) => m !== 'grano').map((m) => <option key={m} value={m}>Molienda {m}</option>)}</Select>
        )}
        <div className="flex items-center gap-2">
          <div className="flex items-center rounded-2xl border border-cafe/20 bg-white">
            <button className="h-11 w-11" onClick={() => setQty(Math.max(1, qty - 1))}>−</button>
            <span className="num w-10 text-center">{qty} kg</span>
            <button className="h-11 w-11" onClick={() => setQty(qty + 1)}>+</button>
          </div>
          <Button className="flex-1" disabled={kgAvail < 1} onClick={() => onAdd(c, pres, pres === 'kg_grano' ? 'grano' : mol, qty)}>Agregar</Button>
        </div>
        <div className={cx('text-xs', kgAvail < qty ? 'text-[#b5432f]' : 'text-cafe/60')}>Hoy hay {grams(c.disponible_g)} para mayoristas.</div>
      </div>
    </Card>
  )
}
