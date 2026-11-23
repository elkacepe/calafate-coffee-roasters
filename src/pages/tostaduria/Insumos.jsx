import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, LoadError, Sheet, Segmented } from '../../components/ui'

export default function Insumos() {
  const s = useAsync(() => rpc('supply_panel'), [])
  const [sel, setSel] = useState(null)
  const [f, setF] = useState({ tipo: 'ingreso', cantidad: '', nota: '' })
  const cmd = useCommand()
  const fmt = (x) => (x.unidad === 'ml' ? `${(x.stock / 1000).toLocaleString('es-AR')} l` : `${x.stock} u`)
  return (
    <div className="space-y-4">
      <H1>Insumos</H1>
      {s.loading && <Loading />}
      {s.error && <LoadError error={s.error} onRetry={s.reload} />}
      <div className="grid grid-cols-2 gap-3">
        {s.data?.map((x) => (
          <button key={x.id} className="text-left" onClick={() => { setSel(x); setF({ tipo: 'ingreso', cantidad: '', nota: '' }) }}>
            <Card><Label>{x.nombre}</Label><div className="num font-display text-4xl font-extrabold">{fmt(x)}</div><div className="mt-1 text-xs underline">Registrar movimiento</div></Card>
          </button>
        ))}
      </div>
      <Sheet open={!!sel} onClose={() => setSel(null)} title={sel?.nombre}>
        <div className="space-y-3">
          <Segmented value={f.tipo} onChange={(v) => setF({ ...f, tipo: v })} options={[{ value: 'ingreso', label: 'Ingreso' }, { value: 'ajuste', label: 'Ajuste (−)' }]} />
          <Field label={sel?.unidad === 'ml' ? 'Litros' : 'Unidades'}><Input inputMode="decimal" value={f.cantidad} onChange={(e) => setF({ ...f, cantidad: e.target.value })} /></Field>
          <Field label="Nota"><Input value={f.nota} onChange={(e) => setF({ ...f, nota: e.target.value })} /></Field>
          <ErrorBanner error={cmd.error} onRefresh={s.reload} />
          <Button size="lg" className="w-full" busy={cmd.busy} disabled={!Number(f.cantidad.replace(',', '.'))}
            onClick={async () => {
              const n = Number(f.cantidad.replace(',', '.')) * (sel.unidad === 'ml' ? 1000 : 1)
              const r = await cmd.run('ingresar_insumo', { insumo_id: sel.id, cantidad: Math.round(f.tipo === 'ajuste' ? -n : n), nota: f.nota })
              if (r?.ok) { setSel(null); s.reload() }
            }}>Guardar</Button>
        </div>
      </Sheet>
    </div>
  )
}
