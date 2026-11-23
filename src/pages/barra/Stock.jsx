import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { grams } from '../../lib/format'
import { H1, H2, Loading, LoadError, Card, Label } from '../../components/ui'
import { LotCards, LotFilter } from '../../components/LotCards'

export default function Stock() {
  const lots = useAsync(async () => { await rpc('refresh_lot_states'); return rpc('lot_panel') }, [])
  const sup = useAsync(() => rpc('supply_panel'), [])
  const [f, setF] = useState('todos')
  return (
    <div className="space-y-4">
      <H1>Stock disponible</H1>
      <div className="grid grid-cols-2 gap-3">
        {sup.data?.filter((s) => s.codigo.startsWith('leche')).map((s) => (
          <Card key={s.id}><Label>{s.nombre}</Label><div className="num font-display text-3xl font-extrabold">{(s.stock / 1000).toLocaleString('es-AR')} <span className="text-base font-normal">l</span></div></Card>
        ))}
      </div>
      {lots.loading && <Loading />}
      {lots.error && <LoadError error={lots.error} onRetry={lots.reload} />}
      {lots.data && (<><LotFilter value={f} onChange={setF} lots={lots.data} /><LotCards lots={lots.data} mode="barra" filter={f} /></>)}
    </div>
  )
}
