import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, grams, fmtDay, localDate, PRESENTACION, CONDICION, METODOS } from '../../lib/format'
import { waLink } from '../../lib/whatsapp'
import { Badge, Button, Card, Empty, ErrorBanner, Field, H1, H2, Input, Label, Loading, LoadError, Notice, Progress, Select, Sheet, Textarea, cx } from '../../components/ui'

export default function Hoy() {
  const [fecha, setFecha] = useState(localDate())
  const board = useAsync(() => rpc('route_board', { p_date: fecha }), [fecha])
  const cmd = useCommand()
  const [stop, setStop] = useState(null)
  return (
    <div className="space-y-4">
      <div className="flex items-end justify-between gap-3">
        <H1>Recorridos</H1>
        <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className="rounded-2xl border border-cafe/15 bg-white px-3 py-2 text-sm" />
      </div>
      <div className="text-sm text-cafe/70">{fmtDay(fecha)}</div>
      {board.loading && <Loading />}
      {board.error && <LoadError error={board.error} onRetry={board.reload} />}
      {board.data?.recorridos.length === 0 && <Empty title="No tenés recorridos este día" />}
      <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); board.reload() }} />
      {board.data?.recorridos.map((r) => (
        <div key={r.id} className="space-y-3">
          <Card className="bg-cafe text-crema">
            <div className="flex items-center justify-between">
              <div><Label className="text-ambar">{r.franja} h</Label><div className="font-display text-2xl font-extrabold">{r.zona}</div></div>
              <Badge status={r.estado} />
            </div>
            <div className="mt-3 flex justify-between text-sm"><span>{grams(r.carga_g)} de {grams(r.capacidad_g)}</span><span>{r.paradas.length} paradas</span></div>
            <Progress value={r.carga_g} max={r.capacidad_g} className="mt-1 bg-crema/20" />
            {r.estado === 'Planificado' && (
              <Button variant="accent" size="lg" className="mt-4 w-full" busy={cmd.busy}
                onClick={async () => { const x = await cmd.run('iniciar_recorrido', { recorrido_id: r.id }, r.revision); if (x?.ok) board.reload() }}>Salir a repartir</Button>
            )}
          </Card>
          {r.paradas.map((s) => (
            <Card key={s.id} className={cx(s.resultado !== 'pendiente' && 'opacity-70')}>
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className="text-xs text-cafe/60">Parada {s.orden} · #{s.numero}{s.reposicion && ' · reposición'}</div>
                  <div className="font-display text-xl font-extrabold leading-tight">{s.nombre}</div>
                  <div className="text-sm">{s.direccion}</div>
                </div>
                <Badge status={s.resultado === 'pendiente' ? s.estado : s.resultado === 'no_entregado' ? 'Para reprogramar' : 'Entregado'} />
              </div>
              <ul className="mt-2 text-sm">
                {s.lineas?.map((l) => <li key={l.id}>{l.cantidad} × {l.cafe} <span className="text-cafe/60">· {PRESENTACION[l.presentacion]} · {l.molienda}</span></li>)}
              </ul>
              <div className="mt-1 text-xs text-cafe/70">{grams(s.gramos)}{s.cobrar && <> · <b>Cobrar {ars(s.total)}</b></>}{s.intentos_fallidos > 0 && ` · ${s.intentos_fallidos} intento(s) fallido(s)`}</div>
              {s.nota && <div className="mt-1 text-xs italic">“{s.nota}”</div>}
              <div className="mt-3 grid grid-cols-2 gap-2">
                <a href={`tel:${s.telefono}`}><Button variant="ghost" size="sm" className="w-full">Llamar</Button></a>
                <a href={waLink(`Hola, soy el repartidor de Calafate Coffee Roasters: estoy llegando con tu pedido #${s.numero}.`, s.telefono)} target="_blank" rel="noreferrer">
                  <Button variant="whatsapp" size="sm" className="w-full">Avisar llegada</Button>
                </a>
              </div>
              {r.estado === 'En curso' && s.resultado === 'pendiente' && (
                <div className="mt-2 grid grid-cols-2 gap-2">
                  <Button size="lg" onClick={() => setStop({ ...s, modo: 'entregado' })}>Entregado</Button>
                  <Button size="lg" variant="danger" onClick={() => setStop({ ...s, modo: 'no_entregado' })}>No entregado</Button>
                </div>
              )}
            </Card>
          ))}
        </div>
      ))}
      <EntregaSheet stop={stop} onClose={() => setStop(null)} onDone={() => { setStop(null); board.reload() }} />
    </div>
  )
}

function EntregaSheet({ stop, onClose, onDone }) {
  const cmd = useCommand()
  const [nota, setNota] = useState('')
  const [metodo, setMetodo] = useState('efectivo')
  const [rechazo, setRechazo] = useState(null)
  if (!stop) return null
  const entregado = stop.modo === 'entregado'
  async function send() {
    const payload = entregado
      ? { parada_id: stop.id, resultado: 'entregado', nota, cobro: stop.cobrar ? { metodo } : null, rechazos: rechazo ? [rechazo] : [] }
      : { parada_id: stop.id, resultado: 'no_entregado', nota }
    const r = await cmd.run('registrar_entrega', payload, stop.revision)
    if (r?.ok) { setNota(''); setRechazo(null); onDone() }
  }
  return (
    <Sheet open onClose={onClose} title={entregado ? `Entregar #${stop.numero}` : `No entregado #${stop.numero}`}>
      <div className="space-y-3">
        {entregado && stop.cobrar && (
          <Field label={`Cobro ${ars(stop.total)}`}><Select value={metodo} onChange={(e) => setMetodo(e.target.value)}>{Object.entries(METODOS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        )}
        {entregado && (
          <div className="rounded-2xl border border-cafe/10 p-3">
            {!rechazo ? (
              <button className="text-sm underline" onClick={() => setRechazo({ linea_id: stop.lineas[0].id, bolsas: 1, condicion: 'mal_sellada', motivo: '' })}>El cliente rechazó una bolsa</button>
            ) : (
              <div className="space-y-2">
                <Label>Bolsa rechazada en la puerta</Label>
                <Select value={rechazo.linea_id} onChange={(e) => setRechazo({ ...rechazo, linea_id: e.target.value })}>
                  {stop.lineas.map((l) => <option key={l.id} value={l.id}>{l.cafe} · {PRESENTACION[l.presentacion]}</option>)}
                </Select>
                <div className="grid grid-cols-2 gap-2">
                  <Input type="number" min={1} value={rechazo.bolsas} onChange={(e) => setRechazo({ ...rechazo, bolsas: Number(e.target.value) })} />
                  <Select value={rechazo.condicion} onChange={(e) => setRechazo({ ...rechazo, condicion: e.target.value })}>{Object.entries(CONDICION).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
                </div>
                <Input placeholder="Qué pasó" value={rechazo.motivo} onChange={(e) => setRechazo({ ...rechazo, motivo: e.target.value })} />
                <button className="text-xs underline" onClick={() => setRechazo(null)}>Quitar rechazo</button>
                <Notice tone="info">Queda como reclamo para administración: decide merma, reposición o nota de crédito.</Notice>
              </div>
            )}
          </div>
        )}
        <Field label={entregado ? 'Nota (opcional)' : '¿Qué pasó?'}><Textarea value={nota} onChange={(e) => setNota(e.target.value)} placeholder={entregado ? '' : 'No había nadie, portón cerrado…'} /></Field>
        {!entregado && <Notice tone="warn">El pedido vuelve a «Para reprogramar» y su café sigue reservado.</Notice>}
        <ErrorBanner error={cmd.error} onRefresh={onDone} onRetry={send} />
        <Button size="xl" className="w-full" variant={entregado ? 'primary' : 'danger'} busy={cmd.busy}
          disabled={(!entregado && nota.trim().length < 3) || (rechazo && rechazo.motivo.trim().length < 3)} onClick={send}>
          {entregado ? (rechazo ? 'Confirmar entrega con rechazo' : 'Confirmar entrega') : 'Registrar no entregado'}
        </Button>
      </div>
    </Sheet>
  )
}
