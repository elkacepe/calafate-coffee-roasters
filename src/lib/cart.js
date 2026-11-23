import { useEffect, useState } from 'react'

// Borrador del carrito en el dispositivo: sobrevive a recargas y errores.
export function useStoredState(key, initial) {
  const [value, setValue] = useState(() => {
    try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : initial } catch { return initial }
  })
  useEffect(() => {
    try { localStorage.setItem(key, JSON.stringify(value)) } catch { /* sin almacenamiento */ }
  }, [key, value])
  return [value, setValue]
}

export function addItem(items, item) {
  const k = (i) => `${i.cafe_id}|${i.presentacion}|${i.molienda}`
  const found = items.find((i) => k(i) === k(item))
  if (found) return items.map((i) => (k(i) === k(item) ? { ...i, cantidad: i.cantidad + item.cantidad } : i))
  return [...items, item]
}
