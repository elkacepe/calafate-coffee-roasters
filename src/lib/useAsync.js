import { useCallback, useEffect, useState } from 'react'

/** Carga datos y expone reload(): las pantallas lo usan para «Actualizar datos». */
export function useAsync(fn, deps = []) {
  const [state, setState] = useState({ data: null, error: null, loading: true })
  const load = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: null }))
    try {
      const data = await fn()
      setState({ data, error: null, loading: false })
    } catch (e) {
      setState({ data: null, error: e.message || String(e), loading: false })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(() => { load() }, [load])
  return { ...state, reload: load }
}
