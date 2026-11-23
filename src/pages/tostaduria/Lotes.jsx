import { useState } from 'react'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { H1, Loading, LoadError, Notice } from '../../components/ui'
import { LotCards, LotFilter } from '../../components/LotCards'

export default function Lotes({ mode = 'tostaduria' }) {
  // Al abrir el panel se recalculan los estados por tiempo (fin de reposo, paso a Solo barra).
  const lots = useAsync(async () => { const n = await rpc('refresh_lot_states'); const l = await rpc('lot_panel'); return { n, l } }, [])
  const [f, setF] = useState('todos')
  return (
    <div className="space-y-4">
      <H1>Lotes tostados</H1>
      {lots.loading && <Loading />}
      {lots.error && <LoadError error={lots.error} onRetry={lots.reload} />}
      {lots.data?.n > 0 && <Notice tone="info">{lots.data.n} lote(s) cambiaron de estado por tiempo al abrir el panel.</Notice>}
      {lots.data && (<><LotFilter value={f} onChange={setF} lots={lots.data.l} /><LotCards lots={lots.data.l} mode={mode} filter={f} onChanged={lots.reload} /></>)}
    </div>
  )
}
