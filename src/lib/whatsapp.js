// Sin SMS ni email: los avisos se comparten por WhatsApp con el texto armado.
export function waLink(text, phone) {
  const t = encodeURIComponent(text)
  const p = (phone || '').replace(/\D/g, '')
  return p ? `https://wa.me/${p}?text=${t}` : `https://wa.me/?text=${t}`
}
