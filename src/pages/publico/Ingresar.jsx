import { useState } from 'react'
import { Navigate, useSearchParams } from 'react-router-dom'
import { supabase, supabaseConfigured } from '../../lib/supabase'
import { useAuth, HOME } from '../../auth/AuthProvider'
import { Button, Card, Field, H1, Input, Notice } from '../../components/ui'

const DEMO = [
  ['admin@calafate.test', 'Administración'], ['barra@calafate.test', 'Barra'], ['tostaduria@calafate.test', 'Tostaduría y depósito'],
  ['reparto@calafate.test', 'Reparto'], ['hotel@calafate.test', 'Mayorista · Hotel Lenga Azul'], ['resto@calafate.test', 'Mayorista · Restó Fogón del Ñire'],
]

export default function Ingresar() {
  const { session, role } = useAuth()
  const [sp] = useSearchParams()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  if (session && role) return <Navigate to={sp.get('volver') || HOME[role]} replace />

  async function submit(e) {
    e.preventDefault()
    setBusy(true); setErr(null)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (error) setErr(/Invalid login/i.test(error.message) ? 'El correo o la contraseña no coinciden.' : error.message)
  }
  return (
    <div className="mx-auto max-w-md">
      <H1>Ingreso</H1>
      <p className="mt-1 text-sm">Para el equipo y los clientes mayoristas. Si comprás en la web no necesitás cuenta.</p>
      {!supabaseConfigured && <Notice tone="warn" className="mt-4">Falta configurar Supabase: copiá <code>.env.example</code> como <code>.env.local</code>.</Notice>}
      <form onSubmit={submit} className="mt-5 space-y-4">
        <Field label="Correo"><Input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label="Contraseña"><Input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
        {err && <Notice tone="warn">{err}</Notice>}
        <Button size="lg" className="w-full" busy={busy}>Ingresar</Button>
      </form>
      <Card className="mt-6 text-sm">
        <div className="font-medium">Cuentas de prueba</div>
        <div className="text-xs text-cafe/70">Contraseña de todas: <code>Calafate2026!</code></div>
        <ul className="mt-2 space-y-1">
          {DEMO.map(([e, r]) => (
            <li key={e}><button type="button" className="text-left underline underline-offset-2" onClick={() => { setEmail(e); setPassword('Calafate2026!') }}>{e}</button> <span className="text-cafe/60">· {r}</span></li>
          ))}
        </ul>
      </Card>
    </div>
  )
}
