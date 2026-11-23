import { useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { priceOn } from '../../domain/rules'
import { ars, fmtDay, localDate, PRESENTACION } from '../../lib/format'
import { Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, Notice, Select, Sheet, cx } from '../../components/ui'

export default function Precios() {
  const data = useAsync(async () => {
    const [l, c, p] = await Promise.all([
      supabase.from('price_lists').select('*').order('name'),
      supabase.from('coffees').select('id, name').order('sort'),
      supabase.from('price_items').select('*').order('valid_from'),
    ])
    return { lists: l.data || [], coffees: c.data || [], items: p.data || [] }
  }, [])
  const [list, setList] = useState(null)
  const [edit, setEdit] = useState(null)
  const cmd = useCommand()
  const today = localDate()
  const d = data.data
  const current = list || d?.lists[0]?.id
  const pres = d?.lists.find((l) => l.id === current)?.kind === 'publico' ? ['bolsa_250', 'bolsa_1000'] : ['kg_grano', 'kg_molido']
  const rows = useMemo(() => d ? d.coffees.map((c) => ({ c, cells: pres.map((p) => {
    const versions = d.items.filter((i) => i.list_id === current && i.coffee_id === c.id && i.presentation === p)
    return { p, now: priceOn(versions, today), next: versions.find((v) => v.valid_from > today) }
  }) })) : [], [d, current, today]) // eslint-disable-line
  if (!d) return <Loading />
  return (
    <div className="space-y-4">
      <H1>Precios</H1>
      <Notice tone="info">Cada cambio se carga como una versión con vigencia desde una fecha (hoy o futura). El precio de cada línea se congela al confirmar el pedido: un cambio futuro no toca pedidos ya confirmados.</Notice>
      <div className="flex gap-2 overflow-x-auto">
        {d.lists.map((l) => <button key={l.id} onClick={() => setList(l.id)} className={cx('shrink-0 rounded-full border px-4 py-2 text-sm', current === l.id ? 'border-cafe bg-cafe text-crema' : 'border-cafe/20 bg-white')}>{l.name}{l.credit_limit ? ` · límite ${ars(l.credit_limit)}` : ''}</button>)}
      </div>
      <div className="space-y-2">
        {rows.map(({ c, cells }) => (
          <Card key={c.id}>
            <div className="font-medium">{c.name}</div>
            <div className="mt-2 grid grid-cols-2 gap-2">
              {cells.map((x) => (
                <button key={x.p} onClick={() => setEdit({ cafe: c, presentacion: x.p, precio: '', vigente_desde: today })} className="rounded-2xl bg-white p-3 text-left">
                  <Label>{PRESENTACION[x.p]}</Label>
                  <div className="num font-display text-xl font-extrabold">{ars(x.now)}</div>
                  {x.next && <div className="text-xs text-canela">{ars(x.next.price)} desde {fmtDay(x.next.valid_from)}</div>}
                </button>
              ))}
            </div>
          </Card>
        ))}
      </div>
      <Sheet open={!!edit} onClose={() => setEdit(null)} title="Nuevo precio">
        {edit && (
          <div className="space-y-3">
            <div className="text-sm">{edit.cafe.name} · {PRESENTACION[edit.presentacion]}</div>
            <Field label="Precio"><Input inputMode="numeric" value={edit.precio} onChange={(e) => setEdit({ ...edit, precio: e.target.value.replace(/\D/g, '') })} /></Field>
            <Field label="Vigente desde"><Input type="date" min={today} value={edit.vigente_desde} onChange={(e) => setEdit({ ...edit, vigente_desde: e.target.value })} /></Field>
            <ErrorBanner error={cmd.error} onRefresh={data.reload} />
            <Button className="w-full" size="lg" busy={cmd.busy} disabled={!Number(edit.precio)}
              onClick={async () => { const r = await cmd.run('actualizar_precio', { lista_id: current, cafe_id: edit.cafe.id, presentacion: edit.presentacion, precio: Number(edit.precio), vigente_desde: edit.vigente_desde }); if (r?.ok) { setEdit(null); data.reload() } }}>Programar precio</Button>
          </div>
        )}
      </Sheet>
    </div>
  )
}
