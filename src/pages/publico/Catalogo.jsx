import { useState } from 'react'
import { Link } from 'react-router-dom'
import { rpc } from '../../lib/supabase'
import { useAsync } from '../../lib/useAsync'
import { useStoredState, addItem } from '../../lib/cart'
import { ars, grams, roastedLabel, untilLabel, MOLIENDAS } from '../../lib/format'
import { Button, Card, H1, Label, Loading, LoadError, Mountains, Segmented, Bag, Notice, cx } from '../../components/ui'

export default function Catalogo() {
  const { data, error, loading, reload } = useAsync(() => rpc('public_catalog'), [])
  const [cart, setCart] = useStoredState('calafate.carrito', [])
  const [added, setAdded] = useState(null)

  return (
    <div>
      <section className="relative -mx-4 mb-6 overflow-hidden bg-cafe px-4 pb-20 pt-10 text-crema sm:rounded-b-[3rem]">
        <Label className="text-ambar">Tostado en el local · El Calafate</Label>
        <h1 className="mt-2 max-w-xl font-display text-4xl font-extrabold leading-[1.05] sm:text-5xl">Café recién tostado, de la tostadora a tu taza.</h1>
        <p className="mt-3 max-w-md text-crema/80">Elegí tu café y tu molienda. Retirás en el local o te lo llevamos.</p>
        <Mountains className="absolute bottom-0 left-0 h-20 w-full" />
      </section>

      {loading && <Loading label="Buscando el café de hoy…" />}
      {error && <LoadError error={error} onRetry={reload} />}
      {data && (
        <>
          <Notice tone="info" className="mb-4">
            Envío en la ciudad {ars(data.envio.tarifa)}. <b>Gratis desde {ars(data.envio.gratis_desde)}</b>.
          </Notice>
          <div className="grid gap-4 sm:grid-cols-2">
            {data.cafes.map((c) => (
              <CoffeeCard key={c.id} cafe={c} onAdd={(item) => { setCart(addItem(cart, item)); setAdded(c.nombre) }} />
            ))}
          </div>
        </>
      )}
      {added && (
        <div className="fixed inset-x-4 bottom-4 z-40 mx-auto flex max-w-md items-center justify-between gap-3 rounded-3xl bg-noche p-4 text-crema shadow-card">
          <span className="text-sm">Sumaste <b>{added}</b> al carrito.</span>
          <Link to="/carrito" className="rounded-2xl bg-ambar px-4 py-2 text-sm font-semibold text-noche">Ver carrito</Link>
          <button onClick={() => setAdded(null)} aria-label="Cerrar" className="text-crema/60">✕</button>
        </div>
      )}
    </div>
  )
}

function CoffeeCard({ cafe, onAdd }) {
  const [pres, setPres] = useState('bolsa_250')
  const [mol, setMol] = useState('grano')
  const [qty, setQty] = useState(1)
  const unit = pres === 'bolsa_250' ? 250 : 1000
  const price = pres === 'bolsa_250' ? cafe.precio_250 : cafe.precio_1000
  const max = Math.floor((cafe.disponible_g || 0) / unit)
  const sinStock = max < 1
  return (
    <Card className="flex flex-col">
      <div className="flex gap-4">
        <Bag className="h-24 w-20 shrink-0" label={cafe.tipo === 'blend' ? 'BLEND' : 'ORIGEN'} />
        <div className="min-w-0">
          <Label>{cafe.tipo === 'blend' ? 'Blend de la casa' : 'Origen'}</Label>
          <h2 className="font-display text-2xl font-extrabold leading-tight">{cafe.nombre}</h2>
          <div className="text-xs text-cafe/70">{cafe.origen}</div>
          {cafe.tostado_el ? (
            <div className="mt-2 inline-flex rounded-full bg-ambar/30 px-3 py-1 text-xs font-semibold text-cafe">{roastedLabel(cafe.tostado_el, 'Se tostó')}</div>
          ) : cafe.reposo_hasta ? (
            <div className="mt-2 inline-flex rounded-full bg-glaciar/40 px-3 py-1 text-xs font-semibold text-noche">En reposo · listo {untilLabel(cafe.reposo_hasta)}</div>
          ) : null}
        </div>
      </div>
      <p className="mt-3 text-sm">{cafe.notas}</p>
      <div className="mt-4 space-y-3">
        <Segmented value={pres} onChange={(v) => { setPres(v); setQty(1) }}
          options={[{ value: 'bolsa_250', label: `250 g · ${ars(cafe.precio_250)}` }, { value: 'bolsa_1000', label: `1 kg · ${ars(cafe.precio_1000)}` }]} />
        <div>
          <div className="mb-1 text-xs font-medium">Elegí tu molienda</div>
          <div className="flex flex-wrap gap-2">
            {MOLIENDAS.map((m) => (
              <button key={m} type="button" onClick={() => setMol(m)}
                className={cx('rounded-full border px-3 py-1.5 text-sm capitalize', mol === m ? 'border-canela bg-canela text-crema' : 'border-cafe/20 bg-white')}>
                {m}
              </button>
            ))}
          </div>
        </div>
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center rounded-2xl border border-cafe/20 bg-white">
            <button className="h-12 w-12 text-xl" onClick={() => setQty(Math.max(1, qty - 1))} aria-label="Menos">−</button>
            <span className="num w-8 text-center font-medium">{qty}</span>
            <button className="h-12 w-12 text-xl" onClick={() => setQty(Math.min(max || 1, qty + 1))} aria-label="Más">+</button>
          </div>
          <Button className="flex-1" disabled={sinStock || !price}
            onClick={() => onAdd({ cafe_id: cafe.id, nombre: cafe.nombre, presentacion: pres, molienda: mol, cantidad: qty, precio: price })}>
            {sinStock ? 'Sin stock por hoy' : `Agregar · ${ars(price * qty)}`}
          </Button>
        </div>
        {!sinStock && max <= 4 && <div className="text-xs text-canela">Quedan {grams(cafe.disponible_g)} para la venta.</div>}
      </div>
    </Card>
  )
}
