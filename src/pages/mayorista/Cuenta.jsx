import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { ars, fmtDate, fmtDay } from '../../lib/format'
import { Card, H1, Label, Loading, LoadError, Notice, Stat } from '../../components/ui'

const KIND = { cargo: 'Pedido entregado', pago: 'Pago', nota_credito: 'Nota de crédito', ajuste: 'Ajuste' }

export default function Cuenta() {
  const credit = useAsync(() => rpc('credit_status', { p_customer: null }), [])
  const movs = useAsync(async () => {
    const { data, error } = await supabase.from('account_movements').select('id, kind, amount, due_date, created_at, reference, order_id, orders(number)').order('created_at', { ascending: true })
    if (error) throw error
    let run = 0
    return data.map((m) => ({ ...m, saldo: (run += m.amount) })).reverse()
  }, [])
  const c = credit.data
  return (
    <div className="space-y-4">
      <H1>Tu cuenta corriente</H1>
      {credit.loading && <Loading />}
      {credit.error && <LoadError error={credit.error} onRetry={credit.reload} />}
      {c && (
        <>
          {c.bloqueado && <Notice tone="dark">{c.mensaje}</Notice>}
          <div className="grid grid-cols-2 gap-3">
            <Stat label="Saldo" value={ars(c.saldo)} />
            <Stat label="Vencido" value={c.vencido > 0 ? ars(c.vencido) : null} hint={c.dias_vencido > 0 ? `hace ${c.dias_vencido} días` : 'Nada vencido'} />
            <Stat label="Límite" value={ars(c.limite)} />
            <Stat label="Pedidos en curso" value={ars(c.comprometido)} />
          </div>
          <Notice tone="info">Pagás a 15 días desde cada entrega. Con deuda vencida de más de 15 días o el límite superado no se pueden confirmar pedidos y el recurrente queda retenido.</Notice>
        </>
      )}
      <Card>
        <Label>Movimientos</Label>
        {movs.data?.length === 0 && <div className="py-4 text-sm text-cafe/60">Sin movimientos todavía.</div>}
        <ul className="mt-2 divide-y divide-cafe/10">
          {movs.data?.map((m) => (
            <li key={m.id} className="flex justify-between gap-3 py-2 text-sm">
              <div>
                <div className="font-medium">{KIND[m.kind]}{m.orders?.number && ` #${m.orders.number}`}</div>
                <div className="text-xs text-cafe/60">{fmtDate(m.created_at)}{m.due_date && ` · vence ${fmtDay(m.due_date)}`}{m.reference && ` · ${m.reference}`}</div>
              </div>
              <div className="text-right">
                <div className={`num ${m.amount < 0 ? 'text-[#2f5d46]' : ''}`}>{m.amount < 0 ? '−' : '+'}{ars(Math.abs(m.amount))}</div>
                <div className="num text-xs text-cafe/60">saldo {ars(m.saldo)}</div>
              </div>
            </li>
          ))}
        </ul>
      </Card>
    </div>
  )
}
