-- =====================================================================
-- Calafate Coffee Roasters · 04 · API pública (RPC)
-- Escrituras: SOLO por public.run_command (idempotente, con revisión y registro).
-- Lecturas agregadas: funciones con chequeo de rol en servidor.
-- =====================================================================

insert into public.command_types (type, handler, allowed_roles, allow_anon, description) values
 ('crear_pedido_web',       'h_crear_pedido_web',       '{admin,barra,tostaduria,reparto,mayorista}', true,  'Pedido minorista web (sin cuenta)'),
 ('crear_pedido_mayorista', 'h_crear_pedido_mayorista', '{admin,mayorista}', false, 'Pedido mayorista (borrador o confirmado)'),
 ('editar_borrador',        'h_editar_borrador',        '{admin,mayorista}', false, 'Editar líneas de un borrador'),
 ('confirmar_pedido',       'h_confirmar_pedido',       '{admin,mayorista}', false, 'Confirmar borrador: congela precio y reserva'),
 ('cambiar_estado_pedido',  'h_cambiar_estado_pedido',  '{admin}', false, 'En preparación / Listo'),
 ('cancelar_pedido',        'h_cancelar_pedido',        '{admin,mayorista}', false, 'Cancelar y liberar reserva'),
 ('correr_recurrentes',     'h_correr_recurrentes',     '{admin}', false, 'Reserva de recurrentes del lunes 8 h'),
 ('liberar_retenido',       'h_liberar_retenido',       '{admin}', false, 'Liberar pedido retenido y reservar'),
 ('ingresar_verde',         'h_ingresar_verde',         '{admin,tostaduria}', false, 'Ingreso de café verde'),
 ('registrar_tueste',       'h_registrar_tueste',       '{admin,tostaduria}', false, 'Nuevo lote tostado'),
 ('envasar',                'h_envasar',                '{admin,tostaduria}', false, 'Envasado de bolsas'),
 ('ingresar_insumo',        'h_ingresar_insumo',        '{admin,tostaduria}', false, 'Ingreso/ajuste de insumos'),
 ('bloquear_lote',          'h_bloquear_lote',          '{admin}', false, 'Porcentaje reservado a mayoristas'),
 ('abrir_turno',            'h_abrir_turno',            '{admin,barra}', false, 'Abrir caja y asignar lote'),
 ('cambiar_lote_turno',     'h_cambiar_lote_turno',     '{admin,barra}', false, 'Cambiar lote de barra'),
 ('vender_barra',           'h_vender_barra',           '{admin,barra}', false, 'Ticket de barra'),
 ('cerrar_caja',            'h_cerrar_caja',            '{admin,barra}', false, 'Cierre de caja'),
 ('entregar_retiro',        'h_entregar_retiro',        '{admin,barra}', false, 'Entrega de pedido web en el local'),
 ('crear_recorrido',        'h_crear_recorrido',        '{admin}', false, 'Nuevo recorrido'),
 ('asignar_a_recorrido',    'h_asignar_a_recorrido',    '{admin}', false, 'Cargar pedido en recorrido'),
 ('quitar_de_recorrido',    'h_quitar_de_recorrido',    '{admin}', false, 'Sacar pedido del recorrido'),
 ('iniciar_recorrido',      'h_iniciar_recorrido',      '{admin,reparto}', false, 'Salir a repartir'),
 ('registrar_entrega',      'h_registrar_entrega',      '{admin,reparto}', false, 'Resultado de una parada'),
 ('pedir_devolucion',       'h_pedir_devolucion',       '{admin,mayorista}', false, 'Reclamo / devolución'),
 ('revisar_devolucion',     'h_revisar_devolucion',     '{admin}', false, 'Pasar a revisión'),
 ('decidir_devolucion',     'h_decidir_devolucion',     '{admin}', false, 'Aceptar o rechazar devolución'),
 ('registrar_pago',         'h_registrar_pago',         '{admin}', false, 'Pago de mayorista'),
 ('proponer_cambio',        'h_proponer_cambio',        '{admin,barra,tostaduria}', false, 'Propuesta de corrección'),
 ('decidir_propuesta',      'h_decidir_propuesta',      '{admin}', false, 'Aprobar o rechazar propuesta'),
 ('actualizar_precio',      'h_actualizar_precio',      '{admin}', false, 'Nueva versión de precio'),
 ('actualizar_config',      'h_actualizar_config',      '{admin}', false, 'Configuración');

-- Punto de entrada único de escritura.
-- Mismo id + mismos datos → devuelve el resultado guardado (sin nuevos efectos).
-- Mismo id + otros datos → conflicto, sin escrituras.
-- Error de negocio → se revierte todo el efecto y queda el comando como «rechazado».
-- Error inesperado → se revierte TODO (incluido el registro del comando).
create or replace function public.run_command(
  p_command_id uuid, p_type text, p_payload jsonb default '{}'::jsonb, p_expected_revision int default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ct public.command_types; v_actor uuid := auth.uid(); v_role public.app_role; v_hash text;
        v_existing public.commands; v_result jsonb; v_detail text; v_hint text; v_msg text;
begin
  if p_command_id is null then raise exception 'Falta el id de comando' using errcode = '22023'; end if;
  select * into ct from public.command_types where type = p_type;
  if not found then raise exception 'Comando desconocido: %', p_type using errcode = '22023'; end if;
  v_role := private.my_role();
  if not ((v_role is not null and v_role = any(ct.allowed_roles)) or (ct.allow_anon and v_role is null)) then
    raise exception 'No tenés permiso para esta acción.' using errcode = '42501';
  end if;
  p_payload := coalesce(p_payload, '{}'::jsonb);
  v_hash := encode(sha256(convert_to(jsonb_build_object('t', p_type, 'p', p_payload, 'r', p_expected_revision)::text, 'UTF8')), 'hex');

  insert into public.commands (id, type, actor_id, actor_role, expected_revision, payload, payload_hash, status, created_at)
  values (p_command_id, p_type, v_actor, v_role, p_expected_revision, p_payload, v_hash, 'en_curso', private.now())
  on conflict (id) do nothing;
  if not found then
    select * into v_existing from public.commands where id = p_command_id;
    if v_existing.payload_hash <> v_hash or v_existing.actor_id is distinct from v_actor then
      return jsonb_build_object('ok', false, 'code', 'comando_conflicto',
        'message', 'Ese envío ya se usó con otros datos. Actualizá la pantalla y volvé a intentar.');
    end if;
    return coalesce(v_existing.result, '{}'::jsonb) || jsonb_build_object('repetido', true);
  end if;

  begin
    execute format('select private.%I($1, $2, $3, $4)', ct.handler)
      into v_result using p_payload, p_expected_revision, v_actor, p_command_id;
    v_result := jsonb_build_object('ok', true) || coalesce(v_result, '{}'::jsonb);
    update public.commands set status = 'aplicado', result = v_result,
           entity = v_result ->> 'entity', entity_id = nullif(v_result ->> 'entity_id', '')::uuid,
           resulting_revision = nullif(v_result ->> 'revision', '')::int
     where id = p_command_id;
  exception when sqlstate 'CF001' then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
    v_result := jsonb_build_object('ok', false, 'code', v_msg, 'message', v_detail,
      'detail', coalesce(nullif(v_hint, '')::jsonb, '{}'::jsonb));
    update public.commands set status = 'rechazado', result = v_result where id = p_command_id;
  end;
  return v_result;
end $$;

-- ---------- Estados por tiempo (al abrir paneles) ----------
create or replace function public.refresh_lot_states() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  if auth.uid() is not null then perform private.require_role('admin','tostaduria','barra'); end if;
  for r in select b.id from public.roast_batches b join private.lot_stock_rows() s on s.lot_id = b.id
            where b.status is distinct from s.status order by b.roasted_at for update of b loop
    perform private.sync_lot_status(r.id, null, 'cambio por tiempo');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Panel de administración: refresca estados y, si es lunes desde las 8, corre los recurrentes
-- con un id de comando derivado de la fecha (idempotente aunque se abra 20 veces).
create or replace function public.admin_open_panel() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_local timestamp; v_cfg public.settings := private.cfg(); v_res jsonb := null; v_n int;
begin
  perform private.require_role('admin');
  v_n := public.refresh_lot_states();
  v_local := private.now() at time zone v_cfg.timezone;
  if extract(isodow from v_local) = 1 and extract(hour from v_local) >= v_cfg.recurring_hour then
    v_res := public.run_command(md5('recurrentes:' || v_local::date)::uuid, 'correr_recurrentes',
      jsonb_build_object('fecha', v_local::date), null);
  end if;
  return jsonb_build_object('lotes_actualizados', v_n, 'recurrentes', v_res);
end $$;

-- Llamado por pg_cron (opcional, ver README). Corre como dueño.
create or replace function private.cron_lunes() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_date date := private.today(); v_res jsonb;
begin
  perform public.refresh_lot_states();
  insert into public.commands (id, type, payload, payload_hash, status, created_at)
  values (md5('recurrentes:' || v_date)::uuid, 'correr_recurrentes', jsonb_build_object('fecha', v_date),
    encode(sha256(convert_to(jsonb_build_object('t','correr_recurrentes','p',jsonb_build_object('fecha', v_date),'r',null)::text,'UTF8')),'hex'),
    'en_curso', private.now())
  on conflict (id) do nothing;
  if not found then return jsonb_build_object('repetido', true); end if;
  v_res := private.h_correr_recurrentes(jsonb_build_object('fecha', v_date), null, null, md5('recurrentes:' || v_date)::uuid);
  update public.commands set status = 'aplicado', result = jsonb_build_object('ok', true) || v_res where id = md5('recurrentes:' || v_date)::uuid;
  return v_res;
end $$;

-- precio vigente o null (sin error) para mostrar
create or replace function private.current_price(p_list uuid, p_coffee uuid, p_pres text) returns bigint
language sql stable security definer set search_path = '' as $$
  select price from public.price_items where list_id = p_list and coffee_id = p_coffee and presentation = p_pres
     and valid_from <= private.today() order by valid_from desc limit 1
$$;

-- ---------- Lecturas públicas (anon): solo campos autorizados ----------
create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  with lst as (select id from public.price_lists where kind = 'publico' order by name limit 1),
  st as (select * from private.lot_stock_rows())
  select jsonb_build_object(
    'envio', jsonb_build_object('tarifa', (select shipping_fee from public.settings), 'gratis_desde', (select free_shipping_from from public.settings)),
    'zonas', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'nombre', z.name) order by z.sort), '[]') from public.zones z where z.active),
    'cafes', coalesce(jsonb_agg(x order by x ->> 'orden', x ->> 'nombre'), '[]'))
  from (
    select jsonb_build_object(
      'id', c.id, 'nombre', c.name, 'tipo', c.kind, 'notas', c.tasting_notes, 'orden', lpad(c.sort::text, 3, '0'),
      'origen', case when c.kind = 'origen' then g.country || ' · ' || g.region || ' · ' || g.process
                     else (select string_agg(round(bc.pct)::text || ' % ' || gg.country, ' + ' order by bc.pct desc)
                             from public.blend_components bc join public.green_coffees gg on gg.id = bc.green_id where bc.coffee_id = c.id) end,
      'precio_250', private.current_price(lst.id, c.id, 'bolsa_250'),
      'precio_1000', private.current_price(lst.id, c.id, 'bolsa_1000'),
      'disponible_g', (select coalesce(sum(retail_available_g), 0) from st where st.coffee_id = c.id),
      'tostado_el', (select min(roasted_at) from st where st.coffee_id = c.id and st.retail_available_g >= 250),
      'reposo_hasta', (select min(rest_until) from st where st.coffee_id = c.id and st.status = 'En reposo')
    ) as x
    from public.coffees c left join public.green_coffees g on g.id = c.green_id cross join lst
    where c.active
  ) q
$$;

-- Seguimiento minorista: número + celular. Misma respuesta si no existe o no coincide.
create or replace function public.track_order(p_number int, p_phone text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'numero', o.number, 'estado', o.status, 'nombre', split_part(o.retail_name, ' ', 1),
    'entrega', o.fulfillment, 'fecha', o.scheduled_date, 'total', o.total, 'envio', o.shipping_fee,
    'zona', (select name from public.zones where id = o.zone_id),
    'lineas', (select jsonb_agg(jsonb_build_object(
        'cafe', c.name, 'presentacion', l.presentation, 'molienda', l.grind, 'cantidad', l.qty, 'total', l.line_total,
        'tostado_el', (select min(b.roasted_at) from public.order_allocations a join public.roast_batches b on b.id = a.lot_id
                        where a.order_line_id = l.id and a.state <> 'liberada')) order by l.line_no)
      from public.order_lines l join public.coffees c on c.id = l.coffee_id where l.order_id = o.id))
  from public.orders o
  where o.channel = 'web' and o.number = p_number
    and o.retail_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
    and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 8
$$;

-- ---------- Lecturas del portal mayorista ----------
create or replace function public.wholesale_catalog() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_customer uuid; v_list uuid;
begin
  perform private.require_role('mayorista','admin');
  v_customer := private.my_customer();
  select price_list_id into v_list from public.wholesale_customers where id = v_customer;
  if v_list is null then select id into v_list from public.price_lists where kind = 'mayorista' order by name limit 1; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'nombre', c.name, 'tipo', c.kind, 'notas', c.tasting_notes,
      'precio_grano', private.current_price(v_list, c.id, 'kg_grano'),
      'precio_molido', private.current_price(v_list, c.id, 'kg_molido'),
      'proximo_precio', (select jsonb_build_object('desde', pi.valid_from, 'precio', pi.price) from public.price_items pi
                          where pi.list_id = v_list and pi.coffee_id = c.id and pi.presentation = 'kg_grano'
                            and pi.valid_from > private.today() order by pi.valid_from limit 1),
      'disponible_g', (select coalesce(sum(s.wholesale_available_g), 0) from private.lot_stock_rows(c.id) s),
      'tostado_el', (select min(s.roasted_at) from private.lot_stock_rows(c.id) s where s.wholesale_available_g >= 1000)
    ) order by c.sort, c.name), '[]') from public.coffees c where c.active);
end $$;

create or replace function public.credit_status(p_customer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_c uuid;
begin
  if private.my_role() = 'mayorista' then v_c := private.my_customer();
  else perform private.require_role('admin'); v_c := p_customer; end if;
  return private.credit_status(v_c);
end $$;

-- Detalle de pedido con lotes y fechas de tueste. Verifica propietario/rol en servidor.
create or replace function public.order_detail(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare o public.orders; v_role public.app_role := private.my_role(); v_ok boolean := false;
begin
  select * into o from public.orders where id = p_order;
  if not found then return null; end if;
  v_ok := v_role = 'admin'
    or (v_role = 'mayorista' and o.customer_id = private.my_customer())
    or (v_role = 'barra' and (o.channel = 'barra' or (o.channel = 'web' and o.fulfillment = 'retiro')))
    or (v_role = 'reparto' and exists (select 1 from public.route_stops s join public.routes r on r.id = s.route_id
                                        where s.order_id = o.id and r.driver_id = auth.uid()));
  if not v_ok then return null; end if;
  return to_jsonb(o) || jsonb_build_object(
    'cliente', (select name from public.wholesale_customers where id = o.customer_id),
    'zona', (select name from public.zones where id = o.zone_id),
    'intentos_fallidos', private.order_failed_attempts(o.id),
    'lineas', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'tipo', l.kind, 'cafe', c.name, 'bebida', d.name, 'presentacion', l.presentation, 'molienda', l.grind,
        'cantidad', l.qty, 'gramos', l.grams, 'precio', l.unit_price, 'total', l.line_total,
        'lotes', (select coalesce(jsonb_agg(jsonb_build_object('codigo', b.code, 'tostado_el', b.roasted_at, 'gramos', a.grams, 'estado', a.state) order by a.id), '[]')
                    from public.order_allocations a join public.roast_batches b on b.id = a.lot_id where a.order_line_id = l.id)
      ) order by l.line_no), '[]')
      from public.order_lines l left join public.coffees c on c.id = l.coffee_id left join public.drinks d on d.id = l.drink_id
      where l.order_id = o.id),
    'devoluciones', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'numero', r.number, 'estado', r.status,
        'bolsas', r.bags, 'condicion', r.condition, 'resolucion', r.resolution, 'monto', r.amount, 'revision', r.revision)), '[]')
      from public.returns r where r.order_id = o.id));
end $$;

-- ---------- Depósito ----------
create or replace function public.lot_panel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin','tostaduria','barra');
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.lot_id, 'codigo', s.code, 'cafe', c.name, 'cafe_id', c.id, 'tostado_el', s.roasted_at,
      'reposo_hasta', s.rest_until, 'solo_barra_desde', s.barra_only_from, 'estado', s.status,
      'verde_g', b.green_used_g, 'tostado_g', s.roasted_g, 'merma_pct', b.shrink_pct, 'motivo_merma', b.shrink_reason,
      'en_mano_g', s.on_hand_g, 'reservado_g', s.reserved_g, 'disponible_g', s.available_g,
      'minorista_g', s.retail_available_g, 'mayorista_g', s.wholesale_available_g, 'barra_g', s.barra_available_g,
      'bloqueo_pct', s.block_pct, 'protegido_g', case when s.status = 'Disponible' then s.protected_g else 0 end,
      'costo_kg', s.cost_per_kg, 'revision', b.revision,
      'envasado', (select coalesce(jsonb_object_agg(format, n), '{}') from
                    (select format, sum(bags) n from public.packaging_runs where lot_id = s.lot_id group by format) z),
      'consumido_g', (select coalesce(-sum(grams), 0) from public.lot_movements where lot_id = s.lot_id and kind in ('barra','entrega')),
      'merma_devolucion_g', (select coalesce(sum(grams), 0) from public.waste_records where lot_id = s.lot_id)
    ) order by s.roasted_at desc), '[]')
    from private.lot_stock_rows() s join public.roast_batches b on b.id = s.lot_id join public.coffees c on c.id = s.coffee_id);
end $$;

create or replace function public.green_panel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin','tostaduria');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'nombre', g.name, 'pais', g.country, 'region', g.region,
      'proceso', g.process, 'costo_kg', g.cost_per_kg, 'stock_g', private.green_stock(g.id),
      'ultimo_tueste', (select max(b.roasted_at) from public.roast_inputs ri join public.roast_batches b on b.id = ri.lot_id where ri.green_id = g.id))
    order by g.name), '[]') from public.green_coffees g where g.active);
end $$;

create or replace function public.supply_panel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin','tostaduria','barra');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'codigo', s.code, 'nombre', s.name, 'unidad', s.unit,
      'stock', private.supply_stock(s.id)) order by s.name), '[]') from public.supplies s);
end $$;

-- ---------- Barra ----------
create or replace function public.shift_panel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t public.bar_shifts;
begin
  perform private.require_role('admin','barra');
  select * into t from public.bar_shifts where status = 'abierto';
  return jsonb_build_object(
    'turno', case when t.id is null then null else to_jsonb(t) || jsonb_build_object(
        'esperado', private.shift_expected_cash(t.id),
        'lote', (select jsonb_build_object('id', s.lot_id, 'codigo', s.code, 'cafe', c.name, 'tostado_el', s.roasted_at,
                   'estado', s.status, 'barra_g', s.barra_available_g)
                 from private.lot_stock_rows(null, t.lot_id) s join public.coffees c on c.id = s.coffee_id),
        'tickets', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'numero', o.number, 'total', o.total,
                      'metodo', o.payment_method, 'hora', o.created_at,
                      'items', (select string_agg(l.qty || '× ' || d.name || case when l.almond then ' (almendras)' else '' end, ', ' order by l.line_no)
                                  from public.order_lines l join public.drinks d on d.id = l.drink_id where l.order_id = o.id))
                    order by o.created_at desc), '[]') from public.orders o where o.shift_id = t.id),
        'ventas', (select jsonb_build_object('total', coalesce(sum(o.total), 0), 'tickets', count(*)) from public.orders o where o.shift_id = t.id)
      ) end,
    'bebidas', (select coalesce(jsonb_agg(to_jsonb(d) order by d.sort), '[]') from public.drinks d where d.active),
    'almendras_extra', (private.cfg()).almond_extra,
    'umbral_caja', (private.cfg()).cash_diff_threshold,
    'lotes_barra', (select coalesce(jsonb_agg(jsonb_build_object('id', s.lot_id, 'codigo', s.code, 'cafe', c.name,
                     'tostado_el', s.roasted_at, 'estado', s.status, 'barra_g', s.barra_available_g, 'reposo_hasta', s.rest_until)
                     order by s.status desc, s.roasted_at), '[]')
                    from private.lot_stock_rows() s join public.coffees c on c.id = s.coffee_id where s.status <> 'Agotado'),
    'retiros', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'numero', o.number, 'nombre', o.retail_name,
                  'celular', o.retail_phone, 'estado', o.status, 'total', o.total, 'revision', o.revision) order by o.number), '[]')
                from public.orders o where o.channel = 'web' and o.fulfillment = 'retiro'
                  and o.status in ('Confirmado','En preparación','Listo'))
  );
end $$;

-- ---------- Reparto ----------
create or replace function public.route_board(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_date date := coalesce(p_date, private.today()); v_role public.app_role := private.my_role();
begin
  perform private.require_role('admin','reparto');
  return jsonb_build_object('fecha', v_date,
    'recorridos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'zona', z.name, 'zona_id', z.id, 'franja', r.slot, 'estado', r.status, 'capacidad_g', r.capacity_g,
        'carga_g', private.route_load_g(r.id), 'revision', r.revision,
        'repartidor', (select full_name from public.profiles where id = r.driver_id),
        'paradas', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', s.id, 'orden', s.seq, 'resultado', s.result, 'nota', s.note, 'pedido_id', o.id, 'numero', o.number,
            'estado', o.status, 'revision', o.revision, 'canal', o.channel,
            'nombre', coalesce(wc.name, o.retail_name), 'telefono', coalesce(wc.phone, o.retail_phone),
            'direccion', o.address, 'total', o.total, 'cobrar', o.channel = 'web' and not exists (select 1 from public.order_payments op where op.order_id = o.id),
            'gramos', (select coalesce(sum(grams), 0) from public.order_lines where order_id = o.id and kind = 'cafe'),
            'intentos_fallidos', private.order_failed_attempts(o.id),
            'reposicion', o.replacement_for_return_id is not null,
            'lineas', (select jsonb_agg(jsonb_build_object('id', l.id, 'cafe', c.name, 'presentacion', l.presentation,
                         'molienda', l.grind, 'cantidad', l.qty) order by l.line_no)
                       from public.order_lines l join public.coffees c on c.id = l.coffee_id where l.order_id = o.id)
          ) order by s.seq), '[]')
          from public.route_stops s join public.orders o on o.id = s.order_id
          left join public.wholesale_customers wc on wc.id = o.customer_id
          where s.route_id = r.id and s.result <> 'quitado')
      ) order by r.slot, z.sort), '[]')
      from public.routes r join public.zones z on z.id = r.zone_id
      where r.route_date = v_date and (v_role = 'admin' or r.driver_id = auth.uid())),
    'pendientes', case when v_role = 'admin' then (select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'numero', o.number, 'estado', o.status, 'canal', o.channel, 'zona', z.name, 'zona_id', o.zone_id,
        'nombre', coalesce(wc.name, o.retail_name), 'direccion', o.address, 'fecha', o.scheduled_date, 'revision', o.revision,
        'gramos', (select coalesce(sum(grams), 0) from public.order_lines where order_id = o.id and kind = 'cafe'),
        'intentos_fallidos', private.order_failed_attempts(o.id), 'reposicion', o.replacement_for_return_id is not null
      ) order by o.scheduled_date, o.number), '[]')
      from public.orders o left join public.zones z on z.id = o.zone_id left join public.wholesale_customers wc on wc.id = o.customer_id
      where o.fulfillment = 'envio' and o.status in ('Confirmado','En preparación','Listo','Para reprogramar')
        and not exists (select 1 from public.route_stops s where s.order_id = o.id and s.result = 'pendiente')) end,
    'repartidores', case when v_role = 'admin' then (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', full_name)), '[]')
      from public.profiles where role = 'reparto') end);
end $$;
