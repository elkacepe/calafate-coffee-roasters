// Une migraciones + semilla en supabase/setup_completo.sql para pegar en el SQL Editor de Supabase.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
const dir = 'supabase/migrations'
const parts = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => `-- >>> ${f}\n` + readFileSync(`${dir}/${f}`, 'utf8'))
parts.push('-- >>> seed.sql\n' + readFileSync('supabase/seed.sql', 'utf8'))
writeFileSync('supabase/setup_completo.sql', '-- GENERADO por scripts/build-setup-sql.mjs: no editar a mano.\n' + parts.join('\n\n'))
console.log('supabase/setup_completo.sql listo')
