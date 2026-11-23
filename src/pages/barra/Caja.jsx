import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ticketTotals, cashClose } from '../../domain/rules'
import { ars, grams, fmtTime, roastedLabel, untilLabel, METODOS } from '../../lib/format'
import { Badge, Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, LoadError, Notice, Segmented, Select, Sheet, Textarea, cx } from '../../components/ui'

export default function Caja() {
  const panel = useAsync(() => rpc('shift_panel'), [])
  const cmd = useCommand()
  const [ticket, setTicket] = useState([])
  const [metodo, setMetodo] = useState('efectivo')
  const [last, setLast] = useState(null)
  const [closing, setClosing] = useState(false)
  const [changing, setChanging] = useState(false)
  const p = panel.data
  const t = p?.turno

  if (panel.loading && !p) return <Loading />
  if (panel.error) return <LoadError error={panel.error} onRetry={panel.reload} />
  if (!t) return <AbrirTurno panel={p} onDone={panel.reload} />

  const drinks = p.bebidas
  const items = ticket.map((i) => {
    const d = drinks.find((x) => x.id === i.bebida_id)
    return { ...i, d, price: d.price, coffeeG: d.coffee_g, milkMl: d.milk_ml, qty: i.cantidad, almond: i.almendras }
  })
  const tot = ticketTotals(items, { almondExtra: p.almendras_extra })

  function tap(d) {
    setLast(null); cmd.clearError()
    const ex = ticket.find((i) => i.bebida_id === d.id && !i.almendras)
    setTicket(ex ? ticket.map((i) => (i === ex ? { ...i, cantidad: i.cantidad + 1 } : i)) : [...ticket, { bebida_id: d.id, cantidad: 1, almendras: false }])
  }
  async function cobrar() {
    const res = await cmd.run('vender_barra', { turno_id: t.id, metodo, items: ticket })
    if (res?.ok) { setLast(res); setTicket([]); setMetodo('efectivo'); panel.reload() }
  }

  return (
    <div className="pb-52">
      <div className="flex items-start justify-between gap-3">
        <div>
          <Label>Lote de barra</Label>
          <div className="font-display text-2xl font-extrabold">{t.lote?.cafe}</div>
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <span className="font-mono">{t.lote?.codigo}</span><Badge status={t.lote?.estado} /><span>{roastedLabel(t.lote?.tostado_el)}</span>
          </div>
        </div>
        <div className="text-right">
          <div className={cx('num font-display text-3xl font-extrabold', t.lote?.barra_g < 300 && 'text-[#b5432f]')}>{grams(t.lote?.barra_g)}</div>
          <button className="text-xs underline" onClick={() => setChanging(true)}>Cambiar lote</button>
        </div>
      </div>
      {t.lote?.barra_g < 300 && <Notice tone="warn" className="mt-2">Quedan pocos gramos en este lote. Cambiá el lote antes de que se termine.</Notice>}

      <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3">
        {drinks.map((d) => (
          <button key={d.id} onClick={() => tap(d)}
            className="flex h-24 flex-col items-start justify-between rounded-3xl bg-cafe p-4 text-left text-crema shadow-card active:scale-[.97]">
            <span className="font-display text-lg font-extrabold leading-tight">{d.name}</span>
            <span className="flex w-full justify-between text-xs text-crema/80"><span>{d.coffee_g} g{d.milk_ml > 0 && ` · ${d.milk_ml} ml`}</span><span className="num font-semibold text-ambar">{ars(d.price)}</span></span>
          </button>
        ))}
      </div>

      <Card className="mt-6">
        <div className="flex items-center justify-between">
          <Label>Turno abierto · {fmtTime(t.opened_at)}</Label>
          <Button size="sm" variant="ghost" onClick={() => setClosing(true)}>Cerrar caja</Button>
        </div>
        <div className="mt-2 grid grid-cols-3 gap-2 text-center text-sm">
          <div><div className="num font-display text-xl font-extrabold">{t.ventas.tickets}</div>tickets</div>
          <div><div className="num font-display text-xl font-extrabold">{ars(t.ventas.total)}</div>vendido</div>
          <div><div className="num font-display text-xl font-extrabold">{ars(t.esperado)}</div>efectivo esperado</div>
        </div>
        <ul className="mt-3 max-h-60 divide-y divide-cafe/10 overflow-y-auto text-sm">
          {t.tickets.map((tk) => (
            <li key={tk.id} className="flex justify-between gap-2 py-2"><span>#{tk.numero} · {tk.items}</span><span className="num whitespace-nowrap">{ars(tk.total)} · {METODOS[tk.metodo]}</span></li>
          ))}
        </ul>
      </Card>

      {/* Ticket fijo abajo: tocar bebida + Cobrar = dos toques */}
      <div className="fixed inset-x-0 bottom-16 z-30 px-3 lg:bottom-3 lg:left-64">
        <div className="mx-auto max-w-2xl rounded-3xl bg-noche p-3 text-crema shadow-card">
          {last && !ticket.length && <div className="mb-2 rounded-2xl bg-[#2f5d46] px-3 py-2 text-sm">Ticket #{last.numero} cobrado · {ars(last.total)} · {last.cafe_g} g</div>}
          {cmd.error && <div className="mb-2"><ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); panel.reload() }} onRetry={cobrar} /></div>}
          {ticket.length > 0 && (
            <div className="mb-2 flex gap-2 overflow-x-auto pb-1">
              {items.map((i, idx) => (
                <div key={idx} className="flex shrink-0 items-center gap-1 rounded-full bg-crema/10 py-1 pl-3 pr-1 text-sm">
                  <span>{i.cantidad}× {i.d.name}</span>
                  {i.d.milk_ml > 0 && (
                    <button onClick={() => setTicket(ticket.map((x, j) => (j === idx ? { ...x, almendras: !x.almendras } : x)))}
                      className={cx('rounded-full px-2 py-1 text-xs', i.almendras ? 'bg-ambar text-noche' : 'bg-crema/10')}>almendras</button>
                  )}
                  <button aria-label="Quitar" className="h-7 w-7 rounded-full bg-crema/10" onClick={() => setTicket(ticket.map((x, j) => (j === idx ? { ...x, cantidad: x.cantidad - 1 } : x)).filter((x) => x.cantidad > 0))}>−</button>
                </div>
              ))}
            </div>
          )}
          <div className="flex items-center gap-2">
            <select value={metodo} onChange={(e) => setMetodo(e.target.value)} className="h-14 rounded-2xl bg-crema/10 px-3 text-crema">
              {Object.entries(METODOS).map(([k, v]) => <option key={k} value={k} className="text-noche">{v}</option>)}
            </select>
            <Button variant="accent" size="lg" className="flex-1" busy={cmd.busy} disabled={!ticket.length} onClick={cobrar}>
              {ticket.length ? `Cobrar ${ars(tot.total)}` : 'Tocá una bebida'}
            </Button>
          </div>
        </div>
      </div>

      <CerrarCaja open={closing} onClose={() => setClosing(false)} turno={t} umbral={p.umbral_caja} onDone={() => { setClosing(false); panel.reload() }} />
      <CambiarLote open={changing} onClose={() => setChanging(false)} turno={t} lotes={p.lotes_barra} onDone={() => { setChanging(false); panel.reload() }} />
    </div>
  )
}

function LotPicker({ lotes, value, onChange }) {
  return (
    <div className="space-y-2">
      {lotes.map((l) => {
        const disabled = l.estado === 'En reposo' || l.barra_g <= 0
        return (
          <button key={l.id} type="button" disabled={disabled} onClick={() => onChange(l.id)}
            className={cx('flex w-full items-center justify-between rounded-2xl border p-3 text-left', value === l.id ? 'border-cafe bg-cafe/5' : 'border-cafe/15 bg-white', disabled && 'opacity-60')}>
            <div><div className="font-medium">{l.cafe}</div><div className="text-xs"><span className="font-mono">{l.codigo}</span> · {roastedLabel(l.tostado_el)}</div>
              {l.estado === 'En reposo' && <div className="text-xs text-canela">En reposo hasta {untilLabel(l.reposo_hasta)}</div>}</div>
            <div className="text-right"><Badge status={l.estado} /><div className="num mt-1 text-sm">{grams(l.barra_g)}</div></div>
          </button>
        )
      })}
    </div>
  )
}

function AbrirTurno({ panel, onDone }) {
  const [lote, setLote] = useState('')
  const [cash, setCash] = useState('20000')
  const cmd = useCommand()
  return (
    <div className="mx-auto max-w-lg space-y-4">
      <H1>Abrir caja</H1>
      <p className="text-sm">Elegí el lote que va a usar la barra en este turno. Los lotes en «Solo barra» se usan acá primero.</p>
      <LotPicker lotes={panel.lotes_barra} value={lote} onChange={setLote} />
      <Field label="Efectivo inicial"><Input inputMode="numeric" value={cash} onChange={(e) => setCash(e.target.value.replace(/\D/g, ''))} /></Field>
      <ErrorBanner error={cmd.error} onRefresh={onDone} />
      <Button size="lg" className="w-full" busy={cmd.busy} disabled={!lote}
        onClick={async () => { const r = await cmd.run('abrir_turno', { lote_id: lote, efectivo_inicial: Number(cash || 0) }); if (r?.ok) onDone() }}>Abrir caja</Button>
    </div>
  )
}

function CambiarLote({ open, onClose, turno, lotes, onDone }) {
  const [lote, setLote] = useState('')
  const cmd = useCommand()
  return (
    <Sheet open={open} onClose={onClose} title="Cambiar lote de barra">
      <LotPicker lotes={lotes.filter((l) => l.id !== turno.lot_id)} value={lote} onChange={setLote} />
      <ErrorBanner error={cmd.error} onRefresh={onDone} />
      <Button className="mt-4 w-full" size="lg" busy={cmd.busy} disabled={!lote}
        onClick={async () => { const r = await cmd.run('cambiar_lote_turno', { turno_id: turno.id, lote_id: lote }, turno.revision); if (r?.ok) onDone() }}>Usar este lote</Button>
    </Sheet>
  )
}

function CerrarCaja({ open, onClose, turno, umbral, onDone }) {
  const [contado, setContado] = useState('')
  const [motivo, setMotivo] = useState('')
  const cmd = useCommand()
  const c = contado === '' ? null : cashClose(turno.esperado, Number(contado), { cashDiffThreshold: umbral })
  return (
    <Sheet open={open} onClose={onClose} title="Cierre de caja">
      <div className="grid grid-cols-2 gap-3">
        <Card><Label>Esperado</Label><div className="num font-display text-2xl font-extrabold">{ars(turno.esperado)}</div><div className="text-xs">inicial + efectivo cobrado</div></Card>
        <Card><Label>Diferencia</Label><div className={cx('num font-display text-2xl font-extrabold', c?.needsReason && 'text-[#b5432f]')}>{c ? ars(c.diff) : '—'}</div></Card>
      </div>
      <div className="mt-4 space-y-3">
        <Field label="Efectivo contado"><Input inputMode="numeric" autoFocus value={contado} onChange={(e) => setContado(e.target.value.replace(/[^\d]/g, ''))} /></Field>
        {c?.needsReason && <Field label="Motivo de la diferencia" hint={`Supera ${ars(umbral)}: es obligatorio.`}><Textarea value={motivo} onChange={(e) => setMotivo(e.target.value)} /></Field>}
        <ErrorBanner error={cmd.error} onRefresh={onDone} />
        <Button size="lg" className="w-full" busy={cmd.busy} disabled={contado === '' || (c?.needsReason && motivo.trim().length < 3)}
          onClick={async () => { const r = await cmd.run('cerrar_caja', { turno_id: turno.id, contado: Number(contado), motivo }, turno.revision); if (r?.ok) onDone() }}>Cerrar caja</Button>
      </div>
    </Sheet>
  )
}
