import { useState } from 'react'
import { Link } from 'react-router-dom'
import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, fmtDate, fmtDay } from '../../lib/format'
import { waLink } from '../../lib/whatsapp'
import { Badge, Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, LoadError, Notice, Select, Sheet, Textarea, cx } from '../../components/ui'

const KIND = { cargo: 'Pedido entregado', pago: 'Pago', nota_credito: 'Nota de crédito', ajuste: 'Ajuste' }

export default function Cuentas() {
  const debtors = useAsync(() => rpc('report_debtors'), [])
  const [sel, setSel] = useState(null)
  return (
    <div className="space-y-4">
      <H1>Cuentas corrientes</H1>
      <p className="text-sm text-cafe/70">Pago a 15 días. Con deuda vencida de más de 15 días o el límite superado, el mayorista no confirma pedidos y su recurrente queda retenido.</p>
      {debtors.loading && <Loading />}
      {debtors.error && <LoadError error={debtors.error} onRetry={debtors.reload} />}
      <div className="grid gap-3 sm:grid-cols-2">
        {debtors.data?.map((d) => (
          <button key={d.cliente_id} className="text-left" onClick={() => setSel(d)}>
            <Card className={cx(d.credito.bloqueado && 'ring-2 ring-noche')}>
              <div className="flex items-start justify-between gap-2">
                <div><div className="font-display text-lg font-extrabold leading-tight">{d.cliente}</div><div className="text-xs text-cafe/60">{d.lista} · límite {ars(d.credito.limite)}</div></div>
                {d.credito.bloqueado ? <Badge status="Retenido">Bloqueado</Badge> : d.credito.saldo > 0 ? <Badge status="Listo">Debe</Badge> : <Badge status="Entregado">Al día</Badge>}
              </div>
              <div className="mt-3 flex items-end justify-between">
                <div><Label>Saldo</Label><div className="num font-display text-3xl font-extrabold">{ars(d.credito.saldo)}</div></div>
                <div className="text-right text-xs">{d.credito.vencido > 0 ? <span className="font-semibold text-[#b5432f]">{ars(d.credito.vencido)} vencidos · {d.credito.dias_vencido} días</span> : 'Nada vencido'}{d.retenidos > 0 && <div className="font-semibold">{d.retenidos} pedido(s) retenido(s)</div>}</div>
              </div>
            </Card>
          </button>
        ))}
      </div>
      <Detalle d={sel} onClose={() => setSel(null)} onChanged={() => debtors.reload().then(() => {})} />
    </div>
  )
}

function Detalle({ d, onClose, onChanged }) {
  const movs = useAsync(async () => {
    if (!d) return []
    const { data, error } = await supabase.from('account_movements').select('id, kind, amount, due_date, created_at, reference, method, orders(number)').eq('customer_id', d.cliente_id).order('created_at')
    if (error) throw error
    let s = 0
    return data.map((m) => ({ ...m, saldo: (s += m.amount) })).reverse()
  }, [d?.cliente_id])
  const retenidos = useAsync(async () => (d ? (await supabase.from('orders').select('id, number, revision, total').eq('customer_id', d.cliente_id).eq('status', 'Retenido')).data : []), [d?.cliente_id])
  const cmd = useCommand()
  const [pago, setPago] = useState({ monto: '', metodo: 'transferencia', referencia: '' })
  const [ajuste, setAjuste] = useState({ monto: '', motivo: '' })
  const [ok, setOk] = useState(null)
  if (!d) return null
  const c = d.credito
  const texto = `Hola ${d.cliente}: tu cuenta en Calafate Coffee Roasters tiene un saldo de ${ars(c.saldo)}${c.vencido > 0 ? `, con ${ars(c.vencido)} vencidos hace ${c.dias_vencido} días` : ''}. ¡Gracias!`
  return (
    <Sheet open onClose={() => { setOk(null); onClose() }} title={d.cliente}>
      <div className="space-y-4 text-sm">
        {c.bloqueado && <Notice tone="dark">{c.mensaje}</Notice>}
        <div className="grid grid-cols-2 gap-2">
          <Card><Label>Saldo</Label><div className="num font-display text-2xl font-extrabold">{ars(c.saldo)}</div></Card>
          <Card><Label>En curso</Label><div className="num font-display text-2xl font-extrabold">{ars(c.comprometido)}</div></Card>
        </div>
        <a href={waLink(texto, d.telefono)} target="_blank" rel="noreferrer"><Button variant="whatsapp" className="w-full">Recordar saldo por WhatsApp</Button></a>
        <div className="space-y-2 rounded-2xl border border-cafe/10 p-3">
          <Label>Registrar pago</Label>
          <div className="grid grid-cols-2 gap-2">
            <Input inputMode="numeric" placeholder="Monto" value={pago.monto} onChange={(e) => setPago({ ...pago, monto: e.target.value.replace(/\D/g, '') })} />
            <Select value={pago.metodo} onChange={(e) => setPago({ ...pago, metodo: e.target.value })}><option value="transferencia">Transferencia</option><option value="efectivo">Efectivo</option><option value="cheque">Cheque</option><option value="qr">QR</option></Select>
          </div>
          <Input placeholder="Referencia (opcional)" value={pago.referencia} onChange={(e) => setPago({ ...pago, referencia: e.target.value })} />
          <Button className="w-full" busy={cmd.busy} disabled={!Number(pago.monto)}
            onClick={async () => { const r = await cmd.run('registrar_pago', { cliente_id: d.cliente_id, monto: Number(pago.monto), metodo: pago.metodo, referencia: pago.referencia }); if (r?.ok) { setOk(`Pago registrado. Saldo: ${ars(r.saldo)}.`); setPago({ monto: '', metodo: 'transferencia', referencia: '' }); movs.reload(); retenidos.reload(); onChanged() } }}>
            Registrar pago
          </Button>
          {c.saldo > 0 && <button className="text-xs underline" onClick={() => setPago({ ...pago, monto: String(c.vencido > 0 ? c.vencido : c.saldo) })}>Completar con {c.vencido > 0 ? 'lo vencido' : 'el saldo'}</button>}
        </div>
        {ok && <Notice tone="ok">{ok}</Notice>}
        <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); movs.reload(); onChanged() }} />
        {retenidos.data?.length > 0 && (
          <div className="space-y-2 rounded-2xl bg-noche p-3 text-crema">
            <Label className="text-ambar">Pedidos retenidos</Label>
            {retenidos.data.map((o) => (
              <div key={o.id} className="flex items-center justify-between gap-2">
                <span>#{o.number}</span>
                <Button size="sm" variant="accent" busy={cmd.busy} onClick={async () => { const r = await cmd.run('liberar_retenido', { pedido_id: o.id }, o.revision); if (r?.ok) { setOk(`Pedido #${o.number} liberado y reservado.`); retenidos.reload(); onChanged() } }}>Liberar y reservar</Button>
              </div>
            ))}
          </div>
        )}
        <div className="space-y-2 rounded-2xl border border-cafe/10 p-3">
          <Label>Proponer ajuste</Label>
          <p className="text-xs">Las correcciones no reescriben movimientos: crean una propuesta que aprueba otra persona y queda un ajuste vinculado.</p>
          <Input inputMode="numeric" placeholder="Monto (+ suma deuda, − la baja)" value={ajuste.monto} onChange={(e) => setAjuste({ ...ajuste, monto: e.target.value.replace(/[^\d-]/g, '') })} />
          <Textarea placeholder="Motivo" value={ajuste.motivo} onChange={(e) => setAjuste({ ...ajuste, motivo: e.target.value })} />
          <Button variant="ghost" className="w-full" busy={cmd.busy} disabled={!Number(ajuste.monto) || ajuste.motivo.trim().length < 5}
            onClick={async () => { const r = await cmd.run('proponer_cambio', { entidad: 'cuenta', entidad_id: d.cliente_id, cambios: { monto: Number(ajuste.monto) }, motivo: ajuste.motivo }, d.revision); if (r?.ok) { setOk('Propuesta enviada. La aprueba otra persona en Caja y propuestas.'); setAjuste({ monto: '', motivo: '' }) } }}>
            Enviar propuesta
          </Button>
        </div>
        <div>
          <Label>Movimientos</Label>
          {movs.loading && <Loading />}
          <ul className="mt-2 divide-y divide-cafe/10">
            {movs.data?.map((m) => (
              <li key={m.id} className="flex justify-between gap-2 py-2">
                <div><div>{KIND[m.kind]}{m.orders?.number && ` #${m.orders.number}`}</div><div className="text-xs text-cafe/60">{fmtDate(m.created_at)}{m.due_date && ` · vence ${fmtDay(m.due_date)}`}{m.reference && ` · ${m.reference}`}</div></div>
                <div className="text-right"><div className="num">{m.amount < 0 ? '−' : '+'}{ars(Math.abs(m.amount))}</div><div className="num text-xs text-cafe/60">{ars(m.saldo)}</div></div>
              </li>
            ))}
          </ul>
          <div className="mt-2 text-xs text-cafe/60">El saldo es la suma de estos movimientos; no hay un contador aparte.</div>
        </div>
      </div>
    </Sheet>
  )
}
