-- =====================================================================
-- Pruebas de dominio y casos adversos (Postgres). Cada bloque corre en una
-- transacción que se revierte: la semilla queda intacta.
-- Uso:  psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/10_dominio.sql
-- Si una afirmación falla, el script se detiene con «FALLÓ: …».
-- =====================================================================
\set QUIET on
\pset pager off

create or replace function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALLÓ: %', p_msg; end if;
  raise notice 'ok · %', p_msg;
end $$;
create or replace function pg_temp.as_user(p_id text) returns void language sql as $$
  select set_config('request.jwt.claims', case when p_id is null then '' else json_build_object('sub', p_id, 'role', 'authenticated')::text end, false) $$;
create or replace function pg_temp.admin() returns void language sql as $$ select pg_temp.as_user('00000000-0000-4000-a000-000000000001') $$;
create or replace function pg_temp.cmd(p_type text, p jsonb, p_rev int default null) returns jsonb language sql as $$
  select public.run_command(gen_random_uuid(), p_type, p, p_rev) $$;
create or replace function pg_temp.at(p_ts timestamptz) returns void language sql as $$ select set_config('app.now', p_ts::text, false) $$;
-- Fixture aislada: un origen de prueba con precio público y mayorista.
create or replace function pg_temp.fixture(p_name text, p_green_g int, p_cost bigint default 20000) returns uuid language plpgsql as $$
declare g uuid; c uuid;
begin
  insert into public.green_coffees (name, country, region, process, cost_per_kg) values (p_name, 'Testlandia', 'Fixture', 'Lavado', p_cost) returning id into g;
  insert into public.coffees (name, kind, green_id, sort) values (p_name, 'origen', g, 99) returning id into c;
  insert into public.price_items (list_id, coffee_id, presentation, price, valid_from)
  select pl.id, c, v.pres, v.price, date '2020-01-01' from public.price_lists pl
  join (values ('Público','bolsa_250',10000), ('Público','bolsa_1000',36000), ('Gastronomía A','kg_grano',30000),
               ('Gastronomía A','kg_molido',31000), ('Gastronomía B','kg_grano',32000), ('Gastronomía B','kg_molido',33000)) v(l, pres, price)
    on v.l = pl.name;
  if p_green_g > 0 then perform pg_temp.cmd('ingresar_verde', jsonb_build_object('verde_id', g, 'gramos', p_green_g)); end if;
  return c;
end $$;
create or replace function pg_temp.lot_of(p_coffee uuid) returns record language sql as $$
  select s from private.lot_stock_rows(p_coffee) s order by roasted_at desc limit 1 $$;

-- ---------------------------------------------------------------------
\echo '13 · Café tostado por lote y unidad base: 1.000 g verdes → 850 g → vender 250 deja 600'
begin;
do $$
declare c uuid; r jsonb; s record; g uuid;
begin
  perform pg_temp.admin();
  perform pg_temp.at(now() - interval '2 days');
  c := pg_temp.fixture('Fixture 1000', 1000);
  select green_id into g from public.coffees where id = c;
  r := pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 1000, 'tostado_g', 850));
  perform pg_temp.ok((r ->> 'ok')::boolean and (r ->> 'merma_pct')::numeric = 15, 'rendimiento 85 % → merma 15 %');
  perform pg_temp.ok(private.green_stock(g) = 0, 'el verde baja a 0 g (no quedan 1.000 g disponibles)');
  select * into s from private.lot_stock_rows(c);
  perform pg_temp.ok(s.on_hand_g = 850 and s.status = 'En reposo', 'entran 850 g tostados y el lote queda En reposo');
  perform pg_temp.at(now());
  update public.roast_batches set wholesale_block_pct = 0 where coffee_id = c;   -- fixture sin bloqueo mayorista
  r := pg_temp.cmd('crear_pedido_web', jsonb_build_object('nombre', 'Prueba', 'celular', '2966000000', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'bolsa_250', 'cantidad', 1))));
  perform pg_temp.ok((r ->> 'ok')::boolean, 'venta de 250 g confirmada');
  select * into s from private.lot_stock_rows(c);
  perform pg_temp.ok(s.available_g = 600 and s.reserved_g = 250 and s.on_hand_g = 850, 'disponible 600 g (850 en mano − 250 reservados)');
  perform private.consume_order_allocations((r ->> 'pedido_id')::uuid, null);
  select * into s from private.lot_stock_rows(c);
  perform pg_temp.ok(s.available_g = 600 and s.on_hand_g = 600 and s.reserved_g = 0, 'al entregar: 600 en mano, 0 reservado, 600 disponibles');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '2 · Tueste y merma: fuera de 12–20 % pide motivo'
begin;
do $$
declare c uuid; r jsonb; n int;
begin
  perform pg_temp.admin();
  c := pg_temp.fixture('Fixture merma', 10000);
  select count(*) into n from public.roast_batches;
  r := pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 5000, 'tostado_g', 3500));
  perform pg_temp.ok(r ->> 'code' = 'merma_fuera_de_rango' and (r -> 'detail' ->> 'merma')::numeric = 30, 'merma 30 % rechazada sin motivo');
  perform pg_temp.ok((select count(*) from public.roast_batches) = n and private.green_stock((select green_id from public.coffees where id = c)) = 10000,
    'sin lote ni descuento de verde tras el rechazo');
  r := pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 5000, 'tostado_g', 3500, 'motivo', 'Prueba de tueste oscuro'));
  perform pg_temp.ok((r ->> 'ok')::boolean, 'con motivo se registra');
  r := pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 9000, 'tostado_g', 7600));
  perform pg_temp.ok(r ->> 'code' = 'verde_insuficiente', 'no se tuesta más verde del que hay');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '3 · Reposo 24 h y Solo barra a los 30 días'
begin;
do $$
declare c uuid; r jsonb; v_lot uuid; s record;
begin
  perform pg_temp.admin();
  c := pg_temp.fixture('Fixture reposo', 20000);
  update public.wholesale_customers set credit_limit = 10000000 where id = '10000000-0000-4000-a000-000000000005';
  r := pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 10000, 'tostado_g', 8500));
  v_lot := (r ->> 'lote_id')::uuid;
  r := pg_temp.cmd('crear_pedido_web', jsonb_build_object('nombre', 'Prueba', 'celular', '2966000000', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'bolsa_250', 'cantidad', 1))));
  perform pg_temp.ok(r ->> 'code' = 'stock_insuficiente' and r ->> 'message' like '%reposo%', 'lote en reposo no se reserva: ' || (r ->> 'message'));
  perform pg_temp.at(now() + interval '23 hours');
  perform pg_temp.ok((select status from private.lot_stock_rows(null, v_lot)) = 'En reposo', 'a las 23 h sigue en reposo');
  perform pg_temp.at(now() + interval '24 hours 1 minute');
  r := pg_temp.cmd('crear_pedido_mayorista', jsonb_build_object('cliente_id', '10000000-0000-4000-a000-000000000005', 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'kg_grano', 'cantidad', 2))));
  perform pg_temp.ok((r ->> 'ok')::boolean, 'a las 24 h ya se reserva');
  perform pg_temp.at(now() + interval '30 days 1 hour');
  perform public.refresh_lot_states();
  perform pg_temp.ok((select status from public.roast_batches where id = v_lot) = 'Solo barra', 'pasa a Solo barra (estado persistido con evento)');
  perform pg_temp.ok(exists (select 1 from public.domain_events where entity_id = v_lot and to_state = 'Solo barra'), 'evento de cambio por tiempo');
  r := pg_temp.cmd('crear_pedido_web', jsonb_build_object('nombre', 'Prueba', 'celular', '2966000000', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'bolsa_250', 'cantidad', 1))));
  perform pg_temp.ok(r ->> 'code' = 'stock_insuficiente', 'Solo barra: no acepta bolsas');
  r := pg_temp.cmd('crear_pedido_mayorista', jsonb_build_object('cliente_id', '10000000-0000-4000-a000-000000000005', 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'kg_grano', 'cantidad', 2))));
  perform pg_temp.ok(r ->> 'code' = 'stock_insuficiente', 'Solo barra: no acepta mayoristas');
  perform pg_temp.ok((select reserved_g from private.lot_stock_rows(null, v_lot)) = 2000, 'la reserva pendiente previa se mantiene');
  select * into s from private.lot_stock_rows(null, v_lot);
  perform pg_temp.ok(s.barra_available_g = s.available_g and s.barra_available_g > 0, 'en barra sí se puede usar');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '4 · Barra: receta descuenta café y leche; cierre con diferencia exige motivo'
begin;
do $$
declare t uuid; v_lot uuid; before_g int; before_milk int; r jsonb; v_rev int; v_exp bigint;
begin
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000002');
  select id, lot_id, revision into t, v_lot, v_rev from public.bar_shifts where status = 'abierto';
  select on_hand_g into before_g from private.lot_stock_rows(null, v_lot);
  before_milk := private.supply_stock((select id from public.supplies where code = 'leche'));
  r := pg_temp.cmd('vender_barra', jsonb_build_object('turno_id', t, 'metodo', 'efectivo',
    'items', jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Espresso doble'), 'cantidad', 1),
                               jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Flat white'), 'cantidad', 1))));
  perform pg_temp.ok((r ->> 'ok')::boolean and (r ->> 'total')::bigint = 10800, 'ticket doble + flat white = $10.800');
  perform pg_temp.ok((select on_hand_g from private.lot_stock_rows(null, v_lot)) = before_g - 36, 'descuenta 18 g + 18 g del lote del turno');
  perform pg_temp.ok(private.supply_stock((select id from public.supplies where code = 'leche')) = before_milk - 120, 'descuenta 120 ml de leche');
  v_exp := private.shift_expected_cash(t);
  r := pg_temp.cmd('cerrar_caja', jsonb_build_object('turno_id', t, 'contado', v_exp - 2500), v_rev);
  perform pg_temp.ok(r ->> 'code' = 'motivo_requerido' and (r -> 'detail' ->> 'diferencia')::bigint = -2500, 'diferencia de $2.500 exige motivo');
  perform pg_temp.ok((select status from public.bar_shifts where id = t) = 'abierto', 'la caja sigue abierta tras el rechazo');
  r := pg_temp.cmd('cerrar_caja', jsonb_build_object('turno_id', t, 'contado', v_exp - 1500), v_rev);
  perform pg_temp.ok((r ->> 'ok')::boolean and (r ->> 'diferencia')::bigint = -1500, 'diferencia de $1.500 cierra sin motivo');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '5 · Reparto: capacidad 40 kg, no entregado conserva reserva, 2º fallo pide decisión'
begin;
do $$
declare c uuid; r jsonb; v_route uuid; v_o1 uuid; v_o2 uuid; st uuid; v_res int; v_route2 uuid;
begin
  perform pg_temp.admin();
  perform pg_temp.at(now() - interval '2 days');
  c := pg_temp.fixture('Fixture reparto', 80000);
  perform pg_temp.cmd('registrar_tueste', jsonb_build_object('cafe_id', c, 'verde_g', 60000, 'tostado_g', 51000));
  perform pg_temp.at(now());
  update public.wholesale_customers set credit_limit = 10000000 where id = '10000000-0000-4000-a000-000000000002';
  v_o1 := (pg_temp.cmd('crear_pedido_mayorista', jsonb_build_object('cliente_id', '10000000-0000-4000-a000-000000000002', 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'kg_grano', 'cantidad', 35)))) ->> 'pedido_id')::uuid;
  v_o2 := (pg_temp.cmd('crear_pedido_mayorista', jsonb_build_object('cliente_id', '10000000-0000-4000-a000-000000000002', 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', c, 'presentacion', 'kg_grano', 'cantidad', 6)))) ->> 'pedido_id')::uuid;
  perform pg_temp.cmd('cambiar_estado_pedido', jsonb_build_object('pedido_id', o, 'a', 'En preparación'), (select revision from public.orders where id = o)) from unnest(array[v_o1, v_o2]) o;
  perform pg_temp.cmd('cambiar_estado_pedido', jsonb_build_object('pedido_id', o, 'a', 'Listo'), (select revision from public.orders where id = o)) from unnest(array[v_o1, v_o2]) o;
  v_route := (pg_temp.cmd('crear_recorrido', jsonb_build_object('fecha', current_date + 3, 'zona_id', (select id from public.zones where name = 'Costanera'),
    'franja', '10-13', 'repartidor_id', '00000000-0000-4000-a000-000000000004')) ->> 'recorrido_id')::uuid;
  r := pg_temp.cmd('asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route, 'pedido_id', v_o1), 1);
  perform pg_temp.ok((r ->> 'ok')::boolean, '35 kg entran');
  r := pg_temp.cmd('asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route, 'pedido_id', v_o2), 2);
  perform pg_temp.ok(r ->> 'code' = 'capacidad_superada', '35 + 6 kg superan 40 kg: ' || (r ->> 'message'));
  perform pg_temp.ok(private.route_load_g(v_route) = 35000, 'la carga queda en 35 kg');

  perform pg_temp.cmd('iniciar_recorrido', jsonb_build_object('recorrido_id', v_route), 2);
  select id into st from public.route_stops where order_id = v_o1;
  select sum(a.grams) into v_res from public.order_allocations a join public.order_lines l on l.id = a.order_line_id where l.order_id = v_o1 and a.state = 'reservada';
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000004');
  r := pg_temp.cmd('registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'no_entregado', 'nota', 'Cocina cerrada'), (select revision from public.orders where id = v_o1));
  perform pg_temp.ok(r ->> 'estado' = 'Para reprogramar', 'no entregado → Para reprogramar');
  perform pg_temp.ok((select sum(a.grams) from public.order_allocations a join public.order_lines l on l.id = a.order_line_id
                       where l.order_id = v_o1 and a.state = 'reservada') = v_res, 'la reserva queda intacta (35 kg)');
  perform pg_temp.admin();
  v_route2 := (pg_temp.cmd('crear_recorrido', jsonb_build_object('fecha', current_date + 4, 'zona_id', (select id from public.zones where name = 'Costanera'),
    'franja', '10-13', 'repartidor_id', '00000000-0000-4000-a000-000000000004')) ->> 'recorrido_id')::uuid;
  perform pg_temp.cmd('asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route2, 'pedido_id', v_o1), 1);
  perform pg_temp.cmd('iniciar_recorrido', jsonb_build_object('recorrido_id', v_route2), 2);
  select id into st from public.route_stops where order_id = v_o1 and result = 'pendiente';
  r := pg_temp.cmd('registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'no_entregado', 'nota', 'Otra vez cerrado'), (select revision from public.orders where id = v_o1));
  perform pg_temp.ok((r ->> 'intentos_fallidos')::int = 2, 'segundo intento fallido registrado');
  v_route := (pg_temp.cmd('crear_recorrido', jsonb_build_object('fecha', current_date + 5, 'zona_id', (select id from public.zones where name = 'Costanera'),
    'franja', '10-13')) ->> 'recorrido_id')::uuid;
  r := pg_temp.cmd('asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route, 'pedido_id', v_o1), 1);
  perform pg_temp.ok(r ->> 'code' = 'decision_admin', 'tras 2 fallos administración decide');
  r := pg_temp.cmd('cancelar_pedido', jsonb_build_object('pedido_id', v_o1, 'motivo', 'Dos intentos fallidos'), (select revision from public.orders where id = v_o1));
  perform pg_temp.ok((r ->> 'reservas_liberadas')::int >= 1 and not exists (select 1 from public.order_allocations a join public.order_lines l on l.id = a.order_line_id
                       where l.order_id = v_o1 and a.state = 'reservada'), 'cancelar libera la reserva');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '6 · Devoluciones: cerrada vuelve al lote; mal sellada es merma; plazo 7 días'
begin;
do $$
declare v_ret uuid; v_lot uuid; before_g int; r jsonb; v_waste int; v_o uuid;
begin
  perform pg_temp.admin();
  -- devolución 505 (Hostería Piedra Gris, bolsa cerrada, En revisión)
  select id into v_ret from public.returns where number = 505;
  v_lot := ((select lot_splits -> 0 ->> 'lot_id' from public.returns where id = v_ret))::uuid;
  select on_hand_g into before_g from private.lot_stock_rows(null, v_lot);
  r := pg_temp.cmd('decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'nota_credito'),
    (select revision from public.returns where id = v_ret));
  perform pg_temp.ok((r ->> 'ok')::boolean and r ->> 'estado' = 'Resuelta', 'aceptada con nota de crédito → Resuelta');
  perform pg_temp.ok((select on_hand_g from private.lot_stock_rows(null, v_lot)) = before_g + 1000, 'bolsa cerrada: +1 kg al mismo lote');
  -- devolución 506 (Bodegón, defectuosa)
  select id into v_ret from public.returns where number = 506;
  v_lot := ((select lot_splits -> 0 ->> 'lot_id' from public.returns where id = v_ret))::uuid;
  select on_hand_g into before_g from private.lot_stock_rows(null, v_lot);
  select coalesce(sum(grams), 0) into v_waste from public.waste_records;
  r := pg_temp.cmd('decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'nota_credito'),
    (select revision from public.returns where id = v_ret));
  perform pg_temp.ok((select on_hand_g from private.lot_stock_rows(null, v_lot)) = before_g, 'defectuosa: no vuelve al stock');
  perform pg_temp.ok((select sum(grams) from public.waste_records) = v_waste + 1000, 'defectuosa: se registra 1 kg de merma');
  -- fuera de plazo
  select id into v_o from public.orders where number = 1001;
  r := pg_temp.cmd('pedir_devolucion', jsonb_build_object('pedido_id', v_o, 'linea_id', (select id from public.order_lines where order_id = v_o),
    'bolsas', 1, 'condicion', 'cerrada', 'motivo', 'Quiero devolverla'));
  perform pg_temp.ok(r ->> 'code' = 'fuera_de_plazo', 'más de 7 días desde la entrega: rechazada');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '7/8/12 · Caso de aceptación del hotel Lenga Azul (retenido → pago → reserva → merma + NC)'
begin;
do $$
declare v_c constant uuid := '10000000-0000-4000-a000-000000000001'; v_o uuid; r jsonb; v_pay uuid := gen_random_uuid();
        v_n int; v_route uuid; st uuid; v_ret uuid; v_order_total bigint; v_oldest timestamptz; v_lot_used text;
begin
  perform pg_temp.admin();
  select id into v_o from public.orders where customer_id = v_c and status = 'Retenido';
  perform pg_temp.ok(v_o is not null and (select hold_reason from public.orders where id = v_o) = 'deuda_vencida', 'el lunes a las 8 el recurrente quedó Retenido por deuda vencida');
  perform pg_temp.ok(not exists (select 1 from public.order_allocations a join public.order_lines l on l.id = a.order_line_id where l.order_id = v_o),
    'retenido: esos 6 kg siguen disponibles para el resto (sin reservas)');
  perform pg_temp.ok((private.credit_status(v_c) ->> 'dias_vencido')::int = 18, 'deuda vencida hace 18 días');
  -- No puede confirmar pedidos nuevos
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000005');
  r := pg_temp.cmd('crear_pedido_mayorista', jsonb_build_object('confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'kg_grano', 'cantidad', 2))));
  perform pg_temp.ok(r ->> 'code' = 'mayorista_bloqueado', 'el hotel no puede confirmar pedidos nuevos: ' || (r ->> 'message'));
  -- Pago que cancela la deuda (y su repetición no duplica)
  perform pg_temp.admin();
  r := public.run_command(v_pay, 'registrar_pago', jsonb_build_object('cliente_id', v_c, 'monto', 264000, 'metodo', 'transferencia'));
  perform pg_temp.ok((r ->> 'saldo')::bigint = 0, 'pago registrado, saldo $0');
  r := public.run_command(v_pay, 'registrar_pago', jsonb_build_object('cliente_id', v_c, 'monto', 264000, 'metodo', 'transferencia'));
  perform pg_temp.ok((r ->> 'repetido')::boolean and (select count(*) from public.account_movements where command_id = v_pay) = 1,
    'repetir la confirmación del pago no lo duplica');
  -- Liberar → reserva del lote disponible más antiguo
  r := pg_temp.cmd('liberar_retenido', jsonb_build_object('pedido_id', v_o), (select revision from public.orders where id = v_o));
  perform pg_temp.ok(r ->> 'estado' = 'Confirmado', 'administración libera y queda Confirmado');
  select min(s.roasted_at) into v_oldest from private.lot_stock_rows((select id from public.coffees where kind = 'blend')) s
   where s.lot_id in (select a.lot_id from public.order_allocations a join public.order_lines l on l.id = a.order_line_id where l.order_id = v_o);
  perform pg_temp.ok(v_oldest = (select min(b.roasted_at) from public.roast_batches b join public.order_allocations a on a.lot_id = b.id
                                  join public.order_lines l on l.id = a.order_line_id where l.order_id = v_o), 'reserva FIFO desde el lote más antiguo');
  perform pg_temp.ok((select sum(a.grams) from public.order_allocations a join public.order_lines l on l.id = a.order_line_id
                       where l.order_id = v_o and a.state = 'reservada') = 6000, 'reservó 6 kg');
  v_order_total := (select total from public.orders where id = v_o);
  -- Entrega con una bolsa de 1 kg mal sellada rechazada en la puerta
  perform pg_temp.cmd('cambiar_estado_pedido', jsonb_build_object('pedido_id', v_o, 'a', 'En preparación'), (select revision from public.orders where id = v_o));
  perform pg_temp.cmd('cambiar_estado_pedido', jsonb_build_object('pedido_id', v_o, 'a', 'Listo'), (select revision from public.orders where id = v_o));
  select id into v_route from public.routes where route_date = private.today() and slot = '15-18';
  r := pg_temp.cmd('asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route, 'pedido_id', v_o), (select revision from public.routes where id = v_route));
  perform pg_temp.ok((r ->> 'ok')::boolean, 'entra en el recorrido de la zona hotelera');
  perform pg_temp.cmd('iniciar_recorrido', jsonb_build_object('recorrido_id', v_route), (select revision from public.routes where id = v_route));
  select id into st from public.route_stops where order_id = v_o and result = 'pendiente';
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000004');
  r := pg_temp.cmd('registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'entregado',
    'rechazos', jsonb_build_array(jsonb_build_object('linea_id', (select id from public.order_lines where order_id = v_o), 'bolsas', 1,
      'condicion', 'mal_sellada', 'motivo', 'Bolsa mal sellada'))), (select revision from public.orders where id = v_o));
  perform pg_temp.ok(r ->> 'estado' = 'Entregado parcial', 'entregado con rechazo → Entregado parcial');
  v_ret := (r -> 'devoluciones' ->> 0)::uuid;
  perform pg_temp.admin();
  select coalesce(sum(grams), 0) into v_n from public.waste_records;
  r := pg_temp.cmd('decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'nota_credito'),
    (select revision from public.returns where id = v_ret));
  perform pg_temp.ok((select sum(grams) from public.waste_records) = v_n + 1000, 'la bolsa se registra como merma');
  perform pg_temp.ok((select -amount from public.account_movements where return_id = v_ret and kind = 'nota_credito') = 44000, 'nota de crédito por ese kilo ($44.000)');
  perform pg_temp.ok((private.credit_status(v_c) ->> 'saldo')::bigint = v_order_total - 44000,
    format('saldo final = pedido %s − NC 44000 = %s', v_order_total, v_order_total - 44000));
  perform pg_temp.ok((private.credit_status(v_c) ->> 'saldo')::bigint = (select sum(amount) from public.account_movements where customer_id = v_c),
    'el saldo coincide con la suma de sus movimientos');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '9 · Precio con vigencia futura no toca pedidos confirmados'
begin;
do $$
declare v_o uuid; v_line_price bigint; r jsonb; v_c uuid := '10000000-0000-4000-a000-000000000002';
begin
  perform pg_temp.admin();
  select o.id, l.unit_price into v_o, v_line_price from public.orders o join public.order_lines l on l.order_id = o.id
   where o.customer_id = v_c and o.status = 'Listo' and o.replacement_for_return_id is null and l.line_no = 1;
  r := pg_temp.cmd('actualizar_precio', jsonb_build_object('lista_id', (select id from public.price_lists where name = 'Gastronomía A'),
    'cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'kg_grano', 'precio', 99000, 'vigente_desde', private.today() + 3));
  perform pg_temp.ok((r ->> 'ok')::boolean, 'precio futuro cargado');
  perform pg_temp.at(now() + interval '4 days');
  perform pg_temp.ok((select unit_price from public.order_lines where order_id = v_o and line_no = 1) = v_line_price, 'la línea confirmada conserva su precio congelado');
  perform pg_temp.ok(private.current_price((select id from public.price_lists where name = 'Gastronomía A'), (select id from public.coffees where kind = 'blend'), 'kg_grano') = 99000,
    'un pedido nuevo usa el precio vigente');
  r := pg_temp.cmd('actualizar_precio', jsonb_build_object('lista_id', (select id from public.price_lists where name = 'Gastronomía A'),
    'cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'kg_grano', 'precio', 1, 'vigente_desde', '2020-01-01'));
  perform pg_temp.ok(r ->> 'code' = 'vigencia_invalida', 'no se puede cargar precio con vigencia pasada');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '10 · RLS: cada rol ve solo lo suyo, aunque cambie el id'
begin;
do $$
declare v_fogon_order uuid; n int; v_err text;
begin
  select id into v_fogon_order from public.orders where customer_id = '10000000-0000-4000-a000-000000000004' limit 1;
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000005');   -- hotel Lenga Azul
  execute 'set local role authenticated';
  select count(*) into n from public.orders where id = v_fogon_order;
  perform pg_temp.ok(n = 0, 'el hotel no ve el pedido del restó aunque pida su id');
  select count(*) into n from public.orders where customer_id <> '10000000-0000-4000-a000-000000000001';
  perform pg_temp.ok(n = 0, 'el hotel solo ve pedidos propios');
  select count(*) into n from public.order_lines l where l.order_id = v_fogon_order;
  perform pg_temp.ok(n = 0, 'tampoco ve líneas (tabla hija) ajenas');
  select count(*) into n from public.account_movements where customer_id = '10000000-0000-4000-a000-000000000004';
  perform pg_temp.ok(n = 0, 'no ve saldo ajeno');
  select count(*) into n from public.price_items pi join public.price_lists pl on pl.id = pi.list_id where pl.name <> 'Gastronomía A';
  perform pg_temp.ok(n = 0, 'solo ve su lista de precios');
  perform pg_temp.ok(public.order_detail(v_fogon_order) is null, 'order_detail de un pedido ajeno devuelve nada');
  select count(*) into n from public.roast_batches;
  perform pg_temp.ok(n = 0, 'mayorista no ve lotes');
  begin
    update public.orders set total = 1 where id = v_fogon_order;
    get diagnostics n = row_count;
    perform pg_temp.ok(false, 'update directo debería fallar');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'update directo a pedidos rechazado');
  end;
  begin
    insert into public.account_movements (customer_id, kind, amount, method) values ('10000000-0000-4000-a000-000000000001', 'pago', -999999, 'efectivo');
    perform pg_temp.ok(false, 'insert directo debería fallar');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'insert directo de un pago rechazado');
  end;
  begin
    perform public.run_command(gen_random_uuid(), 'registrar_pago', '{"cliente_id":"10000000-0000-4000-a000-000000000001","monto":1,"metodo":"efectivo"}');
    perform pg_temp.ok(false, 'pago por mayorista debería fallar');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'un mayorista no puede ejecutar registrar_pago');
  end;
  begin
    perform public.report_sales(current_date - 30, current_date);
    perform pg_temp.ok(false, 'informe por mayorista debería fallar');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'informes: solo administración');
  end;
  execute 'reset role';
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000004');   -- reparto
  execute 'set local role authenticated';
  select count(*) into n from public.orders o where not exists (select 1 from public.route_stops s join public.routes r on r.id = s.route_id
     where s.order_id = o.id and r.driver_id = '00000000-0000-4000-a000-000000000004');
  perform pg_temp.ok(n = 0, 'reparto ve solo pedidos de sus recorridos');
  select count(*) into n from public.account_movements;
  perform pg_temp.ok(n = 0, 'reparto no ve cuentas corrientes');
  execute 'reset role';
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000003');   -- tostaduría
  execute 'set local role authenticated';
  select count(*) into n from public.orders;
  perform pg_temp.ok(n = 0, 'tostaduría no ve pedidos');
  select count(*) into n from public.green_coffees;
  perform pg_temp.ok(n = 5, 'tostaduría ve el café verde');
  execute 'reset role';
  perform pg_temp.as_user(null);   -- anónimo
  execute 'set local role anon';
  begin
    select count(*) into n from public.orders;
    perform pg_temp.ok(false, 'anon no debería leer pedidos');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'anónimo no lee la tabla de pedidos');
  end;
  perform pg_temp.ok(jsonb_array_length(public.public_catalog() -> 'cafes') = 6 and not (public.public_catalog()::text like '%costo%'
     or public.public_catalog()::text like '%kg_grano%'), 'catálogo público expone solo campos autorizados');
  perform pg_temp.ok(public.track_order(1001, '0000000000') is null, 'seguimiento con celular equivocado no devuelve nada');
  perform pg_temp.ok(public.track_order(1001, '2966 41-0001') ->> 'estado' = 'Entregado', 'seguimiento con número + celular');
  execute 'reset role';
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '11/18 · Informe por canal = suma de filas; sin datos no muestra 0'
begin;
do $$
declare r jsonb; v_sum bigint; v_rows bigint; e jsonb;
begin
  perform pg_temp.admin();
  r := public.report_sales(private.today() - 60, private.today());
  select coalesce(sum((f ->> 'total')::bigint), 0) into v_rows from jsonb_array_elements(r -> 'filas') f;
  perform pg_temp.ok(v_rows = (r ->> 'total')::bigint, 'total del informe = suma de filas del CSV');
  select sum((x.value ->> 'total')::bigint) into v_sum from jsonb_each(r -> 'por_canal') x where x.value ->> 'total' is not null;
  perform pg_temp.ok(v_sum = v_rows, 'suma por canal = total');
  perform pg_temp.ok((select sum(total) from public.orders where status not in ('Borrador','Retenido','Cancelado')
                        and replacement_for_return_id is null) = v_rows, 'coincide con las ventas no anuladas de la tabla');
  e := public.report_sales(date '2001-01-01', date '2001-01-31');
  perform pg_temp.ok(e ->> 'total' is null and e -> 'por_canal' -> 'web' ->> 'ticket_promedio' is null, 'período sin datos: total y promedio nulos, no 0');
  e := public.report_waste(date '2001-01-01', date '2001-01-31');
  perform pg_temp.ok(e -> 'tueste' ->> 'merma_pct' is null, 'merma % sin lotes: nula, no 0 %');
  r := public.report_reconciliation();
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'cuentas') x where (x ->> 'diferencia')::bigint <> 0), 'conciliación de cuentas: diferencia 0');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'lotes') x where (x ->> 'en_mano_movimientos')::int <> (x ->> 'en_mano_reconstruido')::int),
    'conciliación de lotes: movimientos = reconstrucción');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'verde') x where (x ->> 'diferencia')::int <> 0), 'conciliación del verde');
  perform pg_temp.ok((r -> 'comandos' ->> 'rechazados_con_evento')::int = 0, 'ningún comando rechazado dejó eventos');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '14 · Idempotencia: mismo id + mismos datos = un efecto; otros datos = conflicto sin escrituras'
begin;
do $$
declare v_id uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; r3 jsonb; n_orders int; n_alloc int; p jsonb;
begin
  perform pg_temp.admin();
  p := jsonb_build_object('nombre', 'Idem', 'celular', '2966123456', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', (select id from public.coffees where name = 'Colombia Huila'), 'presentacion', 'bolsa_250', 'cantidad', 1)));
  r1 := public.run_command(v_id, 'crear_pedido_web', p);
  select count(*) into n_orders from public.orders; select count(*) into n_alloc from public.order_allocations;
  r2 := public.run_command(v_id, 'crear_pedido_web', p);
  perform pg_temp.ok(r2 ->> 'pedido_id' = r1 ->> 'pedido_id' and (r2 ->> 'repetido')::boolean, 'reintento devuelve el mismo resultado');
  perform pg_temp.ok((select count(*) from public.orders) = n_orders and (select count(*) from public.order_allocations) = n_alloc, 'sin pedido ni reserva duplicados');
  r3 := public.run_command(v_id, 'crear_pedido_web', p || '{"nombre":"Otro"}');
  perform pg_temp.ok(r3 ->> 'code' = 'comando_conflicto', 'mismo id con otros datos → conflicto');
  perform pg_temp.ok((select count(*) from public.orders) = n_orders and (select count(*) from public.commands where id = v_id) = 1, 'el conflicto no escribe nada');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '15 · Revisión desactualizada conserva el estado confirmado'
begin;
do $$
declare v_o uuid; v_rev int; r jsonb; v_status public.order_status; n_ev int;
begin
  perform pg_temp.admin();
  select id, revision, status into v_o, v_rev, v_status from public.orders where status = 'Confirmado' and channel = 'mayorista' limit 1;
  select count(*) into n_ev from public.domain_events where entity_id = v_o;
  r := pg_temp.cmd('cancelar_pedido', jsonb_build_object('pedido_id', v_o, 'motivo', 'prueba'), v_rev - 1);
  perform pg_temp.ok(r ->> 'code' = 'revision_desactualizada' and r ->> 'message' like '%Actualizá%', 'rechazo con la condición que falló: ' || (r ->> 'message'));
  perform pg_temp.ok((select status from public.orders where id = v_o) = v_status and (select revision from public.orders where id = v_o) = v_rev, 'estado y revisión intactos');
  perform pg_temp.ok((select count(*) from public.domain_events where entity_id = v_o) = n_ev, 'sin eventos nuevos');
  perform pg_temp.ok(exists (select 1 from public.order_allocations a join public.order_lines l on l.id = a.order_line_id where l.order_id = v_o and a.state = 'reservada'),
    'la reserva confirmada sigue en pie');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '16 · Falla a mitad del procedimiento: rollback total (pedido, reserva, evento y comando)'
begin;
do $$
declare v_id uuid := gen_random_uuid(); n_o int; n_a int; n_e int; n_l int; v_err text;
begin
  perform pg_temp.admin();
  insert into private.test_faults values ('reserva_tras_primera_escritura');
  select count(*) into n_o from public.orders; select count(*) into n_a from public.order_allocations;
  select count(*) into n_e from public.domain_events; select count(*) into n_l from public.order_lines;
  begin
    perform public.run_command(v_id, 'crear_pedido_web', jsonb_build_object('nombre', 'Falla', 'celular', '2966999999', 'entrega', 'retiro',
      'items', jsonb_build_array(jsonb_build_object('cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'bolsa_250', 'cantidad', 2))));
    perform pg_temp.ok(false, 'debería haber fallado');
  exception when others then
    get stacked diagnostics v_err = message_text;
    perform pg_temp.ok(v_err like 'falla_simulada%', 'la falla ocurre después de la primera reserva');
  end;
  perform pg_temp.ok((select count(*) from public.orders) = n_o and (select count(*) from public.order_allocations) = n_a
    and (select count(*) from public.domain_events) = n_e and (select count(*) from public.order_lines) = n_l
    and not exists (select 1 from public.commands where id = v_id), 'no quedan pedido, líneas, reserva, evento ni comando');
  delete from private.test_faults;
  perform pg_temp.ok((public.run_command(v_id, 'crear_pedido_web', jsonb_build_object('nombre', 'Falla', 'celular', '2966999999', 'entrega', 'retiro',
      'items', jsonb_build_array(jsonb_build_object('cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'bolsa_250', 'cantidad', 2)))) ->> 'ok')::boolean,
    'reintentar el mismo id después del rollback aplica una sola vez');
end $$;
rollback;

-- ---------------------------------------------------------------------
\echo '17 · Cierre y corrección: un cierre, un ajuste vinculado, antecedentes intactos'
begin;
do $$
declare t uuid; v_rev int; v_close_id uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; v_cl uuid; v_prop uuid; v_dec uuid := gen_random_uuid();
        v_counted bigint; v_pending uuid;
begin
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000002');
  select id, revision into t, v_rev from public.bar_shifts where status = 'abierto';
  r1 := public.run_command(v_close_id, 'cerrar_caja', jsonb_build_object('turno_id', t, 'contado', private.shift_expected_cash(t)), v_rev);
  r2 := public.run_command(v_close_id, 'cerrar_caja', jsonb_build_object('turno_id', t, 'contado', private.shift_expected_cash(t)), v_rev);
  perform pg_temp.ok((r1 ->> 'ok')::boolean and (r2 ->> 'repetido')::boolean and (select count(*) from public.cash_closures where shift_id = t) = 1,
    'repetir el cierre con el mismo id: un solo cierre');
  v_cl := (r1 ->> 'cierre_id')::uuid;
  select counted_cash into v_counted from public.cash_closures where id = v_cl;
  v_prop := (pg_temp.cmd('proponer_cambio', jsonb_build_object('entidad', 'cierre_caja', 'entidad_id', v_cl, 'cambios', '{"monto": 800}'::jsonb,
    'motivo', 'Vuelto de un proveedor que no se contó'), 1) ->> 'propuesta_id')::uuid;
  perform pg_temp.admin();
  r1 := public.run_command(v_dec, 'decidir_propuesta', jsonb_build_object('propuesta_id', v_prop, 'decision', 'aprobar'), 1);
  r2 := public.run_command(v_dec, 'decidir_propuesta', jsonb_build_object('propuesta_id', v_prop, 'decision', 'aprobar'), 1);
  perform pg_temp.ok((r1 ->> 'ok')::boolean and (select count(*) from public.cash_adjustments where proposal_id = v_prop) = 1, 'un ajuste vinculado a la propuesta');
  perform pg_temp.ok((select counted_cash from public.cash_closures where id = v_cl) = v_counted, 'el cierre original no se reescribe');
  -- la propuesta pendiente de la semilla: la creó barra, la decide admin (otro actor)
  select id into v_pending from public.change_proposals where status = 'pendiente' and entity = 'cierre_caja' and id <> v_prop;
  perform pg_temp.as_user('00000000-0000-4000-a000-000000000002');
  begin
    perform public.run_command(gen_random_uuid(), 'decidir_propuesta', jsonb_build_object('propuesta_id', v_pending, 'decision', 'aprobar'), 1);
    perform pg_temp.ok(false, 'barra no decide');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'quien no es administración no decide propuestas');
  end;
end $$;
rollback;

\echo 'Todas las pruebas de dominio pasaron.'
