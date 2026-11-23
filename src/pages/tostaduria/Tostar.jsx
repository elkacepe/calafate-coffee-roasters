import { useState } from 'react'
import { Link } from 'react-router-dom'
import { rpc, supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useCommand } from '../../lib/commands'
import { roastCheck, blendInputs, RULES } from '../../domain/rules'
import { grams, pctFmt } from '../../lib/format'
import { Button, Card, ErrorBanner, Field, H1, Input, Label, Loading, Notice, Select, Textarea, cx } from '../../components/ui'

export default function Tostar() {
  const data = useAsync(async () => {
    const [coffees, blend, green] = await Promise.all([
      supabase.from('coffees').select('id, name, kind, green_id').eq('active', true).order('sort'),
      supabase.from('blend_components').select('coffee_id, green_id, pct'),
      rpc('green_panel'),
    ])
    return { coffees: coffees.data || [], blend: blend.data || [], green }
  }, [])
  const [f, setF] = useState({ cafe_id: '', verde_kg: '', tostado_g: '', motivo: '' })
  const [done, setDone] = useState(null)
  const cmd = useCommand()
  if (!data.data) return <Loading />
  const { coffees, blend, green } = data.data
  const coffee = coffees.find((c) => c.id === f.cafe_id)
  const verdeG = Math.round(Number(String(f.verde_kg).replace(',', '.')) * 1000) || 0
  const tostadoG = Number(f.tostado_g) || 0
  const check = verdeG && tostadoG ? roastCheck(verdeG, tostadoG) : null
  const inputs = coffee ? (coffee.kind === 'origen' ? [{ green_id: coffee.green_id, grams: verdeG }]
    : blendInputs(verdeG, blend.filter((b) => b.coffee_id === coffee.id).map((b) => ({ green_id: b.green_id, pct: Number(b.pct) })))) : []
  const faltante = inputs.find((i) => (green.find((g) => g.id === i.green_id)?.stock_g ?? 0) < i.grams)
  const needsReason = check?.needsReason || cmd.error?.code === 'merma_fuera_de_rango'

  async function submit() {
    const r = await cmd.run('registrar_tueste', { cafe_id: f.cafe_id, verde_g: verdeG, tostado_g: tostadoG, motivo: f.motivo || null })
    if (r?.ok) { setDone(r); setF({ cafe_id: '', verde_kg: '', tostado_g: '', motivo: '' }); data.reload() }
  }

  return (
    <div className="mx-auto max-w-xl space-y-4">
      <H1>Registrar tueste</H1>
      {done && (
        <Notice tone="ok">
          <div className="font-display text-xl font-extrabold">Lote {done.codigo}</div>
          <div>Merma {pctFmt(done.merma_pct)}. {done.mensaje}</div>
          <Link to="/tostaduria" className="mt-2 inline-block underline">Ver lotes</Link>
        </Notice>
      )}
      <Field label="¿Qué tostaste?">
        <Select value={f.cafe_id} onChange={(e) => setF({ ...f, cafe_id: e.target.value })}>
          <option value="">Elegí el café</option>
          {coffees.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </Select>
      </Field>
      <div className="grid grid-cols-2 gap-3">
        <Field label="Verde que entró (kg)"><Input inputMode="decimal" value={f.verde_kg} onChange={(e) => setF({ ...f, verde_kg: e.target.value })} placeholder="15" /></Field>
        <Field label="Tostado real (g)" hint="Pesalo en la balanza."><Input inputMode="numeric" value={f.tostado_g} onChange={(e) => setF({ ...f, tostado_g: e.target.value.replace(/\D/g, '') })} placeholder="12750" /></Field>
      </div>
      {coffee && verdeG > 0 && (
        <Card>
          <Label>Se descuenta del verde</Label>
          <ul className="mt-2 space-y-1 text-sm">
            {inputs.map((i) => {
              const g = green.find((x) => x.id === i.green_id)
              return <li key={i.green_id} className={cx('flex justify-between', g?.stock_g < i.grams && 'font-semibold text-[#b5432f]')}><span>{g?.nombre}{i.pct ? ` (${i.pct} %)` : ''}</span><span className="num">{grams(i.grams)} de {grams(g?.stock_g)}</span></li>
            })}
          </ul>
        </Card>
      )}
      {check?.ok && (
        <div className={cx('rounded-3xl p-5', check.inRange ? 'bg-cafe text-crema' : 'bg-ambar text-noche')}>
          <Label className={check.inRange ? 'text-ambar' : 'text-noche'}>Merma calculada</Label>
          <div className="num font-display text-5xl font-extrabold">{pctFmt(check.pct)}</div>
          <div className="text-sm">{check.inRange ? `Dentro del rango ${RULES.shrinkMin}–${RULES.shrinkMax} %.` : `Fuera del rango ${RULES.shrinkMin}–${RULES.shrinkMax} %: confirmá con un motivo.`}</div>
        </div>
      )}
      {check && !check.ok && <Notice tone="warn">{check.code === 'tostado_mayor' ? 'El tostado no puede pesar más que el verde. Revisá la balanza.' : 'Completá los pesos.'}</Notice>}
      {needsReason && <Field label="Motivo"><Textarea value={f.motivo} onChange={(e) => setF({ ...f, motivo: e.target.value })} placeholder="Ej.: perfil más oscuro para espresso, balanza verificada" /></Field>}
      {faltante && <Notice tone="warn">No alcanza el verde para este tueste.</Notice>}
      <Notice tone="info">El lote nuevo queda <b>En reposo</b> 24 horas: no se puede vender hasta mañana.</Notice>
      <ErrorBanner error={cmd.error?.code === 'merma_fuera_de_rango' ? null : cmd.error} onRefresh={() => { cmd.clearError(); data.reload() }} />
      <Button size="lg" className="w-full" busy={cmd.busy}
        disabled={!coffee || !check?.ok || !!faltante || (needsReason && f.motivo.trim().length < 5)} onClick={submit}>
        Registrar lote
      </Button>
    </div>
  )
}
