import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { Button, Card, ErrorBanner, H1, Input, Loading, Notice } from '../../components/ui'

export default function Zonas() {
  const zones = useAsync(async () => { const { data, error } = await supabase.from('zones').select('*').order('sort'); if (error) throw error; return data }, [])
  const [nombre, setNombre] = useState('')
  const [err, setErr] = useState(null)
  async function save(fn) { setErr(null); const { error } = await fn(); if (error) setErr({ message: error.message }); else zones.reload() }
  return (
    <div className="space-y-4">
      <H1>Zonas de reparto</H1>
      <Notice tone="info">Lista editable, sin mapa. Una zona inactiva deja de ofrecerse en la web; los pedidos y recorridos viejos la conservan.</Notice>
      <ErrorBanner error={err} onRefresh={zones.reload} />
      {zones.loading && <Loading />}
      {zones.data?.map((z) => (
        <Card key={z.id} className="flex items-center gap-2">
          <Input defaultValue={z.name} onBlur={(e) => e.target.value !== z.name && save(() => supabase.from('zones').update({ name: e.target.value }).eq('id', z.id))} />
          <Input className="w-20" defaultValue={z.notes || ''} placeholder="Notas" onBlur={(e) => save(() => supabase.from('zones').update({ notes: e.target.value }).eq('id', z.id))} />
          <Button size="sm" variant={z.active ? 'ghost' : 'primary'} onClick={() => save(() => supabase.from('zones').update({ active: !z.active }).eq('id', z.id))}>{z.active ? 'Desactivar' : 'Activar'}</Button>
        </Card>
      ))}
      <Card className="flex gap-2">
        <Input placeholder="Nueva zona" value={nombre} onChange={(e) => setNombre(e.target.value)} />
        <Button disabled={nombre.trim().length < 2} onClick={() => save(() => supabase.from('zones').insert({ name: nombre.trim(), sort: (zones.data?.length || 0) + 1 })).then(() => setNombre(''))}>Agregar</Button>
      </Card>
    </div>
  )
}
