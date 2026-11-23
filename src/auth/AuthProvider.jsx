import { createContext, useContext, useEffect, useState } from 'react'
import { supabase, supabaseConfigured } from '../lib/supabase'

const Ctx = createContext(null)
export const HOME = { admin: '/admin', barra: '/barra', tostaduria: '/tostaduria', reparto: '/reparto', mayorista: '/mayorista' }

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (!supabaseConfigured) { setReady(true); return }
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    let cancel = false
    async function load() {
      if (!session) { setProfile(null); setReady(true); return }
      // El rol se lee de la tabla profiles (RLS: solo el propio perfil). Nunca se elige desde un formulario.
      const { data } = await supabase.from('profiles').select('id, role, full_name, customer_id').eq('id', session.user.id).maybeSingle()
      if (!cancel) { setProfile(data); setReady(true) }
    }
    setReady(false)
    load()
    return () => { cancel = true }
  }, [session])

  const signOut = () => supabase.auth.signOut()
  return <Ctx.Provider value={{ session, profile, role: profile?.role, ready, signOut }}>{children}</Ctx.Provider>
}

export const useAuth = () => useContext(Ctx)
