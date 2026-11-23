import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, grams, fmtDateTime, CONDICION, RESOLUCION, METODOS } from '../../lib/format'
import { returnDestination } from '../../domain/rules'
import { Badge, Button, Card, Empty, ErrorBanner, Field, H1, Input, Label, Loading, LoadError, Notice, Select, Sheet, Textarea, cx } from '../../components/ui'

export default function Devoluciones() {
  const [filtro, setFiltro] = useState('abiertas')
  const list = useAsync(async () => {
    let q = supabase.from('returns').select('*, orders!returns_order_id_fkey(number, channel, retail_name), wholesale_customers(name)').order('requested_at', { ascending: false })
    if (filtro === 'abiertas') q = q.in('status', ['Pedida', 'En revisión', 'Aceptada'])
    const { data, error } = await q
    if (error) throw error
    return data
  }, [filtro])
  const [sel, setSel] = useState(null)
  return (
    <div className="space-y-4">
      <H1>Devoluciones</H1>
      <div className="flex gap-2">{['abiertas', 'todas'].map((f) => <button key={f} onClick={() => setFiltro(f)} className={cx('rounded-full border px-4 py-2 text-sm capitalize', filtro === f ? 'border-cafe bg-cafe text-crema' : 'border-cafe/20 bg-white')}>{f}</button>)}</div>
      {list.loading && <Loading />}
      {list.error && <LoadError error={list.error} onRetry={list.reload} />}
      {list.data?.length === 0 && <Empty title="Nada por resolver" />}
      {list.data?.map((r) => (
        <button key={r.id} className="block w-full text-left" onClick={() => setSel(r)}>
          <Card className="flex items-center justify-between gap-2">
            <div><div className="font-medium">#{r.number} · pedido #{r.orders?.number} · {r.wholesale_customers?.name || r.orders?.retail_name}</div>
              <div className="text-xs text-cafe/60">{r.bags} bolsa(s) · {grams(r.grams)} · {CONDICION[r.condition]} · {fmtDateTime(r.requested_at)}</div></div>
            <Badge status={r.status} />
          </Card>
        </button>
      ))}
      <Decidir r={sel} onClose={() => setSel(null)} onDone={() => { setSel(null); list.reload() }} />
    </div>
  )
}

function Decidir({ r, onClose, onDone }) {
  const cmd = useCommand()
  const [resol, setResol] = useState('')
  const [nota, setNota] = useState('')
  const [monto, setMonto] = useState('')
  const [metodo, setMetodo] = useState('efectivo')
  if (!r) return null
  const mayorista = r.orders?.channel === 'mayorista'
  const opciones = mayorista ? ['reposicion', 'nota_credito'] : ['reposicion', 'reintegro']
  const destino = returnDestination(r.condition, null)
  const abierta = ['Pedida', 'En revisión'].includes(r.status)
  return (
    <Sheet open onClose={onClose} title={`Devolución #${r.number}`}>
      <div className="space-y-3 text-sm">
        <div className="flex gap-2"><Badge status={r.status} />{r.resolution && <span>{RESOLUCION[r.resolution]}</span>}</div>
        <div><b>{r.wholesale_customers?.name || r.orders?.retail_name}</b> · pedido #{r.orders?.number}</div>
        <div>{r.bags} bolsa(s) · {grams(r.grams)} · <b>{CONDICION[r.condition]}</b></div>
        <div className="italic">“{r.reason}”</div>
        <div>Valor a precio congelado: <b>{ars(r.amount)}</b></div>
        {abierta && <Notice tone={destino === 'merma' ? 'warn' : 'info'}>{destino === 'merma' ? 'Si la aceptás se registra como merma: no vuelve al stock.' : 'Bolsa cerrada: si la aceptás vuelve al mismo lote (si el lote ya está en «Solo barra», vuelve como café de barra).'}</Notice>}
        {r.decision_note && <div className="text-xs">Decisión: {r.decision_note}</div>}
        <ErrorBanner error={cmd.error} onRefresh={onDone} />
        {r.status === 'Pedida' && <Button variant="ghost" className="w-full" busy={cmd.busy} onClick={async () => { const x = await cmd.run('revisar_devolucion', { devolucion_id: r.id }, r.revision); if (x?.ok) onDone() }}>Pasar a revisión</Button>}
        {abierta && (
          <div className="space-y-2 rounded-2xl border border-cafe/10 p-3">
            <Label>Aceptar</Label>
            <Select value={resol} onChange={(e) => setResol(e.target.value)}><option value="">Elegí la salida</option>{opciones.map((o) => <option key={o} value={o}>{RESOLUCION[o]}</option>)}</Select>
            {resol === 'reintegro' && (
              <div className="grid grid-cols-2 gap-2">
                <Input inputMode="numeric" placeholder={String(r.amount)} value={monto} onChange={(e) => setMonto(e.target.value.replace(/\D/g, ''))} />
                <Select value={metodo} onChange={(e) => setMetodo(e.target.value)}>{Object.entries(METODOS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
              </div>
            )}
            <Textarea placeholder="Nota" value={nota} onChange={(e) => setNota(e.target.value)} />
            <Button className="w-full" busy={cmd.busy} disabled={!resol}
              onClick={async () => { const x = await cmd.run('decidir_devolucion', { devolucion_id: r.id, decision: 'aceptar', resolucion: resol, nota, monto_reintegro: monto ? Number(monto) : null, metodo }, r.revision); if (x?.ok) onDone() }}>Aceptar devolución</Button>
            <Button variant="danger" className="w-full" busy={cmd.busy} disabled={nota.trim().length < 3}
              onClick={async () => { const x = await cmd.run('decidir_devolucion', { devolucion_id: r.id, decision: 'rechazar', nota }, r.revision); if (x?.ok) onDone() }}>Rechazar (con nota)</Button>
          </div>
        )}
        {r.status === 'Aceptada' && r.resolution === 'reposicion' && <Notice tone="info">La reposición está como pedido nuevo: cargala en el próximo recorrido. Al entregarla la devolución queda «Resuelta».</Notice>}
      </div>
    </Sheet>
  )
}
