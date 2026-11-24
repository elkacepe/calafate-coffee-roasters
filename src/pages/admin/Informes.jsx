import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { ars, grams, pctFmt, fmtDate, localDate } from '../../lib/format'
import { toCSV, downloadCSV } from '../../lib/csv'
import { DateInput, Button, Card, H1, H2, Input, Label, Loading, LoadError, Notice, Stat, cx } from '../../components/ui'

const CANAL = { barra: 'Barra', web: 'Web', mayorista: 'Mayoristas' }

export default function Informes() {
  const today = localDate()
  const [desde, setDesde] = useState(today.slice(0, 8) + '01')
  const [hasta, setHasta] = useState(today)
  const sales = useAsync(() => rpc('report_sales', { p_from: desde, p_to: hasta }), [desde, hasta])
  const waste = useAsync(() => rpc('report_waste', { p_from: desde, p_to: hasta }), [desde, hasta])
  const debt = useAsync(() => rpc('report_debtors'), [])
  const rec = useAsync(() => rpc('report_reconciliation'), [])
  const s = sales.data
  const csvRows = s?.filas || []
  const csvSum = csvRows.reduce((a, r) => a + r.total, 0)

  function exportCSV() {
    const text = toCSV(csvRows, [
      { label: 'Pedido', key: 'numero' }, { label: 'Fecha', key: 'fecha' }, { label: 'Canal', key: 'canal' }, { label: 'Estado', key: 'estado' },
      { label: 'Cliente', key: 'cliente' }, { label: 'Subtotal', key: 'subtotal' }, { label: 'Envío', key: 'envio' }, { label: 'Total', key: 'total' }, { label: 'Costo histórico', key: 'costo' },
    ])
    downloadCSV(`ventas_${desde}_${hasta}.csv`, text)
  }
  return (
    <div className="space-y-5">
      <H1>Informes</H1>
      <div className="grid grid-cols-1 gap-2 sm:w-[32rem] sm:grid-cols-2">
        <DateInput label="Desde" value={desde} max={hasta} onChange={(e) => setDesde(e.target.value)} />
        <DateInput label="Hasta" value={hasta} min={desde} onChange={(e) => setHasta(e.target.value)} />
      </div>

      <section className="space-y-2">
        <div className="flex items-center justify-between"><H2>Ventas por canal</H2>{s && <Button size="sm" variant="ghost" onClick={exportCSV} disabled={!csvRows.length}>Descargar CSV ({csvRows.length})</Button>}</div>
        <p className="text-xs text-cafe/60">Pedidos no anulados (sin borradores, retenidos ni cancelados; sin reposiciones), por fecha de confirmación. El CSV trae exactamente estas filas.</p>
        {sales.loading && <Loading />}
        {sales.error && <LoadError error={sales.error} onRetry={sales.reload} />}
        {s && (
          <>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
              {Object.keys(CANAL).map((k) => {
                const c = s.por_canal[k]
                return (
                  <Card key={k}>
                    <Label>{CANAL[k]}</Label>
                    <div className={cx('num font-display font-extrabold', c.total == null ? 'text-xl text-cafe/40' : 'text-3xl')}>{c.total == null ? 'Sin datos' : ars(c.total)}</div>
                    <div className="mt-1 text-xs">{c.pedidos} pedidos · ticket promedio {c.ticket_promedio == null ? 'sin datos' : ars(c.ticket_promedio)}</div>
                    <div className="text-xs">Margen bruto {c.total == null ? 'sin datos' : pctFmt(c.total ? Math.round(((c.total - c.costo) * 10000) / c.total) / 100 : null)}</div>
                  </Card>
                )
              })}
            </div>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Total" value={s.total == null ? null : ars(s.total)} />
              <Stat label="Pedidos" value={s.pedidos || null} />
              <Stat label="Notas de crédito" value={s.notas_credito == null ? null : ars(s.notas_credito)} />
              <Stat label="Reintegros" value={s.reintegros == null ? null : ars(s.reintegros)} />
            </div>
            <Notice tone={csvSum === (s.total || 0) ? 'ok' : 'warn'}>Control: suma de las {csvRows.length} filas del CSV = {ars(csvSum)} · total del informe = {s.total == null ? 'sin datos' : ars(s.total)}{csvSum !== (s.total || 0) && ' → NO COINCIDE'}.</Notice>
          </>
        )}
      </section>

      <section className="space-y-2">
        <H2>Merma</H2>
        {waste.data && (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Stat label="Merma de tueste" value={waste.data.tueste.merma_g == null ? null : grams(waste.data.tueste.merma_g)} hint={`${waste.data.tueste.lotes} lotes`} />
            <Stat label="Merma promedio" value={waste.data.tueste.merma_pct == null ? null : pctFmt(waste.data.tueste.merma_pct)} hint={waste.data.tueste.fuera_de_rango ? `${waste.data.tueste.fuera_de_rango} fuera de rango` : null} />
            <Stat label="Por devoluciones" value={waste.data.devoluciones.gramos == null ? null : grams(waste.data.devoluciones.gramos)} />
            <Stat label="Por ajustes" value={waste.data.ajustes.gramos == null ? null : grams(waste.data.ajustes.gramos)} />
          </div>
        )}
      </section>

      <section className="space-y-2">
        <H2>Qué mayoristas deben</H2>
        {debt.data && (
          <Card>
            <ul className="divide-y divide-cafe/10 text-sm">
              {debt.data.filter((d) => d.credito.saldo !== 0).map((d) => (
                <li key={d.cliente_id} className="flex justify-between py-2"><span>{d.cliente}{d.credito.dias_vencido > 0 && <span className="text-xs text-[#b5432f]"> · vencido {d.credito.dias_vencido} días</span>}</span><span className="num font-medium">{ars(d.credito.saldo)}</span></li>
              ))}
              {debt.data.every((d) => d.credito.saldo === 0) && <li className="py-2 text-cafe/60">Nadie debe.</li>}
            </ul>
          </Card>
        )}
      </section>

      <section className="space-y-2">
        <H2>Conciliación</H2>
        <p className="text-xs text-cafe/60">Reconstruye saldos y stock desde los registros de origen y los compara con lo que muestran las fichas. Si hay diferencia se muestra, no se oculta.</p>
        {rec.data && (
          <div className="grid gap-3 lg:grid-cols-2">
            <Card>
              <Label>Cuentas corrientes</Label>
              <table className="mt-2 w-full text-xs"><thead><tr className="text-left"><th>Cliente</th><th className="text-right">Movimientos</th><th className="text-right">Reconstruido</th><th className="text-right">Dif.</th></tr></thead>
                <tbody>{rec.data.cuentas.map((c) => <tr key={c.cliente} className={c.diferencia !== 0 ? 'font-semibold text-[#b5432f]' : ''}><td>{c.cliente}</td><td className="num text-right">{ars(c.saldo_movimientos)}</td><td className="num text-right">{ars(c.saldo_reconstruido)}</td><td className="num text-right">{ars(c.diferencia)}</td></tr>)}</tbody></table>
            </Card>
            <Card>
              <Label>Lotes (gramos en mano)</Label>
              <table className="mt-2 w-full text-xs"><thead><tr className="text-left"><th>Lote</th><th className="text-right">Movimientos</th><th className="text-right">Reconstruido</th></tr></thead>
                <tbody>{rec.data.lotes.map((l) => <tr key={l.codigo} className={l.en_mano_movimientos !== l.en_mano_reconstruido ? 'font-semibold text-[#b5432f]' : ''}><td className="font-mono">{l.codigo}</td><td className="num text-right">{grams(l.en_mano_movimientos)}</td><td className="num text-right">{grams(l.en_mano_reconstruido)}</td></tr>)}</tbody></table>
            </Card>
            <Card className="lg:col-span-2 text-sm">Comandos aplicados {rec.data.comandos.aplicados} · rechazados {rec.data.comandos.rechazados} · rechazados con eventos {rec.data.comandos.rechazados_con_evento} (debe ser 0).</Card>
          </div>
        )}
      </section>
    </div>
  )
}
