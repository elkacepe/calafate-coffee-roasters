import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, grams, fmtDateTime } from '../../lib/format'
import { Badge, Button, Card, ErrorBanner, H1, H2, Input, Label, Loading, LoadError, Notice, Sheet, Textarea, Empty } from '../../components/ui'
import { useAuth } from '../../auth/AuthProvider'

const ENT = { cierre_caja: 'Cierre de caja', lote: 'Lote', cuenta: 'Cuenta corriente' }

export default function Caja() {
  const { profile } = useAuth()
  const closures = useAsync(async () => (await supabase.from('cash_closures').select('*, cash_adjustments(amount, reason, created_at)').order('closed_at', { ascending: false }).limit(30)).data, [])
  const props = useAsync(async () => {
    const [p, names] = await Promise.all([
      supabase.from('change_proposals').select('*').order('created_at', { ascending: false }),
      supabase.from('profiles').select('id, full_name'),
    ])
    const n = Object.fromEntries((names.data || []).map((x) => [x.id, x.full_name]))
    return (p.data || []).map((x) => ({ ...x, creador: n[x.created_by], decisor: n[x.decided_by] }))
  }, [])
  const cmd = useCommand()
  const [prop, setProp] = useState(null)
  const [nota, setNota] = useState('')
  const [ajuste, setAjuste] = useState(null)

  async function decidir(p, decision) {
    const r = await cmd.run('decidir_propuesta', { propuesta_id: p.id, decision, nota }, p.revision)
    if (r?.ok) { setNota(''); props.reload(); closures.reload() }
  }
  return (
    <div className="space-y-5">
      <H1>Caja y propuestas</H1>
      <ErrorBanner error={cmd.error} onRefresh={() => { cmd.clearError(); props.reload(); closures.reload() }} />
      <section className="space-y-2">
        <H2>Propuestas de corrección</H2>
        <p className="text-sm text-cafe/70">Una corrección nunca reescribe el antecedente: si se aprueba crea un ajuste vinculado. La revisa una persona distinta de quien la propuso.</p>
        {props.loading && <Loading />}
        {props.data?.length === 0 && <Empty title="Sin propuestas" />}
        {props.data?.map((p) => (
          <Card key={p.id}>
            <div className="flex items-start justify-between gap-2">
              <div><div className="font-medium">{ENT[p.entity]} · {p.changes.monto != null ? ars(p.changes.monto) : grams(p.changes.gramos)}</div>
                <div className="text-xs text-cafe/60">Propuso {p.creador} · {fmtDateTime(p.created_at)} · sobre versión {p.base_revision}</div></div>
              <Badge status={p.status} />
            </div>
            <div className="mt-1 text-sm italic">“{p.reason}”</div>
            {p.decision_note && <div className="mt-1 text-xs">Decidió {p.decisor}: {p.decision_note}</div>}
            {p.status === 'pendiente' && (
              p.created_by === profile?.id ? <div className="mt-2 text-xs text-canela">La creaste vos: la tiene que revisar otra persona.</div> : (
                <div className="mt-2 space-y-2">
                  <Textarea placeholder="Nota de la decisión" value={prop === p.id ? nota : ''} onFocus={() => setProp(p.id)} onChange={(e) => { setProp(p.id); setNota(e.target.value) }} />
                  <div className="grid grid-cols-2 gap-2">
                    <Button variant="ghost" busy={cmd.busy} onClick={() => decidir(p, 'rechazar')}>Rechazar</Button>
                    <Button busy={cmd.busy} onClick={() => decidir(p, 'aprobar')}>Aprobar</Button>
                  </div>
                </div>
              )
            )}
          </Card>
        ))}
      </section>
      <section className="space-y-2">
        <H2>Cierres de caja</H2>
        {closures.error && <LoadError error={closures.error} onRetry={closures.reload} />}
        {closures.data?.map((c) => {
          const adj = (c.cash_adjustments || []).reduce((a, x) => a + x.amount, 0)
          return (
            <Card key={c.id}>
              <div className="flex items-center justify-between"><Label>{fmtDateTime(c.closed_at)}</Label><span className="text-xs">v{c.revision}</span></div>
              <div className="mt-1 grid grid-cols-3 gap-2 text-sm">
                <div>Esperado<div className="num font-semibold">{ars(c.expected_cash)}</div></div>
                <div>Contado<div className="num font-semibold">{ars(c.counted_cash)}</div></div>
                <div>Diferencia<div className={`num font-semibold ${Math.abs(c.difference) > 2000 ? 'text-[#b5432f]' : ''}`}>{ars(c.difference)}</div></div>
              </div>
              {c.reason && <div className="mt-1 text-xs italic">Motivo: {c.reason}</div>}
              {adj !== 0 && <div className="mt-1 text-xs">Ajustes aprobados {ars(adj)} → diferencia final {ars(c.difference + adj)}</div>}
              <Button size="sm" variant="ghost" className="mt-2" onClick={() => setAjuste({ c, monto: '', motivo: '' })}>Proponer ajuste</Button>
            </Card>
          )
        })}
      </section>
      <Sheet open={!!ajuste} onClose={() => setAjuste(null)} title="Ajuste de cierre">
        {ajuste && (
          <div className="space-y-3">
            <Input inputMode="numeric" placeholder="Monto (+ o −)" value={ajuste.monto} onChange={(e) => setAjuste({ ...ajuste, monto: e.target.value.replace(/[^\d-]/g, '') })} />
            <Textarea placeholder="Motivo" value={ajuste.motivo} onChange={(e) => setAjuste({ ...ajuste, motivo: e.target.value })} />
            <Notice tone="info">El cierre original queda igual; si se aprueba, se agrega un ajuste vinculado.</Notice>
            <Button className="w-full" busy={cmd.busy} disabled={!Number(ajuste.monto) || ajuste.motivo.trim().length < 5}
              onClick={async () => { const r = await cmd.run('proponer_cambio', { entidad: 'cierre_caja', entidad_id: ajuste.c.id, cambios: { monto: Number(ajuste.monto) }, motivo: ajuste.motivo }, ajuste.c.revision); if (r?.ok) { setAjuste(null); props.reload() } }}>Enviar propuesta</Button>
          </div>
        )}
      </Sheet>
    </div>
  )
}
