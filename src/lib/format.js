const TZ = 'America/Argentina/Buenos_Aires'

export const ars = (n) =>
  n == null ? '—' : '$' + Math.round(Number(n)).toLocaleString('es-AR', { maximumFractionDigits: 0 })

export const grams = (g) => {
  if (g == null) return '—'
  const n = Number(g)
  if (Math.abs(n) >= 1000) return (n / 1000).toLocaleString('es-AR', { maximumFractionDigits: 2 }) + ' kg'
  return n.toLocaleString('es-AR') + ' g'
}
export const kg = (g) => (g == null ? '—' : (Number(g) / 1000).toLocaleString('es-AR', { maximumFractionDigits: 1 }))

export const pctFmt = (p) => (p == null ? 'Sin datos' : Number(p).toLocaleString('es-AR', { maximumFractionDigits: 2 }) + ' %')

const dayName = new Intl.DateTimeFormat('es-AR', { weekday: 'long', timeZone: TZ })
const dateShort = new Intl.DateTimeFormat('es-AR', { day: '2-digit', month: '2-digit', timeZone: TZ })
const timeShort = new Intl.DateTimeFormat('es-AR', { hour: '2-digit', minute: '2-digit', timeZone: TZ })
const dateLong = new Intl.DateTimeFormat('es-AR', { weekday: 'short', day: 'numeric', month: 'short', timeZone: TZ })

export const localDate = (d = new Date()) =>
  new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(d))

export const fmtDate = (d) => (d ? dateShort.format(new Date(d.length === 10 ? d + 'T12:00:00Z' : d)) : '—')
export const fmtTime = (d) => (d ? timeShort.format(new Date(d)) : '—')
export const fmtDateTime = (d) => (d ? `${fmtDate(d)} ${fmtTime(d)}` : '—')
export const fmtDay = (d) => (d ? dateLong.format(new Date(d.length === 10 ? d + 'T12:00:00Z' : d)) : '—')

/** «Tostado hoy», «Tostado ayer», «Tostado el miércoles», «Tostado el 02/11» */
export function roastedLabel(d, prefix = 'Tostado') {
  if (!d) return null
  const days = Math.floor((Date.parse(localDate()) - Date.parse(localDate(d))) / 86400000)
  if (days <= 0) return `${prefix} hoy`
  if (days === 1) return `${prefix} ayer`
  if (days < 7) return `${prefix} el ${dayName.format(new Date(d))}`
  return `${prefix} el ${fmtDate(d)}`
}

export function untilLabel(d) {
  if (!d) return ''
  const days = Math.floor((Date.parse(localDate(d)) - Date.parse(localDate())) / 86400000)
  const t = fmtTime(d)
  if (days <= 0) return `hoy a las ${t}`
  if (days === 1) return `mañana a las ${t}`
  return `el ${fmtDate(d)} a las ${t}`
}

export const PRESENTACION = { bolsa_250: 'Bolsa 250 g', bolsa_1000: 'Bolsa 1 kg', kg_grano: 'Kilo en grano', kg_molido: 'Kilo molido' }
export const MOLIENDAS = ['grano', 'espresso', 'filtro', 'prensa francesa']
export const CONDICION = { cerrada: 'Cerrada y en buen estado', abierta: 'Abierta', defectuosa: 'Defectuosa', mal_sellada: 'Mal sellada' }
export const RESOLUCION = { reposicion: 'Reposición en el próximo recorrido', nota_credito: 'Nota de crédito', reintegro: 'Reintegro (registrado a mano)' }
export const METODOS = { efectivo: 'Efectivo', tarjeta: 'Tarjeta', transferencia: 'Transferencia', qr: 'QR' }
