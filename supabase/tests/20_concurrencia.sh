#!/usr/bin/env bash
# =====================================================================
# Pruebas de concurrencia con DOS sesiones reales de Postgres.
# Escribe datos de prueba (fixture "Concurrencia"): correlo contra una base de
# prueba y después volvé a cargar supabase/seed.sql.
# Uso: DB_URL="postgresql://postgres:...@host:5432/postgres" ./supabase/tests/20_concurrencia.sh
# =====================================================================
set -euo pipefail
: "${DB_URL:?Definí DB_URL}"
PSQL=(psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1)
ADMIN='{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}'
fail() { echo "FALLÓ: $*"; exit 1; }
ok() { echo "ok · $*"; }

as_admin="select set_config('request.jwt.claims', '$ADMIN', false);"

# ---------- Fixture: un origen con exactamente 2 kg vendibles a mayoristas ----------
COFFEE=$("${PSQL[@]}" <<SQL | tail -1
$as_admin
select set_config('app.now', (now() - interval '2 days')::text, false);
do \$\$
declare g uuid; c uuid;
begin
  insert into public.green_coffees (name, country, region, process, cost_per_kg)
  values ('Concurrencia ' || now()::text, 'Testlandia', 'Fixture', 'Lavado', 20000) returning id into g;
  insert into public.coffees (name, kind, green_id, sort) values ('Concurrencia ' || now()::text, 'origen', g, 99) returning id into c;
  insert into public.price_items (list_id, coffee_id, presentation, price, valid_from)
  select id, c, 'kg_grano', 30000, date '2020-01-01' from public.price_lists where kind = 'mayorista';
  perform public.run_command(gen_random_uuid(), 'ingresar_verde', jsonb_build_object('verde_id', g, 'gramos', 2353));
  perform public.run_command(gen_random_uuid(), 'registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 2353, 'tostado_g', 2000));
  perform set_config('test.coffee', c::text, false);
end \$\$;
select current_setting('test.coffee');
SQL
)
[ -n "$COFFEE" ] || fail "no se creó la fixture"
"${PSQL[@]}" -c "select set_config('app.now','',false)" >/dev/null

order_payload() { # $1 cliente
  echo "jsonb_build_object('cliente_id','$1','confirmar',true,'items',jsonb_build_array(jsonb_build_object('cafe_id','$COFFEE','presentacion','kg_grano','cantidad',2)))"
}

# ---------- 1. Dos sesiones intentan el último recurso ----------
A=$(mktemp); B=$(mktemp)
"${PSQL[@]}" > "$A" <<SQL &
begin;
$as_admin
select public.run_command(gen_random_uuid(), 'crear_pedido_mayorista', $(order_payload 10000000-0000-4000-a000-000000000003)) ->> 'ok';
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
"${PSQL[@]}" > "$B" <<SQL &
begin;
$as_admin
select (public.run_command(gen_random_uuid(), 'crear_pedido_mayorista', $(order_payload 10000000-0000-4000-a000-000000000006)) ->> 'code');
commit;
SQL
PID_B=$!
wait $PID_A $PID_B
RA=$(grep -v '^$' "$A" | grep -E 'true|false' | tail -1); RB=$(grep -v '^$' "$B" | tail -1)
[ "$RA" = "true" ] || fail "la sesión A debía reservar ($RA)"
[ "$RB" = "stock_insuficiente" ] || fail "la sesión B debía recibir conflicto de stock ($RB)"
TOTAL=$("${PSQL[@]}" -c "select coalesce(sum(a.grams),0) from public.order_allocations a join public.roast_batches b on b.id = a.lot_id where b.coffee_id = '$COFFEE' and a.state = 'reservada'")
[ "$TOTAL" = "2000" ] || fail "se reservaron $TOTAL g (esperado 2000)"
ok "dos sesiones por los últimos 2 kg: una reserva, la otra recibe «stock_insuficiente» y el lote no queda negativo"

# ---------- 2. Dos sesiones confirman la misma revisión ----------
DRAFT=$("${PSQL[@]}" <<SQL | tail -1
$as_admin
select public.run_command(gen_random_uuid(), 'crear_pedido_mayorista', jsonb_build_object('cliente_id','10000000-0000-4000-a000-000000000006',
  'items', jsonb_build_array(jsonb_build_object('cafe_id',(select id from public.coffees where kind='blend'),'presentacion','kg_grano','cantidad',2)))) ->> 'pedido_id';
SQL
)
"${PSQL[@]}" > "$A" <<SQL &
begin;
$as_admin
select public.run_command(gen_random_uuid(), 'confirmar_pedido', jsonb_build_object('pedido_id','$DRAFT'), 1) ->> 'ok';
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
"${PSQL[@]}" > "$B" <<SQL &
$as_admin
select public.run_command(gen_random_uuid(), 'confirmar_pedido', jsonb_build_object('pedido_id','$DRAFT'), 1) ->> 'code';
SQL
PID_B=$!
wait $PID_A $PID_B
RA=$(grep -E 'true|false' "$A" | tail -1); RB=$(grep -v '^$' "$B" | tail -1)
[ "$RA" = "true" ] && [ "$RB" = "revision_desactualizada" ] || fail "misma revisión: A=$RA B=$RB"
N=$("${PSQL[@]}" -c "select count(*) from public.order_allocations a join public.order_lines l on l.id = a.order_line_id where l.order_id = '$DRAFT'")
EV=$("${PSQL[@]}" -c "select count(*) from public.domain_events where entity_id = '$DRAFT' and event_type = 'pedido_confirmado'")
[ "$EV" = "1" ] || fail "eventos de confirmación: $EV"
ok "misma revisión confirmada por dos sesiones: una aplica ($N reserva/s, 1 evento), la otra recibe «revision_desactualizada»"

# ---------- 3. Mismo id de comando en paralelo ----------
CMD=$(cat /proc/sys/kernel/random/uuid)
PAY="jsonb_build_object('cliente_id','10000000-0000-4000-a000-000000000002','monto',1000,'metodo','efectivo','referencia','concurrencia')"
"${PSQL[@]}" > "$A" <<SQL &
begin;
$as_admin
select public.run_command('$CMD', 'registrar_pago', $PAY) ->> 'ok';
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
"${PSQL[@]}" > "$B" <<SQL &
$as_admin
select coalesce(public.run_command('$CMD', 'registrar_pago', $PAY) ->> 'repetido', 'false');
SQL
PID_B=$!
wait $PID_A $PID_B
RB=$(grep -v '^$' "$B" | tail -1)
N=$("${PSQL[@]}" -c "select count(*) from public.account_movements where command_id = '$CMD'")
[ "$N" = "1" ] && [ "$RB" = "true" ] || fail "mismo id en paralelo: movimientos=$N repetido=$RB"
ok "mismo id en dos sesiones: un solo pago; la segunda recibe el resultado guardado"

# ---------- 4. Se corta la respuesta después del commit y se reintenta ----------
CMD=$(cat /proc/sys/kernel/random/uuid)
"${PSQL[@]}" >/dev/null <<SQL
$as_admin
select public.run_command('$CMD', 'registrar_pago', $PAY);
SQL
# (la respuesta "se perdió": otra conexión reintenta el mismo id)
R=$("${PSQL[@]}" <<SQL | tail -1
$as_admin
select (public.run_command('$CMD', 'registrar_pago', $PAY) ->> 'repetido');
SQL
)
N=$("${PSQL[@]}" -c "select count(*) from public.account_movements where command_id = '$CMD'")
[ "$R" = "true" ] && [ "$N" = "1" ] || fail "reintento tras corte: repetido=$R movimientos=$N"
R=$("${PSQL[@]}" <<SQL | tail -1
$as_admin
select public.run_command('$CMD', 'registrar_pago', jsonb_build_object('cliente_id','10000000-0000-4000-a000-000000000002','monto',9999,'metodo','efectivo')) ->> 'code';
SQL
)
N=$("${PSQL[@]}" -c "select count(*) from public.account_movements where command_id = '$CMD'")
[ "$R" = "comando_conflicto" ] && [ "$N" = "1" ] || fail "payload distinto: $R / $N"
ok "reintento tras perder la respuesta devuelve el resultado guardado; con otro payload es conflicto sin escrituras"

rm -f "$A" "$B"
echo "Todas las pruebas de concurrencia pasaron. Volvé a cargar supabase/seed.sql para limpiar la fixture."
