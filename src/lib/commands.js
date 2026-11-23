import { useCallback, useRef, useState } from 'react'
import { supabase, humanError } from './supabase'

function newId() {
  return crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16)
  })
}

/**
 * Envía comandos a public.run_command.
 * - Un doble toque o un reintento tras corte de red reutiliza el MISMO id → la base no duplica.
 * - Si cambian los datos, se genera un id nuevo.
 * - Con respuesta (aplicada o rechazada) el id se descarta: el próximo envío es otro comando.
 * - Los rechazos vuelven como { ok:false, code, message } para mostrarlos en la pantalla que los originó.
 */
export function useCommand() {
  const pendingRef = useRef(null) // { key, id }
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const run = useCallback(async (type, payload = {}, expectedRevision = null) => {
    const key = JSON.stringify([type, payload, expectedRevision])
    if (!pendingRef.current || pendingRef.current.key !== key) pendingRef.current = { key, id: newId() }
    const { id } = pendingRef.current
    setBusy(true)
    setError(null)
    try {
      const { data, error: err } = await supabase.rpc('run_command', {
        p_command_id: id, p_type: type, p_payload: payload, p_expected_revision: expectedRevision,
      })
      if (err) {
        const e = humanError(err)
        // Error de red: se conserva el id para reintentar sin duplicar.
        if (!/conexión/.test(e.message)) pendingRef.current = null
        setError({ code: 'error', message: e.message, retryable: /conexión/.test(e.message) })
        return { ok: false, code: 'error', message: e.message }
      }
      pendingRef.current = null
      if (!data?.ok) setError({ code: data?.code, message: data?.message || 'No se pudo completar.', detail: data?.detail })
      return data
    } finally {
      setBusy(false)
    }
  }, [])

  return { run, busy, error, setError, clearError: () => setError(null) }
}
