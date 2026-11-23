import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { ars, kg, roastedLabel } from '../../lib/format'
import { Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, LoadError, Sheet } from '../../components/ui'

export default function Verde() {
  const g = useAsync(() => rpc('green_panel'), [])
  const [sel, setSel] = useState(null)
  const [f, setF] = useState({ kg: '', costo: '' })
  const cmd = useCommand()
  return (
    <div className="space-y-4">
      <H1>Café verde</H1>
      {g.loading && <Loading />}
      {g.error && <LoadError error={g.error} onRetry={g.reload} />}
      <div className="grid gap-3 sm:grid-cols-2">
        {g.data?.map((x) => (
          <Card key={x.id}>
            <Label>{x.pais} · {x.proceso}</Label>
            <div className="font-display text-xl font-extrabold">{x.nombre}</div>
            <div className="mt-2 flex items-end justify-between">
              <div className="num font-display text-5xl font-extrabold">{kg(x.stock_g)}<span className="ml-1 font-body text-base font-normal">kg</span></div>
              <div className="text-right text-xs">{ars(x.costo_kg)}/kg<div>{x.ultimo_tueste ? roastedLabel(x.ultimo_tueste, 'Último tueste') : 'Sin tuestes'}</div></div>
            </div>
            <Button variant="ghost" size="sm" className="mt-3" onClick={() => { setSel(x); setF({ kg: '', costo: String(x.costo_kg) }) }}>Registrar ingreso</Button>
          </Card>
        ))}
      </div>
      <Sheet open={!!sel} onClose={() => setSel(null)} title={`Ingreso · ${sel?.nombre}`}>
        <div className="space-y-3">
          <Field label="Kilos que entraron"><Input inputMode="decimal" value={f.kg} onChange={(e) => setF({ ...f, kg: e.target.value })} /></Field>
          <Field label="Costo por kg" hint="Actualiza el costo para los próximos tuestes; los lotes ya tostados conservan el suyo."><Input inputMode="numeric" value={f.costo} onChange={(e) => setF({ ...f, costo: e.target.value.replace(/\D/g, '') })} /></Field>
          <ErrorBanner error={cmd.error} onRefresh={g.reload} />
          <Button size="lg" className="w-full" busy={cmd.busy} disabled={!Number(f.kg.replace(',', '.'))}
            onClick={async () => { const r = await cmd.run('ingresar_verde', { verde_id: sel.id, gramos: Math.round(Number(f.kg.replace(',', '.')) * 1000), costo_kg: Number(f.costo) || null }); if (r?.ok) { setSel(null); g.reload() } }}>Guardar ingreso</Button>
        </div>
      </Sheet>
    </div>
  )
}
