// Motor de reglas en JavaScript, sin React ni Supabase.
// Sirve para PREVISUALIZAR (merma, totales, capacidad, estados) y validar antes de enviar.
// La autoridad es la base: cada regla se vuelve a validar dentro de la función SQL.
// Unidades: café en gramos enteros; dinero en pesos enteros; tiempo en milisegundos UTC.

export const RULES = {
  restHours: 24,
  freshDays: 30,
  shrinkMin: 12,
  shrinkMax: 20,
  wholesaleBlockPct: 40,
  routeCapacityG: 40000,
  cashDiffThreshold: 2000,
  returnDays: 7,
  paymentTermsDays: 15,
  overdueToleranceDays: 15,
  shippingFee: 3500,
  freeShippingFrom: 50000,
  almondExtra: 900,
  minWholesaleKg: 2,
}

const HOUR = 3600_000
const DAY = 24 * HOUR

export const UNIT_GRAMS = { bolsa_250: 250, bolsa_1000: 1000, kg_grano: 1000, kg_molido: 1000 }

/** Merma de tueste en %, redondeada a 2 decimales (mitad hacia arriba, como round() de Postgres). */
export function shrinkPct(greenG, roastedG) {
  if (!(greenG > 0) || !(roastedG > 0)) return null
  return Math.round(((greenG - roastedG) * 10000) / greenG) / 100
}

export function roastCheck(greenG, roastedG, rules = RULES) {
  const g = Number(greenG), r = Number(roastedG)
  if (!(g > 0)) return { ok: false, code: 'falta_verde' }
  if (!(r > 0)) return { ok: false, code: 'falta_tostado' }
  if (r > g) return { ok: false, code: 'tostado_mayor' }
  const pct = shrinkPct(g, r)
  const inRange = pct >= rules.shrinkMin && pct <= rules.shrinkMax
  return { ok: true, pct, inRange, needsReason: !inRange, yieldPct: Math.round((10000 - pct * 100)) / 100 }
}

/** Costo del kilo tostado a partir de los insumos de verde. */
export function roastedCostPerKg(inputs, roastedG) {
  const sum = inputs.reduce((acc, i) => acc + i.grams * i.costPerKg, 0)
  return Math.round(sum / roastedG)
}

/** Reparte los gramos de un blend por porcentaje; el resto va al último componente. */
export function blendInputs(greenG, components) {
  const sorted = [...components].sort((a, b) => b.pct - a.pct)
  let assigned = 0
  return sorted.map((c, i) => {
    const grams = i === sorted.length - 1 ? greenG - assigned : Math.round((greenG * c.pct) / 100)
    assigned += grams
    return { ...c, grams }
  })
}

/** Estado de un lote por tiempo y kilos (misma regla que private.lot_status_at). */
export function lotStatus({ roastedAt, availableG, now, rules = RULES }) {
  const t = new Date(roastedAt).getTime()
  const n = new Date(now).getTime()
  if (availableG <= 0) return 'Agotado'
  if (n < t + rules.restHours * HOUR) return 'En reposo'
  if (n >= t + rules.freshDays * DAY) return 'Solo barra'
  return 'Disponible'
}

/**
 * Stock de un lote reconstruido desde sus movimientos y reservas.
 * movements: [{grams}] (tueste +, barra/entrega −, devolución +, ajuste ±)
 * allocations: [{grams, state, channel}]
 */
export function lotStock({ roastedG, roastedAt, blockPct = 0, movements, allocations, now, rules = RULES }) {
  const onHand = movements.reduce((a, m) => a + m.grams, 0)
  const reserved = allocations.filter((a) => a.state === 'reservada').reduce((a, x) => a + x.grams, 0)
  const available = onHand - reserved
  const whUsed = allocations
    .filter((a) => a.channel === 'mayorista' && a.state !== 'liberada')
    .reduce((a, x) => a + x.grams, 0)
  const protectedG = Math.max(0, Math.round((roastedG * blockPct) / 100) - whUsed)
  const status = lotStatus({ roastedAt, availableG: available, now, rules })
  const retail = status === 'Disponible' ? Math.max(0, available - protectedG) : 0
  const wholesale = status === 'Disponible' ? available : 0
  const barra = status === 'Disponible' ? retail : status === 'Solo barra' ? available : 0
  return { onHand, reserved, available, protectedG, status, retail, wholesale, barra }
}

/**
 * Reserva FIFO por lote en unidades enteras de bolsa (cada bolsa sale de un solo lote).
 * lots: [{id, roastedAt, retail, wholesale}] ; devuelve {allocations, missing}
 */
export function planReservation(lots, grams, channel, unitG) {
  const sorted = [...lots].sort((a, b) => new Date(a.roastedAt) - new Date(b.roastedAt))
  let need = grams
  const allocations = []
  for (const lot of sorted) {
    const avail = channel === 'mayorista' ? lot.wholesale : lot.retail
    const take = Math.min(need, Math.floor(avail / unitG) * unitG)
    if (take <= 0) continue
    allocations.push({ lotId: lot.id, grams: take })
    need -= take
    if (need === 0) break
  }
  return { allocations, missing: need }
}

export function shippingFor(subtotal, fulfillment, rules = RULES) {
  if (fulfillment !== 'envio') return 0
  return subtotal >= rules.freeShippingFrom ? 0 : rules.shippingFee
}

/** Totales de un carrito minorista: [{price, qty}] */
export function cartTotals(items, fulfillment, rules = RULES) {
  const subtotal = items.reduce((a, i) => a + (i.price || 0) * i.qty, 0)
  const shipping = shippingFor(subtotal, fulfillment, rules)
  return { subtotal, shipping, total: subtotal + shipping, faltaParaEnvioGratis: fulfillment === 'envio' && shipping > 0 ? rules.freeShippingFrom - subtotal : 0 }
}

export function wholesaleKg(items) {
  return items.reduce((a, i) => a + i.qty, 0)
}

/** Precio vigente: la versión con mayor valid_from ≤ fecha. Fechas 'YYYY-MM-DD'. */
export function priceOn(versions, date) {
  const v = versions.filter((p) => p.valid_from <= date).sort((a, b) => (a.valid_from < b.valid_from ? 1 : -1))[0]
  return v ? v.price : null
}

/** Ticket de barra: [{price, coffeeG, milkMl, qty, almond}] */
export function ticketTotals(items, rules = RULES) {
  return items.reduce(
    (acc, i) => {
      const unit = i.price + (i.almond && i.milkMl > 0 ? rules.almondExtra : 0)
      acc.total += unit * i.qty
      acc.coffeeG += i.coffeeG * i.qty
      if (i.almond && i.milkMl > 0) acc.almondMl += i.milkMl * i.qty
      else acc.milkMl += i.milkMl * i.qty
      return acc
    },
    { total: 0, coffeeG: 0, milkMl: 0, almondMl: 0 },
  )
}

export function cashClose(expected, counted, rules = RULES) {
  const diff = counted - expected
  return { diff, needsReason: Math.abs(diff) > rules.cashDiffThreshold }
}

export function routeFits(loadG, addG, capacityG = RULES.routeCapacityG) {
  return { fits: loadG + addG <= capacityG, after: loadG + addG, free: capacityG - loadG }
}

export function returnAllowed(deliveredAt, now, rules = RULES) {
  if (!deliveredAt) return false
  return new Date(now).getTime() <= new Date(deliveredAt).getTime() + rules.returnDays * DAY
}

/** Destino físico de una devolución aceptada. */
export function returnDestination(condition, lotStatusNow) {
  if (condition !== 'cerrada') return 'merma'
  return lotStatusNow === 'Solo barra' ? 'barra' : 'stock'
}

function dateOnly(d) {
  return typeof d === 'string' ? d.slice(0, 10) : new Date(d).toISOString().slice(0, 10)
}
function daysBetween(a, b) {
  return Math.round((Date.parse(dateOnly(b)) - Date.parse(dateOnly(a))) / DAY)
}

/**
 * Estado de crédito: pagos y notas aplicados FIFO a los cargos más viejos.
 * movements: [{amount, kind, created_at, due_date}] (+ deuda, − pagos/NC)
 */
export function creditStatus({ movements, today, limit, openOrdersTotal = 0, extra = 0, rules = RULES }) {
  const balance = movements.reduce((a, m) => a + m.amount, 0)
  const credits = -movements.filter((m) => m.amount < 0).reduce((a, m) => a + m.amount, 0)
  const charges = movements.filter((m) => m.amount > 0).sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
  let cum = 0
  let overdueAmount = 0
  let oldestDue = null
  for (const c of charges) {
    cum += c.amount
    const unpaid = Math.max(0, Math.min(c.amount, cum - credits))
    if (unpaid > 0 && c.due_date < today) {
      overdueAmount += unpaid
      if (!oldestDue || c.due_date < oldestDue) oldestDue = c.due_date
    }
  }
  const overdueDays = oldestDue ? daysBetween(oldestDue, today) : 0
  const exposure = balance + openOrdersTotal + extra
  let reason = null
  if (overdueDays > rules.overdueToleranceDays) reason = 'deuda_vencida'
  else if (exposure > limit) reason = 'limite_credito'
  return { balance, overdueAmount, overdueDays, exposure, blocked: !!reason, reason }
}

/** Indicadores: sin datos aplicables devuelve null (la UI muestra «Sin datos», nunca 0 %). */
export function pct(part, whole) {
  if (whole == null || whole === 0 || part == null) return null
  return Math.round((part * 10000) / whole) / 100
}
export function avg(values) {
  const v = values.filter((x) => x != null)
  if (!v.length) return null
  return Math.round(v.reduce((a, x) => a + x, 0) / v.length)
}
