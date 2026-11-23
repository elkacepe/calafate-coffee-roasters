import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY

export const supabaseConfigured = Boolean(url && key && !url.includes('tu-proyecto'))

// Solo URL + clave pública. La service_role nunca llega al navegador.
export const supabase = createClient(url || 'http://localhost:54321', key || 'falta-clave', {
  auth: { persistSession: true, autoRefreshToken: true },
})

/** Llama a una función RPC y devuelve data o lanza un Error con texto legible. */
export async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw humanError(error)
  return data
}

export function humanError(error) {
  const msg = error?.message || String(error)
  if (/Failed to fetch|NetworkError|fetch failed/i.test(msg))
    return new Error('No hay conexión. Revisá internet y volvé a intentar: no se perdió nada de lo que cargaste.')
  if (/permission|permiso|42501/i.test(msg)) return new Error('No tenés permiso para esta acción.')
  if (/JWT|token/i.test(msg)) return new Error('Tu sesión venció. Volvé a ingresar.')
  return new Error(msg)
}
