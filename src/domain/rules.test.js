import { describe, it, expect } from 'vitest'
import {
  shrinkPct, roastCheck, roastedCostPerKg, blendInputs, lotStatus, lotStock, planReservation, cartTotals,
  ticketTotals, cashClose, routeFits, returnAllowed, returnDestination, creditStatus, priceOn, pct, avg,
} from './rules.js'

// Reloj fijo para todas las pruebas: lunes 23/11/2026 08:00 en Argentina (UTC−3).
const NOW = '2026-11-23T11:00:00Z'
const hoursAgo = (h) => new Date(Date.parse(NOW) - h * 3600_000).toISOString()
const daysAgo = (d) => hoursAgo(d * 24)

describe('Café tostado por lote y unidad base', () => {
  it('1.000 g verdes al 85 % → 850 g; vender 250 deja 600 (y el verde no sigue en 1.000)', () => {
    const roast = roastCheck(1000, 850)
    expect(roast.pct).toBe(15)
    expect(roast.yieldPct).toBe(85)
    const green = 1000 - 1000
    expect(green).toBe(0)
    const movements = [{ grams: 850 }]
    const reserved = [{ grams: 250, state: 'reservada', channel: 'web' }]
    const s = lotStock({ roastedG: 850, roastedAt: daysAgo(2), movements, allocations: reserved, now: NOW })
    expect(s.onHand).toBe(850)
    expect(s.available).toBe(600)
    // al entregar: la reserva pasa a consumida y sale el movimiento físico
    const s2 = lotStock({ roastedG: 850, roastedAt: daysAgo(2), movements: [...movements, { grams: -250 }],
      allocations: [{ grams: 250, state: 'consumida', channel: 'web' }], now: NOW })
    expect(s2).toMatchObject({ onHand: 600, reserved: 0, available: 600 })
  })
})

describe('Tueste y merma', () => {
  it('redondea a 2 decimales', () => {
    expect(shrinkPct(10000, 8450)).toBe(15.5)
    expect(shrinkPct(3, 2)).toBe(33.33)
    expect(shrinkPct(0, 10)).toBeNull()
  })
  it('pide motivo fuera de 12–20 %', () => {
    expect(roastCheck(5000, 3500)).toMatchObject({ pct: 30, needsReason: true })
    expect(roastCheck(5000, 4000)).toMatchObject({ pct: 20, needsReason: false })
    expect(roastCheck(5000, 4400)).toMatchObject({ pct: 12, needsReason: false })
    expect(roastCheck(5000, 4500)).toMatchObject({ pct: 10, needsReason: true })
    expect(roastCheck(100, 200).code).toBe('tostado_mayor')
  })
  it('blend 60/40 asigna el resto al último componente', () => {
    const r = blendInputs(15001, [{ id: 'col', pct: 40 }, { id: 'bra', pct: 60 }])
    expect(r).toEqual([{ id: 'bra', pct: 60, grams: 9001 }, { id: 'col', pct: 40, grams: 6000 }])
    expect(r.reduce((a, x) => a + x.grams, 0)).toBe(15001)
  })
  it('costo del kilo tostado', () => {
    expect(roastedCostPerKg([{ grams: 1000, costPerKg: 20000 }], 850)).toBe(23529)
  })
})

describe('Reposo y frescura', () => {
  it('24 h en reposo, Disponible hasta los 30 días, después Solo barra, en cero Agotado', () => {
    expect(lotStatus({ roastedAt: hoursAgo(23.9), availableG: 5000, now: NOW })).toBe('En reposo')
    expect(lotStatus({ roastedAt: hoursAgo(24), availableG: 5000, now: NOW })).toBe('Disponible')
    expect(lotStatus({ roastedAt: daysAgo(29.9), availableG: 5000, now: NOW })).toBe('Disponible')
    expect(lotStatus({ roastedAt: daysAgo(30), availableG: 5000, now: NOW })).toBe('Solo barra')
    expect(lotStatus({ roastedAt: daysAgo(3), availableG: 0, now: NOW })).toBe('Agotado')
  })
  it('Solo barra no acepta bolsas ni mayoristas pero sí barra', () => {
    const s = lotStock({ roastedG: 5000, roastedAt: daysAgo(31), movements: [{ grams: 5000 }], allocations: [], now: NOW })
    expect(s).toMatchObject({ status: 'Solo barra', retail: 0, wholesale: 0, barra: 5000 })
  })
})

describe('Bloqueo mayorista y reserva FIFO', () => {
  it('40 % protegido para mayoristas que minorista no toca', () => {
    const s = lotStock({ roastedG: 10000, roastedAt: daysAgo(3), blockPct: 40, movements: [{ grams: 10000 }], allocations: [], now: NOW })
    expect(s.retail).toBe(6000)
    expect(s.wholesale).toBe(10000)
    const s2 = lotStock({ roastedG: 10000, roastedAt: daysAgo(3), blockPct: 40, movements: [{ grams: 10000 }],
      allocations: [{ grams: 3000, state: 'reservada', channel: 'mayorista' }], now: NOW })
    expect(s2.protectedG).toBe(1000)
    expect(s2.retail).toBe(6000)
  })
  it('reserva del lote más antiguo y parte la línea en bolsas enteras', () => {
    const lots = [
      { id: 'nuevo', roastedAt: daysAgo(2), retail: 5000, wholesale: 5000 },
      { id: 'viejo', roastedAt: daysAgo(10), retail: 750, wholesale: 1800 },
    ]
    expect(planReservation(lots, 1000, 'web', 250).allocations).toEqual([{ lotId: 'viejo', grams: 750 }, { lotId: 'nuevo', grams: 250 }])
    expect(planReservation(lots, 3000, 'mayorista', 1000).allocations).toEqual([{ lotId: 'viejo', grams: 1000 }, { lotId: 'nuevo', grams: 2000 }])
    expect(planReservation(lots, 9000, 'mayorista', 1000).missing).toBe(3000)
  })
})

describe('Ventas', () => {
  it('envío $3.500, gratis desde $50.000', () => {
    expect(cartTotals([{ price: 14500, qty: 3 }], 'envio')).toMatchObject({ subtotal: 43500, shipping: 3500, total: 47000, faltaParaEnvioGratis: 6500 })
    expect(cartTotals([{ price: 14500, qty: 4 }], 'envio')).toMatchObject({ shipping: 0, total: 58000 })
    expect(cartTotals([{ price: 14500, qty: 1 }], 'retiro').shipping).toBe(0)
  })
  it('precio vigente por fecha: un cambio futuro no toca lo confirmado', () => {
    const versions = [{ valid_from: '2026-09-24', price: 44000 }, { valid_from: '2026-11-30', price: 48000 }]
    expect(priceOn(versions, '2026-11-23')).toBe(44000)
    expect(priceOn(versions, '2026-11-30')).toBe(48000)
    expect(priceOn(versions, '2026-01-01')).toBeNull()
  })
})

describe('Barra', () => {
  it('receta: doble 18 g, flat white 18 g + 120 ml, almendras suma $900', () => {
    const t = ticketTotals([
      { price: 4900, coffeeG: 18, milkMl: 0, qty: 1 },
      { price: 5900, coffeeG: 18, milkMl: 120, qty: 2, almond: true },
    ])
    expect(t).toEqual({ total: 4900 + 2 * 6800, coffeeG: 54, milkMl: 0, almondMl: 240 })
  })
  it('cierre: motivo obligatorio si la diferencia supera $2.000', () => {
    expect(cashClose(100000, 97500)).toEqual({ diff: -2500, needsReason: true })
    expect(cashClose(100000, 102000)).toEqual({ diff: 2000, needsReason: false })
  })
})

describe('Reparto y devoluciones', () => {
  it('capacidad de 40 kg', () => {
    expect(routeFits(35000, 6000).fits).toBe(false)
    expect(routeFits(34000, 6000).fits).toBe(true)
  })
  it('plazo de 7 días y destino físico', () => {
    expect(returnAllowed(daysAgo(7), NOW)).toBe(true)
    expect(returnAllowed(daysAgo(7.01), NOW)).toBe(false)
    expect(returnDestination('cerrada', 'Disponible')).toBe('stock')
    expect(returnDestination('cerrada', 'Solo barra')).toBe('barra')
    expect(returnDestination('mal_sellada', 'Disponible')).toBe('merma')
  })
})

describe('Cuenta corriente', () => {
  const today = '2026-11-23'
  it('deuda vencida hace 18 días bloquea; el pago la cancela', () => {
    const movs = [{ amount: 264000, kind: 'cargo', created_at: '2026-10-21T13:00:00Z', due_date: '2026-11-05' }]
    const s = creditStatus({ movements: movs, today, limit: 600000 })
    expect(s).toMatchObject({ balance: 264000, overdueDays: 18, blocked: true, reason: 'deuda_vencida' })
    const paid = creditStatus({ movements: [...movs, { amount: -264000, kind: 'pago', created_at: '2026-11-23T12:00:00Z' }], today, limit: 600000, extra: 264000 })
    expect(paid).toMatchObject({ balance: 0, overdueDays: 0, blocked: false })
  })
  it('saldo final = pedido − nota de crédito', () => {
    const movs = [
      { amount: 264000, kind: 'cargo', created_at: '2026-11-23T15:00:00Z', due_date: '2026-12-08' },
      { amount: -44000, kind: 'nota_credito', created_at: '2026-11-23T16:00:00Z' },
    ]
    expect(creditStatus({ movements: movs, today, limit: 600000 }).balance).toBe(220000)
  })
  it('límite de crédito superado', () => {
    const s = creditStatus({ movements: [], today, limit: 300000, openOrdersTotal: 250000, extra: 60000 })
    expect(s).toMatchObject({ blocked: true, reason: 'limite_credito' })
  })
})

describe('Indicadores sin datos', () => {
  it('no muestran 0 % ni promedio 0', () => {
    expect(pct(0, 0)).toBeNull()
    expect(pct(null, 10)).toBeNull()
    expect(avg([])).toBeNull()
    expect(pct(15, 100)).toBe(15)
  })
})
