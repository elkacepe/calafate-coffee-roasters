export function toCSV(rows, columns) {
  const esc = (v) => {
    if (v == null) return ''
    const s = String(v)
    return /[",;\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s
  }
  const head = columns.map((c) => esc(c.label)).join(';')
  const body = rows.map((r) => columns.map((c) => esc(typeof c.value === 'function' ? c.value(r) : r[c.key])).join(';'))
  return [head, ...body].join('\n')
}

export function downloadCSV(filename, text) {
  const blob = new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = filename
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}
