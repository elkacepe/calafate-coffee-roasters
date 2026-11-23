#!/usr/bin/env bash
# Corre migraciones + semilla + pruebas contra un Postgres local vacío (sin Supabase).
# Requiere psql. Uso: DB_URL=postgresql://postgres@localhost:5432/calafate_test ./scripts/test-db-local.sh
set -euo pipefail
: "${DB_URL:?Definí DB_URL apuntando a una base VACÍA de prueba}"
P=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)
"${P[@]}" -f supabase/tests/00_local_supabase_mock.sql
for f in supabase/migrations/*.sql; do "${P[@]}" -f "$f"; done
"${P[@]}" -f supabase/seed.sql
"${P[@]}" -f supabase/tests/10_dominio.sql
DB_URL="$DB_URL" ./supabase/tests/20_concurrencia.sh
"${P[@]}" -f supabase/seed.sql   # deja la semilla limpia
