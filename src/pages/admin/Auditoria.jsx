import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { fmtDateTime } from '../../lib/format'
import { Badge, Card, H1, Label, Loading, LoadError, Sheet, cx } from '../../components/ui'

export default function Auditoria() {
  const cmds = useAsync(async () => { const { data, error } = await supabase.from('commands').select('*').order('created_at', { ascending: false }).limit(100); if (error) throw error; return data }, [])
  const [sel, setSel] = useState(null)
  const events = useAsync(async () => {
    let q = supabase.from('domain_events').select('*').order('id', { ascending: false }).limit(150)
    if (sel) q = q.eq('command_id', sel.id)
    return (await q).data
  }, [sel?.id])
  return (
    <div className="space-y-4">
      <H1>Auditoría</H1>
      <p className="text-sm text-cafe/70">Cada comando guarda id, tipo, entidad, actor, instante, revisión esperada, datos y resultado. Cada evento guarda el comando de origen, el estado anterior y el nuevo, el efecto y el motivo.</p>
      {cmds.loading && <Loading />}
      {cmds.error && <LoadError error={cmds.error} onRetry={cmds.reload} />}
      <div className="space-y-2">
        {cmds.data?.map((c) => (
          <button key={c.id} className="block w-full text-left" onClick={() => setSel(c)}>
            <Card className="py-3">
              <div className="flex items-center justify-between gap-2">
                <span className="font-medium">{c.type}</span>
                <Badge status={c.status === 'aplicado' ? 'Entregado' : 'Para reprogramar'}>{c.status}</Badge>
              </div>
              <div className="text-xs text-cafe/60">{fmtDateTime(c.created_at)} · {c.actor_role || 'público'} · rev. esperada {c.expected_revision ?? '—'} → {c.resulting_revision ?? '—'}{c.result?.code && ` · ${c.result.code}`}</div>
              <div className="truncate font-mono text-[10px] text-cafe/50">{c.id}</div>
            </Card>
          </button>
        ))}
        {cmds.data?.length === 0 && <div className="text-sm text-cafe/60">Sin comandos.</div>}
      </div>
      <Sheet open={!!sel} onClose={() => setSel(null)} title={sel?.type || ''}>
        {sel && (
          <div className="space-y-3 text-xs">
            <Label>Datos</Label><pre className="overflow-x-auto rounded-2xl bg-white p-3">{JSON.stringify(sel.payload, null, 2)}</pre>
            <Label>Resultado</Label><pre className="overflow-x-auto rounded-2xl bg-white p-3">{JSON.stringify(sel.result, null, 2)}</pre>
            <Label>Eventos ({events.data?.length || 0})</Label>
            {events.data?.length === 0 && <div>Sin eventos (un comando rechazado no deja eventos de dominio).</div>}
            {events.data?.map((e) => (
              <div key={e.id} className={cx('rounded-2xl bg-white p-3')}>
                <div className="font-medium">{e.event_type} · {e.entity} v{e.entity_revision ?? '—'}</div>
                <div>{e.from_state ?? '∅'} → {e.to_state ?? '∅'}{e.reason && ` · ${e.reason}`}</div>
                <div className="font-mono text-[10px] text-cafe/60">{JSON.stringify(e.effect)}</div>
              </div>
            ))}
          </div>
        )}
      </Sheet>
    </div>
  )
}
