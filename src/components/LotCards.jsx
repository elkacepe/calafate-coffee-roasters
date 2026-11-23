import { useState } from 'react'
import { useCommand } from '../lib/commands'
import { grams, kg, roastedLabel, untilLabel, pctFmt, fmtDateTime, ars } from '../lib/format'
import { Badge, Button, Card, ErrorBanner, Field, Input, Label, Segmented, Sheet, Textarea, Notice, cx } from './ui'

const ORDER = { 'En reposo': 0, Disponible: 1, 'Solo barra': 2, Agotado: 3 }

export function LotCards({ lots, mode = 'tostaduria', onChanged, filter }) {
  const [sel, setSel] = useState(null)
  const list = [...lots].filter((l) => !filter || filter === 'todos' || l.estado === filter)
    .sort((a, b) => ORDER[a.estado] - ORDER[b.estado] || (a.tostado_el < b.tostado_el ? 1 : -1))
  return (
    <>
      <div className="grid gap-3 sm:grid-cols-2">
        {list.map((l) => (
          <button key={l.id} className="text-left" onClick={() => setSel(l)}>
            <Card className={cx('h-full', l.estado === 'Agotado' && 'opacity-60')}>
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-mono text-xs text-cafe/60">{l.codigo}</div>
                  <div className="font-display text-xl font-extrabold leading-tight">{l.cafe}</div>
                  <div className="text-xs">{roastedLabel(l.tostado_el)} · merma {pctFmt(l.merma_pct)}</div>
                </div>
                <Badge status={l.estado} className="text-sm" />
              </div>
              <div className="mt-3 grid grid-cols-3 gap-2">
                <Big label={mode === 'barra' ? 'Para barra' : 'Disponible'} g={mode === 'barra' ? l.barra_g : l.disponible_g} strong />
                <Big label="Reservado" g={l.reservado_g} />
                <Big label="En mano" g={l.en_mano_g} />
              </div>
              {l.estado === 'En reposo' && <div className="mt-2 rounded-xl bg-glaciar/30 px-3 py-1.5 text-xs">No se vende hasta {untilLabel(l.reposo_hasta)}.</div>}
              {l.estado === 'Disponible' && l.protegido_g > 0 && <div className="mt-2 text-xs text-canela">{grams(l.protegido_g)} bloqueados para mayoristas ({Number(l.bloqueo_pct)} %).</div>}
              {l.estado === 'Disponible' && <div className="mt-1 text-xs text-cafe/60">Pasa a «Solo barra» {untilLabel(l.solo_barra_desde)}.</div>}
            </Card>
          </button>
        ))}
      </div>
      <LotSheet lot={sel} mode={mode} onClose={() => setSel(null)} onChanged={() => { setSel(null); onChanged?.() }} />
    </>
  )
}

function Big({ label, g, strong }) {
  return (
    <div>
      <div className="text-[10px] font-semibold uppercase tracking-wider text-canela">{label}</div>
      <div className={cx('num font-display font-extrabold leading-none', strong ? 'text-3xl' : 'text-xl text-cafe/80')}>{kg(g)}<span className="ml-0.5 font-body text-xs font-normal">kg</span></div>
    </div>
  )
}

function LotSheet({ lot, mode, onClose, onChanged }) {
  const cmd = useCommand()
  const [bolsas, setBolsas] = useState('')
  const [formato, setFormato] = useState('bolsa_250')
  const [pct, setPct] = useState('')
  const [ajuste, setAjuste] = useState({ gramos: '', motivo: '' })
  if (!lot) return null
  return (
    <Sheet open={!!lot} onClose={onClose} title={`${lot.cafe} · ${lot.codigo}`}>
      <div className="space-y-4 text-sm">
        <div className="flex flex-wrap gap-2"><Badge status={lot.estado} /><span>{roastedLabel(lot.tostado_el)} ({fmtDateTime(lot.tostado_el)})</span></div>
        <div className="grid grid-cols-2 gap-2">
          <Card><Label>Verde usado</Label><div className="num font-display text-2xl font-extrabold">{grams(lot.verde_g)}</div></Card>
          <Card><Label>Tostado real</Label><div className="num font-display text-2xl font-extrabold">{grams(lot.tostado_g)}</div></Card>
          <Card><Label>Merma de tueste</Label><div className="num font-display text-2xl font-extrabold">{pctFmt(lot.merma_pct)}</div>{lot.motivo_merma && <div className="text-xs">{lot.motivo_merma}</div>}</Card>
          <Card><Label>Costo kg tostado</Label><div className="num font-display text-2xl font-extrabold">{ars(lot.costo_kg)}</div></Card>
        </div>
        <div className="grid grid-cols-3 gap-2 text-center">
          <div><Label>Minorista</Label><div className="num text-lg font-semibold">{grams(lot.minorista_g)}</div></div>
          <div><Label>Mayorista</Label><div className="num text-lg font-semibold">{grams(lot.mayorista_g)}</div></div>
          <div><Label>Barra</Label><div className="num text-lg font-semibold">{grams(lot.barra_g)}</div></div>
        </div>
        <div className="text-xs text-cafe/70">Consumido {grams(lot.consumido_g)} · merma por devoluciones {grams(lot.merma_devolucion_g)} · envasado: {Object.entries(lot.envasado || {}).map(([f, n]) => `${n} × ${f === 'bolsa_250' ? '250 g' : '1 kg'}`).join(', ') || 'sin envasar'}</div>

        <ErrorBanner error={cmd.error} onRefresh={onChanged} />

        {(mode === 'tostaduria' || mode === 'admin') && lot.estado !== 'Agotado' && (
          <div className="rounded-2xl border border-cafe/10 p-3">
            <Label>Envasar</Label>
            <div className="mt-2 space-y-2">
              <Segmented value={formato} onChange={setFormato} options={[{ value: 'bolsa_250', label: '250 g' }, { value: 'bolsa_1000', label: '1 kg' }]} />
              <div className="flex gap-2">
                <Input inputMode="numeric" placeholder="Bolsas" value={bolsas} onChange={(e) => setBolsas(e.target.value.replace(/\D/g, ''))} />
                <Button busy={cmd.busy} disabled={!bolsas} onClick={async () => { const r = await cmd.run('envasar', { lote_id: lot.id, formato, bolsas: Number(bolsas) }); if (r?.ok) onChanged() }}>Registrar</Button>
              </div>
            </div>
          </div>
        )}
        {mode === 'admin' && (
          <div className="rounded-2xl border border-cafe/10 p-3">
            <Label>Bloqueo para mayoristas</Label>
            <p className="mt-1 text-xs">Porcentaje del lote que el canal minorista no puede tocar. Ahora: {Number(lot.bloqueo_pct)} %.</p>
            <div className="mt-2 flex gap-2">
              <Input inputMode="numeric" placeholder="40" value={pct} onChange={(e) => setPct(e.target.value.replace(/[^\d.]/g, ''))} />
              <Button busy={cmd.busy} disabled={pct === ''} onClick={async () => { const r = await cmd.run('bloquear_lote', { lote_id: lot.id, pct: Number(pct) }, lot.revision); if (r?.ok) onChanged() }}>Guardar</Button>
            </div>
          </div>
        )}
        {(mode === 'tostaduria' || mode === 'admin') && (
          <div className="rounded-2xl border border-cafe/10 p-3">
            <Label>Proponer ajuste de stock</Label>
            <p className="mt-1 text-xs">No se edita el lote: se crea una propuesta que revisa otra persona de administración. Si se aprueba queda un ajuste vinculado.</p>
            <div className="mt-2 space-y-2">
              <Input inputMode="numeric" placeholder="Gramos (ej. -300)" value={ajuste.gramos} onChange={(e) => setAjuste({ ...ajuste, gramos: e.target.value.replace(/[^\d-]/g, '') })} />
              <Textarea placeholder="Motivo" value={ajuste.motivo} onChange={(e) => setAjuste({ ...ajuste, motivo: e.target.value })} />
              <Button variant="ghost" className="w-full" busy={cmd.busy} disabled={!Number(ajuste.gramos) || ajuste.motivo.trim().length < 5}
                onClick={async () => { const r = await cmd.run('proponer_cambio', { entidad: 'lote', entidad_id: lot.id, cambios: { gramos: Number(ajuste.gramos) }, motivo: ajuste.motivo }, lot.revision); if (r?.ok) { setAjuste({ gramos: '', motivo: '' }); onChanged() } }}>
                Enviar propuesta
              </Button>
            </div>
          </div>
        )}
      </div>
    </Sheet>
  )
}

export function LotFilter({ value, onChange, lots }) {
  const count = (s) => lots.filter((l) => s === 'todos' || l.estado === s).length
  return (
    <div className="flex gap-2 overflow-x-auto pb-1">
      {['todos', 'Disponible', 'En reposo', 'Solo barra', 'Agotado'].map((s) => (
        <button key={s} onClick={() => onChange(s)}
          className={cx('shrink-0 rounded-full border px-3 py-2 text-sm', value === s ? 'border-cafe bg-cafe text-crema' : 'border-cafe/20 bg-white')}>
          {s === 'todos' ? 'Todos' : s} · {count(s)}
        </button>
      ))}
    </div>
  )
}
