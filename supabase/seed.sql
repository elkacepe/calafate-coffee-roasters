-- =====================================================================
-- Calafate Coffee Roasters · Semilla de datos sintéticos
-- Correr de nuevo este archivo REINICIA todo al estado inicial.
-- La historia se construye llamando a las MISMAS funciones de negocio con un reloj
-- simulado (private.now lee app.now solo para el dueño), así que stock, reservas,
-- saldos y eventos son consistentes por construcción.
-- Ancla R = último lunes a las 8:00 (hora Argentina) ≤ ahora: corrida de recurrentes.
-- Todos los nombres, celulares y direcciones son inventados.
-- =====================================================================

-- ---------- Limpieza (idempotente) ----------
truncate public.domain_events, public.commands, public.change_proposals, public.cash_adjustments, public.cash_closures,
  public.refunds, public.account_movements, public.waste_records, public.lot_movements, public.order_allocations,
  public.order_payments, public.supply_movements, public.packaging_runs, public.route_stops, public.routes,
  public.returns, public.order_lines, public.orders, public.bar_shifts, public.recurring_order_lines,
  public.recurring_orders, public.roast_inputs, public.green_movements, public.roast_batches, public.price_items,
  public.profiles, public.wholesale_customers, public.price_lists, public.drinks, public.supplies,
  public.blend_components, public.coffees, public.green_coffees, public.zones, public.settings cascade;
truncate private.test_faults;
alter sequence public.order_number_seq restart with 1001;
alter sequence public.return_number_seq restart with 501;
delete from auth.identities where user_id::text like '00000000-0000-4000-a000-0000000000%';
delete from auth.users where id::text like '00000000-0000-4000-a000-0000000000%';

-- ---------- Usuarios de prueba (contraseña de todos: Calafate2026!) ----------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id::uuid, 'authenticated', 'authenticated', u.email,
  extensions.crypt('Calafate2026!', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', jsonb_build_object('nombre', u.name), now(), now(), '', '', '', ''
from (values
  ('00000000-0000-4000-a000-000000000001', 'admin@calafate.test', 'Lucía Ferreyra'),
  ('00000000-0000-4000-a000-000000000002', 'barra@calafate.test', 'Tomás Quiroga'),
  ('00000000-0000-4000-a000-000000000003', 'tostaduria@calafate.test', 'Inés Arrieta'),
  ('00000000-0000-4000-a000-000000000004', 'reparto@calafate.test', 'Bruno Salvatierra'),
  ('00000000-0000-4000-a000-000000000005', 'hotel@calafate.test', 'Recepción Lenga Azul'),
  ('00000000-0000-4000-a000-000000000006', 'resto@calafate.test', 'Cocina Fogón del Ñire')
) as u(id, email, name);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), id, id::text, jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
  'email', now(), now(), now()
from auth.users where id::text like '00000000-0000-4000-a000-0000000000%';

-- ---------- Configuración y catálogos ----------
insert into public.settings (id) values (1);

insert into public.zones (name, notes, sort) values
  ('Centro', 'Microcentro y costanera baja', 1),
  ('Costanera', 'Zona hotelera sobre el lago', 2),
  ('Accesos y chacras', 'Rutas de acceso, chacras y hosterías de afuera', 3);

insert into public.green_coffees (name, country, region, process, cost_per_kg) values
  ('Colombia Huila lavado', 'Colombia', 'Huila', 'Lavado', 26000),
  ('Brasil Cerrado natural', 'Brasil', 'Cerrado Mineiro', 'Natural', 18000),
  ('Etiopía Yirgacheffe lavado', 'Etiopía', 'Yirgacheffe', 'Lavado', 34000),
  ('Perú Cajamarca lavado', 'Perú', 'Cajamarca', 'Lavado', 24000),
  ('Guatemala Huehuetenango lavado', 'Guatemala', 'Huehuetenango', 'Lavado', 29000);

insert into public.coffees (name, kind, green_id, tasting_notes, sort)
select 'Blend de la casa', 'blend', null, 'Chocolate con leche, avellana y cuerpo redondo. El de todos los días.', 1
union all select 'Colombia Huila', 'origen', id, 'Panela, naranja y final largo.', 2 from public.green_coffees where country = 'Colombia'
union all select 'Brasil Cerrado', 'origen', id, 'Maní tostado, cacao, poca acidez.', 3 from public.green_coffees where country = 'Brasil'
union all select 'Etiopía Yirgacheffe', 'origen', id, 'Jazmín, bergamota y durazno blanco.', 4 from public.green_coffees where country = 'Etiopía'
union all select 'Perú Cajamarca', 'origen', id, 'Caramelo, manzana roja, dulce y limpio.', 5 from public.green_coffees where country = 'Perú'
union all select 'Guatemala Huehuetenango', 'origen', id, 'Ciruela, chocolate amargo y especias.', 6 from public.green_coffees where country = 'Guatemala';

insert into public.blend_components (coffee_id, green_id, pct)
select (select id from public.coffees where kind = 'blend'), id, case country when 'Brasil' then 60 else 40 end
from public.green_coffees where country in ('Brasil','Colombia');

insert into public.supplies (code, name, unit) values
  ('leche', 'Leche entera', 'ml'), ('leche_almendras', 'Leche de almendras', 'ml'),
  ('bolsa_250', 'Bolsa con válvula 250 g', 'u'), ('bolsa_1000', 'Bolsa con válvula 1 kg', 'u');

insert into public.drinks (name, price, coffee_g, milk_ml, sort) values
  ('Espresso', 3800, 9, 0, 1), ('Espresso doble', 4900, 18, 0, 2), ('Cortado', 4600, 18, 40, 3),
  ('Flat white', 5900, 18, 120, 4), ('Capuchino', 5900, 18, 150, 5), ('Filtrado V60', 6200, 15, 0, 6),
  ('Cold brew', 6500, 20, 0, 7);

insert into public.price_lists (name, kind, credit_limit) values
  ('Público', 'publico', null), ('Gastronomía A', 'mayorista', 600000), ('Gastronomía B', 'mayorista', 300000);

-- Precios vigentes desde hace 60 días (pesos argentinos, de prueba)
insert into public.price_items (list_id, coffee_id, presentation, price, valid_from)
select pl.id, c.id, v.pres, v.price, ((now() at time zone 'America/Argentina/Buenos_Aires')::date - 60)
from (values
  ('Público','Blend de la casa','bolsa_250',14500), ('Público','Blend de la casa','bolsa_1000',52000),
  ('Público','Colombia Huila','bolsa_250',18500), ('Público','Colombia Huila','bolsa_1000',68000),
  ('Público','Brasil Cerrado','bolsa_250',17000), ('Público','Brasil Cerrado','bolsa_1000',62000),
  ('Público','Etiopía Yirgacheffe','bolsa_250',22000), ('Público','Etiopía Yirgacheffe','bolsa_1000',80000),
  ('Público','Perú Cajamarca','bolsa_250',19000), ('Público','Perú Cajamarca','bolsa_1000',70000),
  ('Público','Guatemala Huehuetenango','bolsa_250',20000), ('Público','Guatemala Huehuetenango','bolsa_1000',74000),
  ('Gastronomía A','Blend de la casa','kg_grano',44000), ('Gastronomía A','Blend de la casa','kg_molido',45500),
  ('Gastronomía A','Colombia Huila','kg_grano',56000), ('Gastronomía A','Colombia Huila','kg_molido',57500),
  ('Gastronomía A','Brasil Cerrado','kg_grano',50000), ('Gastronomía A','Brasil Cerrado','kg_molido',51500),
  ('Gastronomía A','Etiopía Yirgacheffe','kg_grano',66000), ('Gastronomía A','Etiopía Yirgacheffe','kg_molido',67500),
  ('Gastronomía A','Perú Cajamarca','kg_grano',58000), ('Gastronomía A','Perú Cajamarca','kg_molido',59500),
  ('Gastronomía A','Guatemala Huehuetenango','kg_grano',61000), ('Gastronomía A','Guatemala Huehuetenango','kg_molido',62500),
  ('Gastronomía B','Blend de la casa','kg_grano',47000), ('Gastronomía B','Blend de la casa','kg_molido',48500),
  ('Gastronomía B','Colombia Huila','kg_grano',59500), ('Gastronomía B','Colombia Huila','kg_molido',61000),
  ('Gastronomía B','Brasil Cerrado','kg_grano',53000), ('Gastronomía B','Brasil Cerrado','kg_molido',54500),
  ('Gastronomía B','Etiopía Yirgacheffe','kg_grano',70000), ('Gastronomía B','Etiopía Yirgacheffe','kg_molido',71500),
  ('Gastronomía B','Perú Cajamarca','kg_grano',61500), ('Gastronomía B','Perú Cajamarca','kg_molido',63000),
  ('Gastronomía B','Guatemala Huehuetenango','kg_grano',64500), ('Gastronomía B','Guatemala Huehuetenango','kg_molido',66000)
) as v(list, coffee, pres, price)
join public.price_lists pl on pl.name = v.list join public.coffees c on c.name = v.coffee;

-- Cambio de precio con vigencia futura (no toca pedidos confirmados): blend en Gastronomía A desde dentro de 7 días.
insert into public.price_items (list_id, coffee_id, presentation, price, valid_from)
select pl.id, c.id, 'kg_grano', 48000, ((now() at time zone 'America/Argentina/Buenos_Aires')::date + 7)
from public.price_lists pl, public.coffees c where pl.name = 'Gastronomía A' and c.kind = 'blend';

insert into public.wholesale_customers (id, name, kind, price_list_id, contact_name, phone, address, zone_id)
select v.id::uuid, v.name, v.kind, pl.id, v.contact, v.phone, v.address, z.id
from (values
  ('10000000-0000-4000-a000-000000000001','Hotel Lenga Azul','hotel','Gastronomía A','Valeria Ocampo','5492966400101','Av. del Lago 1450','Costanera'),
  ('10000000-0000-4000-a000-000000000002','Hotel Viento Blanco','hotel','Gastronomía A','Marcos Iturbe','5492966400102','Costanera Sur 230','Costanera'),
  ('10000000-0000-4000-a000-000000000003','Hostería Piedra Gris','hotel','Gastronomía B','Celina Duarte','5492966400103','Ruta 11 km 7','Accesos y chacras'),
  ('10000000-0000-4000-a000-000000000004','Restó Fogón del Ñire','restaurante','Gastronomía A','Julián Pardo','5492966400104','Libertador 1120','Centro'),
  ('10000000-0000-4000-a000-000000000005','Bodegón La Matra','restaurante','Gastronomía B','Rocío Benítez','5492966400105','9 de Julio 58','Centro'),
  ('10000000-0000-4000-a000-000000000006','Casa de Té Tetera Austral','casa_de_te','Gastronomía B','Amalia Kern','5492966400106','Moyano 77','Centro')
) as v(id, name, kind, list, contact, phone, address, zone)
join public.price_lists pl on pl.name = v.list join public.zones z on z.name = v.zone;

insert into public.profiles (id, role, full_name, customer_id) values
  ('00000000-0000-4000-a000-000000000001', 'admin', 'Lucía Ferreyra', null),
  ('00000000-0000-4000-a000-000000000002', 'barra', 'Tomás Quiroga', null),
  ('00000000-0000-4000-a000-000000000003', 'tostaduria', 'Inés Arrieta', null),
  ('00000000-0000-4000-a000-000000000004', 'reparto', 'Bruno Salvatierra', null),
  ('00000000-0000-4000-a000-000000000005', 'mayorista', 'Recepción Lenga Azul', '10000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-a000-000000000006', 'mayorista', 'Cocina Fogón del Ñire', '10000000-0000-4000-a000-000000000004');

-- ---------- Helpers temporales de la semilla ----------
create or replace function pg_temp.go(p_ts timestamptz) returns void language sql as $$
  select set_config('app.now', p_ts::text, false) $$;
create or replace function pg_temp.h(p_handler text, p jsonb, p_rev int default null,
  p_actor uuid default '00000000-0000-4000-a000-000000000001') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute format('select private.%I($1, $2, $3, null)', p_handler) into r using p, p_rev, p_actor;
  return r;
end $$;
create or replace function pg_temp.rev(p_order uuid) returns int language sql as $$
  select revision from public.orders where id = p_order $$;
create or replace function pg_temp.coffee(p_name text) returns uuid language sql as $$
  select id from public.coffees where name = p_name $$;
create or replace function pg_temp.zone(p_name text) returns uuid language sql as $$
  select id from public.zones where name = p_name $$;
create or replace function pg_temp.lot(p_code_suffix text) returns uuid language sql as $$
  select id from public.roast_batches where code like '%' || p_code_suffix $$;
create or replace function pg_temp.line(p_order uuid, p_no int default 1) returns uuid language sql as $$
  select id from public.order_lines where order_id = p_order and line_no = p_no $$;
-- Prepara un pedido: Confirmado → En preparación → Listo
create or replace function pg_temp.ready(p_order uuid) returns void language plpgsql as $$
begin
  perform pg_temp.h('h_cambiar_estado_pedido', jsonb_build_object('pedido_id', p_order, 'a', 'En preparación'), pg_temp.rev(p_order));
  perform pg_temp.h('h_cambiar_estado_pedido', jsonb_build_object('pedido_id', p_order, 'a', 'Listo'), pg_temp.rev(p_order));
end $$;
-- Recorrido completo (crea, asigna, inicia y entrega) en una fecha.
create or replace function pg_temp.route_deliver(p_ts timestamptz, p_zone text, p_slot text, p_orders uuid[],
  p_fail uuid default null, p_fail_note text default null) returns uuid language plpgsql as $$
declare v_r uuid; o uuid; st uuid;
begin
  perform pg_temp.go(p_ts - interval '1 hour');
  v_r := (pg_temp.h('h_crear_recorrido', jsonb_build_object('fecha', (p_ts at time zone 'America/Argentina/Buenos_Aires')::date,
    'zona_id', pg_temp.zone(p_zone), 'franja', p_slot, 'repartidor_id', '00000000-0000-4000-a000-000000000004')) ->> 'recorrido_id')::uuid;
  foreach o in array p_orders loop
    perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_r, 'pedido_id', o),
      (select revision from public.routes where id = v_r));
  end loop;
  perform pg_temp.h('h_iniciar_recorrido', jsonb_build_object('recorrido_id', v_r), (select revision from public.routes where id = v_r));
  perform pg_temp.go(p_ts);
  foreach o in array p_orders loop
    select id into st from public.route_stops where route_id = v_r and order_id = o;
    if o = p_fail then
      perform pg_temp.h('h_registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'no_entregado', 'nota', p_fail_note),
        pg_temp.rev(o), '00000000-0000-4000-a000-000000000004');
    else
      perform pg_temp.h('h_registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'entregado',
        'cobro', case when (select channel from public.orders where id = o) = 'web' then jsonb_build_object('metodo', 'efectivo') end),
        pg_temp.rev(o), '00000000-0000-4000-a000-000000000004');
    end if;
  end loop;
  return v_r;
end $$;

-- ---------- Línea de tiempo ----------
do $seed$
declare
  tz constant text := 'America/Argentina/Buenos_Aires';
  v_local timestamp := now() at time zone tz;
  v_rdate date;
  R timestamptz;
  ADMIN constant uuid := '00000000-0000-4000-a000-000000000001';
  BARRA constant uuid := '00000000-0000-4000-a000-000000000002';
  TOST constant uuid := '00000000-0000-4000-a000-000000000003';
  C_LENGA constant uuid := '10000000-0000-4000-a000-000000000001';
  C_VIENTO constant uuid := '10000000-0000-4000-a000-000000000002';
  C_PIEDRA constant uuid := '10000000-0000-4000-a000-000000000003';
  C_FOGON constant uuid := '10000000-0000-4000-a000-000000000004';
  C_MATRA constant uuid := '10000000-0000-4000-a000-000000000005';
  C_TETERA constant uuid := '10000000-0000-4000-a000-000000000006';
  BLEND uuid := pg_temp.coffee('Blend de la casa');
  COL uuid := pg_temp.coffee('Colombia Huila');
  BRA uuid := pg_temp.coffee('Brasil Cerrado');
  ETI uuid := pg_temp.coffee('Etiopía Yirgacheffe');
  PER uuid := pg_temp.coffee('Perú Cajamarca');
  GUA uuid := pg_temp.coffee('Guatemala Huehuetenango');
  w1 uuid; w2 uuid; w3 uuid; w4 uuid; w5 uuid; w6 uuid; w7 uuid; w8 uuid; w9 uuid; w10 uuid; w11 uuid; w12 uuid; w13 uuid; w14 uuid;
  m_piedra1 uuid; m_lenga1 uuid; m_matra1 uuid; m_tetera uuid; m_piedra2 uuid; m_fogon_hoy uuid;
  rec_viento uuid; rec_fogon uuid; rec_lenga uuid; o uuid; v_shift uuid; v_close uuid; v_ret uuid; v_repl uuid;
  v_route_am uuid; v_route_pm uuid; st uuid; v_today date := (now() at time zone tz)::date; i int;
  v_tickets jsonb;
  -- hora de "hoy" acotada a antes de ahora
  v_d0 date; v_d1 date;
begin
  v_rdate := v_local::date - (extract(isodow from v_local)::int - 1);
  if v_rdate = v_local::date and v_local::time < time '08:00' then v_rdate := v_rdate - 7; end if;
  R := (v_rdate + time '08:00') at time zone tz;

  -- Insumos y verde inicial (R-42)
  perform pg_temp.go(((v_rdate - 42) + time '06:30') at time zone tz);
  perform pg_temp.h('h_ingresar_verde', jsonb_build_object('verde_id', id, 'gramos', g, 'nota', 'Stock inicial'), null, TOST)
    from (select id, case country when 'Colombia' then 90000 when 'Brasil' then 90000 when 'Etiopía' then 40000
                                   when 'Perú' then 45000 else 50000 end g from public.green_coffees) z;
  perform pg_temp.h('h_ingresar_insumo', jsonb_build_object('insumo_id', id, 'cantidad', q, 'nota', 'Stock inicial'), null, TOST)
    from (select id, case code when 'leche' then 24000 when 'leche_almendras' then 6000 when 'bolsa_250' then 400 else 150 end q
            from public.supplies) z;

  -- ===== Tuestes históricos (lunes, miércoles y viernes 7 a 9) =====
  perform pg_temp.go(((v_rdate - 38) + time '07:10') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', PER, 'verde_g', 5000, 'tostado_g', 4250), null, TOST);
  perform pg_temp.go(((v_rdate - 35) + time '07:20') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BLEND, 'verde_g', 15000, 'tostado_g', 12750), null, TOST);

  -- W1: bolsa de Perú, retiro (R-37 sábado)
  perform pg_temp.go(((v_rdate - 37) + time '10:15') at time zone tz);
  w1 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Martina Lezcano', 'celular', '2966 41-0001',
    'entrega', 'retiro', 'items', jsonb_build_array(jsonb_build_object('cafe_id', PER, 'presentacion', 'bolsa_250', 'molienda', 'filtro', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w1);
  perform pg_temp.go(((v_rdate - 37) + time '17:30') at time zone tz);
  perform pg_temp.h('h_entregar_retiro', jsonb_build_object('pedido_id', w1, 'metodo', 'efectivo'), pg_temp.rev(w1), BARRA);

  -- Mayoristas R-34: Piedra Gris (4 kg Perú, deja el lote en cero) y Lenga Azul (6 kg blend: la deuda que vence)
  perform pg_temp.go(((v_rdate - 34) + time '11:00') at time zone tz);
  m_piedra1 := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('cliente_id', C_PIEDRA, 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', PER, 'presentacion', 'kg_grano', 'cantidad', 4)))) ->> 'pedido_id')::uuid;
  m_lenga1 := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('cliente_id', C_LENGA, 'confirmar', true,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'kg_grano', 'cantidad', 6)))) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(m_piedra1); perform pg_temp.ready(m_lenga1);

  perform pg_temp.go(((v_rdate - 33) + time '07:30') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', ETI, 'verde_g', 6000, 'tostado_g', 5040), null, TOST);
  perform pg_temp.route_deliver(((v_rdate - 33) + time '11:00') at time zone tz, 'Costanera', '10-13', array[m_lenga1]);
  perform pg_temp.route_deliver(((v_rdate - 33) + time '12:00') at time zone tz, 'Accesos y chacras', '10-13', array[m_piedra1]);

  -- W2: Etiopía envío Centro
  perform pg_temp.go(((v_rdate - 32) + time '12:00') at time zone tz);
  w2 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Federico Almirón', 'celular', '2966 41-0002',
    'entrega', 'envio', 'zona_id', pg_temp.zone('Centro'), 'direccion', 'Los Pioneros 431', 'fecha', v_rdate - 31,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', ETI, 'presentacion', 'bolsa_250', 'molienda', 'espresso', 'cantidad', 2))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w2);
  perform pg_temp.route_deliver(((v_rdate - 31) + time '16:00') at time zone tz, 'Centro', '15-18', array[w2]);

  perform pg_temp.go(((v_rdate - 26) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', COL, 'verde_g', 10000, 'tostado_g', 8500), null, TOST);
  perform pg_temp.go(((v_rdate - 24) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BRA, 'verde_g', 10000, 'tostado_g', 8600), null, TOST);

  perform pg_temp.go(((v_rdate - 20) + time '10:00') at time zone tz);
  perform pg_temp.h('h_registrar_pago', jsonb_build_object('cliente_id', C_PIEDRA, 'monto', 246000, 'metodo', 'transferencia', 'referencia', 'Transf. 88412'));

  perform pg_temp.go(((v_rdate - 19) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BLEND, 'verde_g', 15000, 'tostado_g', 12750), null, TOST);
  perform pg_temp.go(((v_rdate - 17) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', GUA, 'verde_g', 8000, 'tostado_g', 6720), null, TOST);
  perform pg_temp.go(((v_rdate - 12) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BLEND, 'verde_g', 15000, 'tostado_g', 12600), null, TOST);
  perform pg_temp.go(((v_rdate - 12) + time '09:00') at time zone tz);
  perform pg_temp.h('h_envasar', jsonb_build_object('lote_id', id, 'formato', 'bolsa_250', 'bolsas', 16), null, TOST)
    from public.roast_batches where coffee_id = BLEND order by roasted_at desc limit 1;
  perform pg_temp.go(((v_rdate - 10) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', COL, 'verde_g', 10000, 'tostado_g', 8450), null, TOST);

  -- ===== Recurrentes de la semana pasada (R-7, lunes 8 h) =====
  insert into public.recurring_orders (id, customer_id, notes) values
    ('20000000-0000-4000-a000-000000000002', C_VIENTO, 'Desayunos del hotel'),
    ('20000000-0000-4000-a000-000000000004', C_FOGON, 'Servicio de la semana');
  insert into public.recurring_order_lines (recurring_id, coffee_id, presentation, grind, qty) values
    ('20000000-0000-4000-a000-000000000002', BLEND, 'kg_grano', 'grano', 4),
    ('20000000-0000-4000-a000-000000000002', COL, 'kg_grano', 'grano', 2),
    ('20000000-0000-4000-a000-000000000004', BLEND, 'kg_grano', 'grano', 3);
  perform pg_temp.go(((v_rdate - 7) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', ETI, 'verde_g', 6000, 'tostado_g', 4980), null, TOST);
  perform pg_temp.go(R - interval '7 days');
  perform pg_temp.h('h_correr_recurrentes', jsonb_build_object('fecha', v_rdate - 7));
  perform pg_temp.go(((v_rdate - 7) + time '08:40') at time zone tz);
  select id into rec_viento from public.orders where recurring_id = '20000000-0000-4000-a000-000000000002' and recurring_date = v_rdate - 7;
  select id into rec_fogon from public.orders where recurring_id = '20000000-0000-4000-a000-000000000004' and recurring_date = v_rdate - 7;
  perform pg_temp.ready(rec_viento); perform pg_temp.ready(rec_fogon);
  perform pg_temp.route_deliver(((v_rdate - 7) + time '11:00') at time zone tz, 'Costanera', '10-13', array[rec_viento]);
  perform pg_temp.route_deliver(((v_rdate - 7) + time '11:40') at time zone tz, 'Centro', '10-13', array[rec_fogon]);

  -- El hotel Lenga Azul se suma al pedido recurrente después de esa corrida.
  insert into public.recurring_orders (id, customer_id, notes) values ('20000000-0000-4000-a000-000000000001', C_LENGA, 'Blend para desayunos');
  insert into public.recurring_order_lines (recurring_id, coffee_id, presentation, grind, qty) values
    ('20000000-0000-4000-a000-000000000001', BLEND, 'kg_grano', 'grano', 6);

  -- Reclamo del Viento Blanco: bolsa mal sellada (R-6)
  perform pg_temp.go(((v_rdate - 6) + time '10:30') at time zone tz);
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', rec_viento, 'linea_id', pg_temp.line(rec_viento, 1),
    'bolsas', 1, 'condicion', 'mal_sellada', 'motivo', 'La válvula vino despegada, el café perdió aroma'));

  -- R-5 miércoles
  perform pg_temp.go(((v_rdate - 5) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', PER, 'verde_g', 6000, 'tostado_g', 4440,
    'motivo', 'Prueba de perfil más oscuro para espresso; balanza verificada'), null, TOST);
  perform pg_temp.go(((v_rdate - 5) + time '10:00') at time zone tz);
  w3 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Agustina Ríos', 'celular', '2966 41-0003', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', COL, 'presentacion', 'bolsa_250', 'molienda', 'grano', 'cantidad', 2))), null, null) ->> 'pedido_id')::uuid;
  w4 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Hernán Sosa', 'celular', '2966 41-0004', 'entrega', 'envio',
    'zona_id', pg_temp.zone('Centro'), 'direccion', 'Gob. Gregores 980', 'fecha', v_rdate - 4,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'bolsa_1000', 'molienda', 'espresso', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  w5 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Paula Montes', 'celular', '2966 41-0005', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', ETI, 'presentacion', 'bolsa_250', 'molienda', 'filtro', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  m_matra1 := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('cliente_id', C_MATRA, 'confirmar', true, 'fecha', v_rdate - 4,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', GUA, 'presentacion', 'kg_grano', 'cantidad', 2)))) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w3); perform pg_temp.ready(w4); perform pg_temp.ready(w5); perform pg_temp.ready(m_matra1);
  perform pg_temp.go(((v_rdate - 5) + time '18:00') at time zone tz);
  perform pg_temp.h('h_entregar_retiro', jsonb_build_object('pedido_id', w3, 'metodo', 'qr'), pg_temp.rev(w3), BARRA);
  perform pg_temp.h('h_entregar_retiro', jsonb_build_object('pedido_id', w5, 'metodo', 'efectivo'), pg_temp.rev(w5), BARRA);

  -- R-4 jueves
  perform pg_temp.route_deliver(((v_rdate - 4) + time '16:00') at time zone tz, 'Centro', '15-18', array[w4, m_matra1]);
  perform pg_temp.go(((v_rdate - 4) + time '10:00') at time zone tz);
  m_tetera := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('cliente_id', C_TETERA, 'confirmar', true, 'fecha', v_rdate - 3,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'kg_molido', 'molienda', 'filtro', 'cantidad', 2)))) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(m_tetera);
  perform pg_temp.go(((v_rdate - 4) + time '19:00') at time zone tz);
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', w5, 'linea_id', pg_temp.line(w5),
    'bolsas', 1, 'condicion', 'abierta', 'motivo', 'No me gustó, la abrí y la quiero cambiar'));

  -- R-3 viernes
  perform pg_temp.go(((v_rdate - 3) + time '07:15') at time zone tz);
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BLEND, 'verde_g', 15000, 'tostado_g', 12750), null, TOST);
  perform pg_temp.route_deliver(((v_rdate - 3) + time '11:00') at time zone tz, 'Centro', '10-13', array[m_tetera]);
  perform pg_temp.go(((v_rdate - 3) + time '12:00') at time zone tz);
  m_piedra2 := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('cliente_id', C_PIEDRA, 'confirmar', true, 'fecha', v_rdate - 2,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BRA, 'presentacion', 'kg_grano', 'cantidad', 3)))) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(m_piedra2);
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', w3, 'linea_id', pg_temp.line(w3),
    'bolsas', 1, 'condicion', 'cerrada', 'motivo', 'Compré de más, la bolsa está sin abrir'));
  select id into v_ret from public.returns where order_id = w5;
  perform pg_temp.h('h_decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'rechazar',
    'nota', 'Bolsa abierta sin defecto: no corresponde devolución'), (select revision from public.returns where id = v_ret));

  -- R-2 sábado: reparto, ventas web, caja de barra completa
  perform pg_temp.route_deliver(((v_rdate - 2) + time '11:00') at time zone tz, 'Accesos y chacras', '10-13', array[m_piedra2]);
  perform pg_temp.go(((v_rdate - 2) + time '08:50') at time zone tz);
  v_shift := (pg_temp.h('h_abrir_turno', jsonb_build_object('lote_id', pg_temp.lot(to_char(v_rdate - 35, 'YYMMDD') || '-01'),
    'efectivo_inicial', 20000), null, BARRA) ->> 'turno_id')::uuid;
  for i in 1..9 loop
    perform pg_temp.go(((v_rdate - 2) + time '09:20' + make_interval(mins => i * 70)) at time zone tz);
    v_tickets := case i % 4
      when 0 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Flat white'), 'cantidad', 2))
      when 1 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Espresso'), 'cantidad', 1),
                                    jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Capuchino'), 'cantidad', 1, 'almendras', true))
      when 2 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Espresso doble'), 'cantidad', 2))
      else jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Filtrado V60'), 'cantidad', 1),
                             jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Cortado'), 'cantidad', 1)) end;
    perform pg_temp.h('h_vender_barra', jsonb_build_object('turno_id', v_shift, 'items', v_tickets,
      'metodo', case when i % 3 = 0 then 'tarjeta' else 'efectivo' end), null, BARRA);
  end loop;
  perform pg_temp.go(((v_rdate - 2) + time '10:30') at time zone tz);
  w6 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Lorena Vidal', 'celular', '2966 41-0006', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', GUA, 'presentacion', 'bolsa_250', 'molienda', 'prensa francesa', 'cantidad', 2))), null, null) ->> 'pedido_id')::uuid;
  w7 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Diego Ferro', 'celular', '2966 41-0007', 'entrega', 'envio',
    'zona_id', pg_temp.zone('Accesos y chacras'), 'direccion', 'Chacra Los Notros Bajos, lote 4', 'fecha', v_rdate - 2,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BRA, 'presentacion', 'bolsa_1000', 'molienda', 'grano', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  w8 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Sofía Barrios', 'celular', '2966 41-0008', 'entrega', 'envio',
    'zona_id', pg_temp.zone('Centro'), 'direccion', 'Av. Libertador 1302, 2° B', 'fecha', v_rdate,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', COL, 'presentacion', 'bolsa_1000', 'molienda', 'espresso', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w6); perform pg_temp.ready(w7);
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', m_tetera, 'linea_id', pg_temp.line(m_tetera),
    'bolsas', 1, 'condicion', 'mal_sellada', 'motivo', 'La bolsa llegó con el cierre abierto'));
  select id into v_ret from public.returns where order_id = m_tetera;
  perform pg_temp.h('h_decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'nota_credito',
    'nota', 'Mal sellada: merma y nota de crédito'), (select revision from public.returns where id = v_ret));
  select id into v_ret from public.returns where order_id = w3;
  perform pg_temp.h('h_decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'reintegro',
    'metodo', 'efectivo', 'nota', 'Bolsa cerrada, vuelve al lote'), (select revision from public.returns where id = v_ret));
  perform pg_temp.go(((v_rdate - 2) + time '17:00') at time zone tz);
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', m_piedra2, 'linea_id', pg_temp.line(m_piedra2),
    'bolsas', 1, 'condicion', 'cerrada', 'motivo', 'Pedimos de más, la bolsa está cerrada'));
  select id into v_ret from public.returns where order_id = m_piedra2;
  perform pg_temp.h('h_revisar_devolucion', jsonb_build_object('devolucion_id', v_ret), 1);
  perform pg_temp.h('h_entregar_retiro', jsonb_build_object('pedido_id', w6, 'metodo', 'tarjeta'), pg_temp.rev(w6), BARRA);
  perform pg_temp.route_deliver(((v_rdate - 2) + time '16:30') at time zone tz, 'Accesos y chacras', '15-18', array[w7],
    w7, 'No había nadie en la chacra, portón cerrado');
  -- Cierre de caja con diferencia mayor al umbral: exige motivo.
  perform pg_temp.go(((v_rdate - 2) + time '20:10') at time zone tz);
  v_close := (pg_temp.h('h_cerrar_caja', jsonb_build_object('turno_id', v_shift,
    'contado', private.shift_expected_cash(v_shift) - 2500, 'motivo', 'Faltante: un vuelto mal dado en la hora pico'),
    (select revision from public.bar_shifts where id = v_shift), BARRA) ->> 'cierre_id')::uuid;

  -- R-1 domingo (cerrado): administración resuelve pendientes
  perform pg_temp.go(((v_rdate - 1) + time '11:00') at time zone tz);
  perform pg_temp.h('h_registrar_pago', jsonb_build_object('cliente_id', C_MATRA, 'monto', 129000, 'metodo', 'transferencia', 'referencia', 'Transf. 90231'));
  perform pg_temp.h('h_pedir_devolucion', jsonb_build_object('pedido_id', m_matra1, 'linea_id', pg_temp.line(m_matra1),
    'bolsas', 1, 'condicion', 'defectuosa', 'motivo', 'Granos quebrados y olor raro al abrir'));
  select id into v_ret from public.returns where order_id = rec_viento;
  v_repl := (pg_temp.h('h_decidir_devolucion', jsonb_build_object('devolucion_id', v_ret, 'decision', 'aceptar', 'resolucion', 'reposicion',
    'nota', 'Se repone en el próximo viaje a la Costanera'), (select revision from public.returns where id = v_ret)) ->> 'pedido_reposicion')::uuid;
  -- Propuestas: una pendiente (caja) y una rechazada (lote), con actores distintos.
  perform pg_temp.h('h_proponer_cambio', jsonb_build_object('entidad', 'cierre_caja', 'entidad_id', v_close,
    'cambios', jsonb_build_object('monto', 1500), 'motivo', 'Aparecieron $1.500 en el sobre de propinas: eran de la caja'),
    (select revision from public.cash_closures where id = v_close), BARRA);
  perform pg_temp.h('h_proponer_cambio', jsonb_build_object('entidad', 'lote', 'entidad_id', pg_temp.lot(to_char(v_rdate - 17, 'YYMMDD') || '-01'),
    'cambios', jsonb_build_object('gramos', -300), 'motivo', 'Bolsa rota en el depósito, se tiraron unos 300 g'),
    (select revision from public.roast_batches where id = pg_temp.lot(to_char(v_rdate - 17, 'YYMMDD') || '-01')), TOST);
  perform pg_temp.h('h_decidir_propuesta', jsonb_build_object('propuesta_id', id, 'decision', 'rechazar',
    'nota', 'Revisé el depósito: la bolsa estaba entera en otra estantería'), revision)
    from public.change_proposals where entity = 'lote';

  -- ===== R: lunes 8 h, recurrentes. Lenga Azul tiene deuda vencida hace 18 días → Retenido =====
  perform pg_temp.go(R);
  perform pg_temp.h('h_correr_recurrentes', jsonb_build_object('fecha', v_rdate));
  select id into rec_lenga from public.orders where recurring_id = '20000000-0000-4000-a000-000000000001' and recurring_date = v_rdate;
  select id into rec_viento from public.orders where recurring_id = '20000000-0000-4000-a000-000000000002' and recurring_date = v_rdate;
  select id into rec_fogon from public.orders where recurring_id = '20000000-0000-4000-a000-000000000004' and recurring_date = v_rdate;

  -- ===== Hoy =====
  v_d0 := case when extract(isodow from v_today) = 7 then v_today + 1 else v_today end;
  v_d1 := case when extract(isodow from v_d0 + 1) = 7 then v_d0 + 2 else v_d0 + 1 end;
  perform pg_temp.go(least((v_today + time '07:15') at time zone tz, now() - interval '50 minutes'));
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', BLEND, 'verde_g', 15000, 'tostado_g', 12750), null, TOST);
  perform pg_temp.go(least((v_today + time '08:20') at time zone tz, now() - interval '45 minutes'));
  perform pg_temp.h('h_registrar_tueste', jsonb_build_object('cafe_id', GUA, 'verde_g', 8000, 'tostado_g', 6800), null, TOST);

  perform pg_temp.go(greatest(R, least((v_today + time '08:50') at time zone tz, now() - interval '40 minutes')));
  perform pg_temp.ready(rec_viento); perform pg_temp.ready(rec_fogon); perform pg_temp.ready(v_repl); perform pg_temp.ready(w8);
  v_shift := (pg_temp.h('h_abrir_turno', jsonb_build_object('lote_id', pg_temp.lot(to_char(v_rdate - 35, 'YYMMDD') || '-01'),
    'efectivo_inicial', 20000), null, BARRA) ->> 'turno_id')::uuid;
  v_route_am := (pg_temp.h('h_crear_recorrido', jsonb_build_object('fecha', v_today, 'zona_id', pg_temp.zone('Centro'),
    'franja', '10-13', 'repartidor_id', '00000000-0000-4000-a000-000000000004')) ->> 'recorrido_id')::uuid;
  perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route_am, 'pedido_id', rec_fogon), 1);
  perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route_am, 'pedido_id', w8), 2);
  perform pg_temp.h('h_iniciar_recorrido', jsonb_build_object('recorrido_id', v_route_am), 3);

  perform pg_temp.go(greatest(R, least((v_today + time '09:30') at time zone tz, now() - interval '35 minutes')));
  for i in 1..4 loop
    perform pg_temp.h('h_vender_barra', jsonb_build_object('turno_id', v_shift, 'metodo', case when i = 2 then 'qr' else 'efectivo' end,
      'items', case i
        when 1 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Espresso'), 'cantidad', 2),
                                      jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Flat white'), 'cantidad', 1))
        when 2 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Flat white'), 'cantidad', 2, 'almendras', true))
        when 3 then jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Cold brew'), 'cantidad', 1))
        else jsonb_build_array(jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Espresso doble'), 'cantidad', 1),
                               jsonb_build_object('bebida_id', (select id from public.drinks where name = 'Capuchino'), 'cantidad', 1)) end), null, BARRA);
  end loop;

  perform pg_temp.go(greatest(R, least((v_today + time '10:40') at time zone tz, now() - interval '30 minutes')));
  select id into st from public.route_stops where route_id = v_route_am and order_id = rec_fogon;
  perform pg_temp.h('h_registrar_entrega', jsonb_build_object('parada_id', st, 'resultado', 'entregado'), pg_temp.rev(rec_fogon),
    '00000000-0000-4000-a000-000000000004');

  -- El restaurante del centro pide por el portal 6 kg del blend.
  perform pg_temp.go(greatest(R, least((v_today + time '10:50') at time zone tz, now() - interval '28 minutes')));
  m_fogon_hoy := (pg_temp.h('h_crear_pedido_mayorista', jsonb_build_object('confirmar', true, 'cliente_id', C_FOGON, 'fecha', v_d1,
    'notas', 'Para el servicio del martes', 'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'kg_grano', 'cantidad', 6))),
    null, '00000000-0000-4000-a000-000000000006') ->> 'pedido_id')::uuid;

  perform pg_temp.go(greatest(R, least((v_today + time '11:00') at time zone tz, now() - interval '25 minutes')));
  w9 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Carolina Peralta', 'celular', '2966 41-0009', 'entrega', 'envio',
    'zona_id', pg_temp.zone('Costanera'), 'direccion', 'Costanera Sur 615', 'fecha', v_d0,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BRA, 'presentacion', 'bolsa_1000', 'molienda', 'filtro', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w9);
  -- La familia que vuelve a su ciudad: cuatro bolsas de 250 g para retirar a la tarde.
  w10 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Familia Acuña', 'celular', '11 5555-0010', 'entrega', 'retiro',
    'notas', 'Retiramos a eso de las 17', 'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'bolsa_250', 'molienda', 'espresso', 'cantidad', 4))), null, null) ->> 'pedido_id')::uuid;
  w11 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Mateo Giménez', 'celular', '2966 41-0011', 'entrega', 'envio',
    'zona_id', pg_temp.zone('Accesos y chacras'), 'direccion', 'Ruta 11 km 3, cabaña 2', 'fecha', v_d1,
    'items', jsonb_build_array(jsonb_build_object('cafe_id', ETI, 'presentacion', 'bolsa_250', 'molienda', 'filtro', 'cantidad', 2))), null, null) ->> 'pedido_id')::uuid;
  w12 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Natalia Correa', 'celular', '2966 41-0012', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', COL, 'presentacion', 'bolsa_250', 'molienda', 'grano', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.h('h_cancelar_pedido', jsonb_build_object('pedido_id', w12, 'motivo', 'La clienta avisó que no viene'), pg_temp.rev(w12));
  w13 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Ramiro Ojeda', 'celular', '2966 41-0013', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', GUA, 'presentacion', 'bolsa_1000', 'molienda', 'grano', 'cantidad', 1))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.ready(w13);
  w14 := (pg_temp.h('h_crear_pedido_web', jsonb_build_object('nombre', 'Elena Vázquez', 'celular', '2966 41-0014', 'entrega', 'retiro',
    'items', jsonb_build_array(jsonb_build_object('cafe_id', BLEND, 'presentacion', 'bolsa_250', 'molienda', 'prensa francesa', 'cantidad', 2))), null, null) ->> 'pedido_id')::uuid;
  perform pg_temp.h('h_cambiar_estado_pedido', jsonb_build_object('pedido_id', w14, 'a', 'En preparación'), pg_temp.rev(w14));

  -- Recorrido de la tarde a la zona hotelera (planificado): recurrente + reposición del Viento Blanco + un envío web.
  v_route_pm := (pg_temp.h('h_crear_recorrido', jsonb_build_object('fecha', v_today, 'zona_id', pg_temp.zone('Costanera'),
    'franja', '15-18', 'repartidor_id', '00000000-0000-4000-a000-000000000004')) ->> 'recorrido_id')::uuid;
  perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route_pm, 'pedido_id', rec_viento), 1);
  perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route_pm, 'pedido_id', v_repl), 2);
  perform pg_temp.h('h_asignar_a_recorrido', jsonb_build_object('recorrido_id', v_route_pm, 'pedido_id', w9), 3);

  perform set_config('app.now', '', false);
end $seed$;

-- ===== Seis comandos de antecedente (5 aplicados con revisiones 1..5 y 1 rechazado sin evento) =====
-- Pedido del Bodegón La Matra cargado por administración. Usan la API real (run_command) con el actor admin.
do $cmds$
declare v_order uuid; r jsonb;
begin
  perform set_config('app.now', (now() - interval '20 minutes')::text, false);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', false);
  r := public.run_command('30000000-0000-4000-a000-000000000001', 'crear_pedido_mayorista',
    jsonb_build_object('cliente_id', '10000000-0000-4000-a000-000000000005', 'notas', 'Pedido telefónico',
      'items', jsonb_build_array(jsonb_build_object('cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'kg_grano', 'cantidad', 2))));
  v_order := (r ->> 'pedido_id')::uuid;
  r := public.run_command('30000000-0000-4000-a000-000000000002', 'editar_borrador',
    jsonb_build_object('pedido_id', v_order, 'items', jsonb_build_array(
      jsonb_build_object('cafe_id', (select id from public.coffees where kind = 'blend'), 'presentacion', 'kg_grano', 'cantidad', 3),
      jsonb_build_object('cafe_id', (select id from public.coffees where name = 'Guatemala Huehuetenango'), 'presentacion', 'kg_molido', 'molienda', 'espresso', 'cantidad', 1))), 1);
  r := public.run_command('30000000-0000-4000-a000-000000000003', 'confirmar_pedido', jsonb_build_object('pedido_id', v_order), 2);
  r := public.run_command('30000000-0000-4000-a000-000000000004', 'cambiar_estado_pedido', jsonb_build_object('pedido_id', v_order, 'a', 'En preparación'), 3);
  -- Rechazado: otra pestaña intentó marcarlo «Listo» con la revisión 3 (ya era la 4).
  r := public.run_command('30000000-0000-4000-a000-000000000005', 'cambiar_estado_pedido', jsonb_build_object('pedido_id', v_order, 'a', 'Listo'), 3);
  r := public.run_command('30000000-0000-4000-a000-000000000006', 'cambiar_estado_pedido', jsonb_build_object('pedido_id', v_order, 'a', 'Listo'), 4);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('app.now', '', false);
end $cmds$;

-- Estados por tiempo al día de hoy.
select public.refresh_lot_states();
