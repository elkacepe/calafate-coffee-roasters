-- =====================================================================
-- Calafate Coffee Roasters · 03 · Manejadores de comandos
-- Firma común: (payload jsonb, revisión esperada, actor, id de comando) → jsonb
-- Se llaman SOLO desde public.run_command, que agrega idempotencia y registro.
-- =====================================================================

-- ========================= VENTAS =========================

-- Pedido web minorista (sin cuenta): nombre + celular. Se confirma y reserva en el acto.
create or replace function private.h_crear_pedido_web(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_id uuid; v_phone text := regexp_replace(coalesce(p ->> 'celular', ''), '\D', '', 'g');
        v_name text := btrim(coalesce(p ->> 'nombre', '')); v_ful text := coalesce(p ->> 'entrega', 'retiro');
        v_zone uuid := nullif(p ->> 'zona_id', '')::uuid; v_list uuid; v_res jsonb; v_date date;
begin
  if length(v_name) < 2 then perform private.biz('falta_nombre', 'Contanos tu nombre.', '{}'); end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then
    perform private.biz('celular_invalido', 'Revisá tu celular: con característica, solo números.', '{}');
  end if;
  if v_ful not in ('retiro','envio') then perform private.biz('entrega_invalida', 'Elegí retiro o envío.', '{}'); end if;
  if v_ful = 'envio' and (v_zone is null or length(btrim(coalesce(p ->> 'direccion', ''))) < 4) then
    perform private.biz('falta_direccion', 'Para el envío necesitamos zona y dirección.', '{}');
  end if;
  if v_zone is not null and not exists (select 1 from public.zones where id = v_zone and active) then
    perform private.biz('zona_invalida', 'Esa zona no tiene reparto. Elegí otra o retirá en el local.', '{}');
  end if;
  v_date := coalesce(nullif(p ->> 'fecha', '')::date,
    case when extract(isodow from private.today()) = 7 then private.today() + 1 else private.today() end);
  if v_date < private.today() or extract(isodow from v_date) = 7 then
    perform private.biz('fecha_invalida', 'Elegí una fecha desde hoy, de lunes a sábado.', '{}');
  end if;
  select id into v_list from public.price_lists where kind = 'publico' order by name limit 1;

  insert into public.orders (channel, status, retail_name, retail_phone, fulfillment, zone_id, address,
    scheduled_date, price_list_id, notes, created_by, created_at)
  values ('web', 'Borrador', v_name, v_phone, v_ful, case when v_ful = 'envio' then v_zone end,
    case when v_ful = 'envio' then btrim(p ->> 'direccion') end, v_date, v_list,
    left(p ->> 'notas', 300), p_actor, private.now())
  returning id into v_id;
  perform private.emit(p_cmd, 'pedido', v_id, 1, 'pedido_creado', null, 'Borrador', '{}', null);
  perform private.insert_coffee_lines(v_id, p -> 'items', array['bolsa_250','bolsa_1000']);
  v_res := private.confirm_order(v_id, p_cmd);
  return v_res || jsonb_build_object('entity', 'pedido', 'entity_id', v_id);
end $$;

-- Pedido mayorista: el cliente sale del perfil (nunca del navegador). Admin puede indicar cliente.
create or replace function private.h_crear_pedido_mayorista(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_customer uuid; c public.wholesale_customers; v_id uuid; v_res jsonb; v_rev int;
begin
  if private.my_role() = 'mayorista' then v_customer := private.my_customer();
  else v_customer := nullif(p ->> 'cliente_id', '')::uuid; end if;
  select * into c from public.wholesale_customers where id = v_customer and active;
  if not found then perform private.biz('cliente_invalido', 'No encontramos ese cliente mayorista.', '{}'); end if;

  insert into public.orders (channel, status, customer_id, fulfillment, zone_id, address, scheduled_date,
    price_list_id, notes, created_by, created_at)
  values ('mayorista', 'Borrador', c.id, 'envio', c.zone_id, c.address,
    coalesce(nullif(p ->> 'fecha', '')::date, private.today() + 1), c.price_list_id, left(p ->> 'notas', 300),
    p_actor, private.now())
  returning id, revision into v_id, v_rev;
  perform private.insert_coffee_lines(v_id, p -> 'items', array['kg_grano','kg_molido']);
  perform private.emit(p_cmd, 'pedido', v_id, v_rev, 'pedido_creado', null, 'Borrador', '{}', null);
  if coalesce((p ->> 'confirmar')::boolean, false) then
    v_res := private.confirm_order(v_id, p_cmd);
  else
    v_res := jsonb_build_object('pedido_id', v_id, 'numero', (select number from public.orders where id = v_id),
      'estado', 'Borrador', 'revision', v_rev);
  end if;
  return v_res || jsonb_build_object('entity', 'pedido', 'entity_id', v_id);
end $$;

create or replace function private.lock_order_for_actor(p_order uuid) returns public.orders
language plpgsql set search_path = '' as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or (private.my_role() = 'mayorista' and o.customer_id is distinct from private.my_customer()) then
    perform private.biz('pedido_inexistente', 'No encontramos ese pedido.', '{}');
  end if;
  return o;
end $$;

create or replace function private.h_editar_borrador(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  if o.status <> 'Borrador' then
    perform private.biz('no_editable', format('El pedido está «%s» y ya no se puede editar.', o.status), '{}');
  end if;
  delete from public.order_lines where order_id = o.id;
  perform private.insert_coffee_lines(o.id, p -> 'items',
    case when o.channel = 'mayorista' then array['kg_grano','kg_molido'] else array['bolsa_250','bolsa_1000'] end);
  update public.orders set notes = coalesce(left(p ->> 'notas', 300), notes),
         scheduled_date = coalesce(nullif(p ->> 'fecha', '')::date, scheduled_date), revision = revision + 1
   where id = o.id returning * into o;
  perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'borrador_editado', 'Borrador', 'Borrador', p -> 'items', null);
  return jsonb_build_object('entity', 'pedido', 'entity_id', o.id, 'pedido_id', o.id, 'revision', o.revision, 'estado', o.status);
end $$;

create or replace function private.h_confirmar_pedido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  return private.confirm_order(o.id, p_cmd) || jsonb_build_object('entity', 'pedido', 'entity_id', o.id);
end $$;

create or replace function private.h_cambiar_estado_pedido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders; v_to public.order_status := (p ->> 'a')::public.order_status; v_from public.order_status;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  if v_to not in ('En preparación','Listo') then
    perform private.biz('transicion_invalida', 'Desde acá solo se pasa a «En preparación» o «Listo».', '{}');
  end if;
  v_from := o.status;
  perform private.assert_transition(o.status, v_to);
  update public.orders set status = v_to, revision = revision + 1 where id = o.id returning * into o;
  perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'estado_pedido', v_from::text, v_to::text, '{}', null);
  return jsonb_build_object('entity', 'pedido', 'entity_id', o.id, 'estado', o.status, 'revision', o.revision);
end $$;

create or replace function private.h_cancelar_pedido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders; v_from public.order_status; v_n int;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  if private.my_role() = 'mayorista' and o.status not in ('Borrador','Confirmado') then
    perform private.biz('no_cancelable', 'Ese pedido ya está en preparación. Escribinos y lo vemos.', '{}');
  end if;
  v_from := o.status;
  perform private.assert_transition(o.status, 'Cancelado');
  update public.route_stops set result = 'quitado' where order_id = o.id and result = 'pendiente';
  v_n := private.release_order_allocations(o.id, p_cmd, 'pedido cancelado');
  update public.orders set status = 'Cancelado', cancelled_at = private.now(), revision = revision + 1,
         notes = concat_ws(' · ', notes, 'Cancelado: ' || nullif(p ->> 'motivo', ''))
   where id = o.id returning * into o;
  perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'pedido_cancelado', v_from::text, 'Cancelado',
    jsonb_build_object('reservas_liberadas', v_n), p ->> 'motivo');
  return jsonb_build_object('entity', 'pedido', 'entity_id', o.id, 'estado', o.status, 'revision', o.revision,
    'reservas_liberadas', v_n);
end $$;

-- Recurrentes del lunes a las 8 (idempotente por plantilla + fecha).
create or replace function private.h_correr_recurrentes(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_date date := coalesce(nullif(p ->> 'fecha', '')::date, private.today()); t record; v_id uuid;
        v_cs jsonb; v_out jsonb := '[]'; v_state text; v_msg text;
begin
  for t in select r.*, c.name as cname, c.price_list_id, c.zone_id, c.address
             from public.recurring_orders r join public.wholesale_customers c on c.id = r.customer_id
            where r.active and c.active and r.weekday = extract(isodow from v_date)
            order by c.name loop
    continue when exists (select 1 from public.orders where recurring_id = t.id and recurring_date = v_date);
    insert into public.orders (channel, status, customer_id, fulfillment, zone_id, address, scheduled_date,
      price_list_id, recurring_id, recurring_date, created_by, created_at)
    values ('mayorista', 'Borrador', t.customer_id, 'envio', t.zone_id, t.address, v_date, t.price_list_id,
      t.id, v_date, p_actor, private.now()) returning id into v_id;
    insert into public.order_lines (order_id, line_no, kind, coffee_id, presentation, grind, qty, grams)
    select v_id, row_number() over (order by l.id), 'cafe', l.coffee_id, l.presentation, l.grind, l.qty, l.qty * 1000
      from public.recurring_order_lines l where l.recurring_id = t.id;
    perform private.emit(p_cmd, 'pedido', v_id, 1, 'recurrente_generado', null, 'Borrador', '{}', null);

    v_cs := private.credit_status(t.customer_id, 0, v_id);
    if (v_cs ->> 'bloqueado')::boolean then
      update public.orders set status = 'Retenido', hold_reason = v_cs ->> 'motivo', revision = revision + 1 where id = v_id;
      perform private.emit(p_cmd, 'pedido', v_id, 2, 'pedido_retenido', 'Borrador', 'Retenido', v_cs, v_cs ->> 'mensaje');
      v_state := 'Retenido'; v_msg := v_cs ->> 'mensaje';
    else
      begin
        perform private.confirm_order(v_id, p_cmd);
        v_state := 'Confirmado'; v_msg := null;
      exception when sqlstate 'CF001' then
        -- sin stock o límite: queda retenido sin ninguna reserva parcial (el subbloque se revirtió)
        update public.orders set status = 'Retenido', hold_reason = sqlerrm, revision = revision + 1 where id = v_id;
        perform private.emit(p_cmd, 'pedido', v_id, 2, 'pedido_retenido', 'Borrador', 'Retenido', '{}', sqlerrm);
        v_state := 'Retenido'; v_msg := sqlerrm;
      end;
    end if;
    v_out := v_out || jsonb_build_object('pedido_id', v_id, 'cliente', t.cname, 'estado', v_state, 'motivo', v_msg);
  end loop;
  return jsonb_build_object('fecha', v_date, 'pedidos', v_out);
end $$;

create or replace function private.h_liberar_retenido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  if o.status <> 'Retenido' then
    perform private.biz('no_retenido', format('El pedido está «%s», no retenido.', o.status), '{}');
  end if;
  return private.confirm_order(o.id, p_cmd) || jsonb_build_object('entity', 'pedido', 'entity_id', o.id);
end $$;

-- ========================= TOSTADURÍA Y DEPÓSITO =========================

create or replace function private.green_stock(p_green uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(grams), 0)::int from public.green_movements where green_id = p_green
$$;

create or replace function private.h_ingresar_verde(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare g public.green_coffees; v_g int := (p ->> 'gramos')::int; v_cost bigint := nullif(p ->> 'costo_kg', '')::bigint;
begin
  select * into g from public.green_coffees where id = (p ->> 'verde_id')::uuid for update;
  if not found then perform private.biz('verde_inexistente', 'No encontramos ese café verde.', '{}'); end if;
  if v_g is null or v_g <= 0 then perform private.biz('cantidad_invalida', 'Cargá los kilos que entraron.', '{}'); end if;
  if v_cost is not null and v_cost > 0 then update public.green_coffees set cost_per_kg = v_cost where id = g.id; end if;
  insert into public.green_movements (green_id, kind, grams, cost_per_kg, command_id, note, created_by, created_at)
  values (g.id, 'ingreso', v_g, coalesce(v_cost, g.cost_per_kg), p_cmd, p ->> 'nota', p_actor, private.now());
  perform private.emit(p_cmd, 'verde', g.id, null, 'verde_ingresado', null, null, jsonb_build_object('gramos', v_g), null);
  return jsonb_build_object('entity', 'verde', 'entity_id', g.id, 'stock_g', private.green_stock(g.id));
end $$;

create or replace function private.h_registrar_tueste(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare c public.coffees; v_green int := (p ->> 'verde_g')::int; v_roasted int := (p ->> 'tostado_g')::int;
        v_reason text := nullif(btrim(coalesce(p ->> 'motivo', '')), ''); v_cfg public.settings := private.cfg();
        v_now timestamptz := private.now(); v_shrink numeric; v_lot uuid; v_code text; v_seq int;
        v_cost_sum numeric := 0; v_assigned int := 0; i record; v_inputs jsonb := '[]'; v_g int; v_n int; v_k int := 0;
begin
  select * into c from public.coffees where id = (p ->> 'cafe_id')::uuid;
  if not found then perform private.biz('cafe_inexistente', 'Elegí qué café tostaste.', '{}'); end if;
  if v_green is null or v_green <= 0 then perform private.biz('falta_verde', 'Cargá cuántos gramos de verde entraron a la tostadora.', '{}'); end if;
  if v_roasted is null or v_roasted <= 0 then perform private.biz('falta_tostado', 'Pesá el café tostado y cargá los gramos reales.', '{}'); end if;
  if v_roasted > v_green then perform private.biz('tostado_mayor', 'El tostado no puede pesar más que el verde. Revisá la balanza.', '{}'); end if;

  v_shrink := round((v_green - v_roasted) * 100.0 / v_green, 2);
  if (v_shrink < v_cfg.shrink_min_pct or v_shrink > v_cfg.shrink_max_pct) and v_reason is null then
    perform private.biz('merma_fuera_de_rango',
      format('La merma da %s %%, fuera del rango %s–%s %%. Si el peso está bien, confirmá con un motivo.',
        replace(v_shrink::text, '.', ','), v_cfg.shrink_min_pct::int, v_cfg.shrink_max_pct::int),
      jsonb_build_object('merma', v_shrink));
  end if;

  -- Insumos de verde: un origen o los componentes del blend (el resto se asigna al último).
  if c.kind = 'origen' then
    v_inputs := jsonb_build_array(jsonb_build_object('green_id', c.green_id, 'grams', v_green));
  else
    select count(*) into v_n from public.blend_components where coffee_id = c.id;
    if v_n = 0 then perform private.biz('blend_sin_receta', 'El blend no tiene receta de verdes.', '{}'); end if;
    for i in select * from public.blend_components where coffee_id = c.id order by pct desc, green_id loop
      v_k := v_k + 1;
      v_g := case when v_k = v_n then v_green - v_assigned else round(v_green * i.pct / 100.0)::int end;
      v_assigned := v_assigned + v_g;
      v_inputs := v_inputs || jsonb_build_object('green_id', i.green_id, 'grams', v_g);
    end loop;
  end if;

  -- Bloqueo del verde en orden fijo y validación de stock.
  perform 1 from public.green_coffees where id in (select (e ->> 'green_id')::uuid from jsonb_array_elements(v_inputs) e)
   order by id for update;
  for i in select (e ->> 'green_id')::uuid as gid, (e ->> 'grams')::int as g, gc.name, gc.cost_per_kg
             from jsonb_array_elements(v_inputs) e join public.green_coffees gc on gc.id = (e ->> 'green_id')::uuid loop
    if private.green_stock(i.gid) < i.g then
      perform private.biz('verde_insuficiente',
        format('Quedan %s de %s y el tueste pide %s.', private.fmt_g(private.green_stock(i.gid)), i.name, private.fmt_g(i.g)),
        jsonb_build_object('verde', i.name, 'stock_g', private.green_stock(i.gid)));
    end if;
    v_cost_sum := v_cost_sum + i.g::numeric * i.cost_per_kg;
  end loop;

  perform pg_advisory_xact_lock(hashtext('lot_code'));
  select count(*) + 1 into v_seq from public.roast_batches
   where (roasted_at at time zone v_cfg.timezone)::date = (v_now at time zone v_cfg.timezone)::date;
  v_code := 'L' || to_char(v_now at time zone v_cfg.timezone, 'YYMMDD') || '-' || lpad(v_seq::text, 2, '0');

  insert into public.roast_batches (code, coffee_id, roasted_at, green_used_g, roasted_g, shrink_reason,
    rest_until, barra_only_from, cost_per_kg, wholesale_block_pct, status, created_by, command_id, created_at)
  values (v_code, c.id, v_now, v_green, v_roasted, v_reason,
    v_now + make_interval(hours => v_cfg.rest_hours), v_now + make_interval(days => v_cfg.fresh_days),
    round(v_cost_sum / v_roasted)::bigint, v_cfg.wholesale_block_pct, 'En reposo', p_actor, p_cmd, v_now)
  returning id into v_lot;

  for i in select (e ->> 'green_id')::uuid as gid, (e ->> 'grams')::int as g, gc.cost_per_kg
             from jsonb_array_elements(v_inputs) e join public.green_coffees gc on gc.id = (e ->> 'green_id')::uuid loop
    insert into public.roast_inputs (lot_id, green_id, grams, cost_per_kg) values (v_lot, i.gid, i.g, i.cost_per_kg);
    insert into public.green_movements (green_id, kind, grams, cost_per_kg, lot_id, command_id, created_by, created_at)
    values (i.gid, 'tueste', -i.g, i.cost_per_kg, v_lot, p_cmd, p_actor, v_now);
  end loop;
  insert into public.lot_movements (lot_id, kind, grams, command_id, note, created_by, created_at)
  values (v_lot, 'tueste', v_roasted, p_cmd, 'Ingreso de tueste', p_actor, v_now);

  perform private.emit(p_cmd, 'lote', v_lot, 1, 'lote_registrado', null, 'En reposo',
    jsonb_build_object('verde_g', v_green, 'tostado_g', v_roasted, 'merma_pct', v_shrink), v_reason);
  return jsonb_build_object('entity', 'lote', 'entity_id', v_lot, 'lote_id', v_lot, 'codigo', v_code,
    'merma_pct', v_shrink, 'disponible_desde', v_now + make_interval(hours => v_cfg.rest_hours),
    'mensaje', format('Lote %s registrado. Queda en reposo: no se puede vender hasta %s.', v_code,
      private.human_when(v_now + make_interval(hours => v_cfg.rest_hours))));
end $$;

create or replace function private.supply_stock(p_supply uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(qty), 0)::int from public.supply_movements where supply_id = p_supply
$$;

create or replace function private.h_envasar(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare s record; v_fmt text := p ->> 'formato'; v_bags int := (p ->> 'bolsas')::int; v_g int; v_packed int;
        v_supply uuid; v_id uuid;
begin
  if v_fmt not in ('bolsa_250','bolsa_1000') then perform private.biz('formato_invalido', 'Elegí bolsa de 250 g o de 1 kg.', '{}'); end if;
  if v_bags is null or v_bags <= 0 then perform private.biz('cantidad_invalida', 'Cargá cuántas bolsas envasaste.', '{}'); end if;
  perform 1 from public.roast_batches where id = (p ->> 'lote_id')::uuid for update;
  select * into s from private.lot_stock_rows(null, (p ->> 'lote_id')::uuid);
  if not found then perform private.biz('lote_inexistente', 'No encontramos ese lote.', '{}'); end if;
  v_g := v_bags * private.unit_grams(v_fmt);
  select coalesce(sum(grams), 0) into v_packed from public.packaging_runs where lot_id = s.lot_id;
  if v_packed + v_g > s.roasted_g then
    perform private.biz('envasado_excede', format('El lote %s no tiene café suficiente para %s bolsas.', s.code, v_bags), '{}');
  end if;
  select id into v_supply from public.supplies where code = v_fmt;
  if private.supply_stock(v_supply) < v_bags then
    perform private.biz('sin_bolsas', format('Quedan %s bolsas vacías de ese formato. Cargá insumos primero.',
      private.supply_stock(v_supply)), '{}');
  end if;
  insert into public.packaging_runs (lot_id, format, bags, grams, command_id, created_by, created_at)
  values (s.lot_id, v_fmt, v_bags, v_g, p_cmd, p_actor, private.now()) returning id into v_id;
  insert into public.supply_movements (supply_id, kind, qty, packaging_id, command_id, created_by, created_at)
  values (v_supply, 'envasado', -v_bags, v_id, p_cmd, p_actor, private.now());
  perform private.emit(p_cmd, 'lote', s.lot_id, null, 'envasado', null, null,
    jsonb_build_object('formato', v_fmt, 'bolsas', v_bags), null);
  return jsonb_build_object('entity', 'lote', 'entity_id', s.lot_id, 'envasado_id', v_id);
end $$;

create or replace function private.h_ingresar_insumo(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_s uuid := (p ->> 'insumo_id')::uuid; v_q int := (p ->> 'cantidad')::int;
begin
  if not exists (select 1 from public.supplies where id = v_s) then perform private.biz('insumo_inexistente', 'No encontramos ese insumo.', '{}'); end if;
  if v_q is null or v_q = 0 then perform private.biz('cantidad_invalida', 'Cargá una cantidad.', '{}'); end if;
  perform 1 from public.supplies where id = v_s for update;
  if v_q < 0 and private.supply_stock(v_s) + v_q < 0 then
    perform private.biz('ajuste_negativo', 'El ajuste deja el insumo en negativo.', '{}');
  end if;
  insert into public.supply_movements (supply_id, kind, qty, command_id, note, created_by, created_at)
  values (v_s, case when v_q > 0 then 'ingreso' else 'ajuste' end, v_q, p_cmd, p ->> 'nota', p_actor, private.now());
  perform private.emit(p_cmd, 'insumo', v_s, null, 'insumo_movido', null, null, jsonb_build_object('cantidad', v_q), p ->> 'nota');
  return jsonb_build_object('entity', 'insumo', 'entity_id', v_s, 'stock', private.supply_stock(v_s));
end $$;

create or replace function private.h_bloquear_lote(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare b public.roast_batches; v_pct numeric := (p ->> 'pct')::numeric; v_old numeric;
begin
  select * into b from public.roast_batches where id = (p ->> 'lote_id')::uuid for update;
  if not found then perform private.biz('lote_inexistente', 'No encontramos ese lote.', '{}'); end if;
  perform private.check_rev(b.revision, p_rev, 'el lote');
  if v_pct is null or v_pct < 0 or v_pct > 100 then perform private.biz('pct_invalido', 'El bloqueo va de 0 a 100 %.', '{}'); end if;
  v_old := b.wholesale_block_pct;
  update public.roast_batches set wholesale_block_pct = v_pct, revision = revision + 1 where id = b.id returning * into b;
  perform private.emit(p_cmd, 'lote', b.id, b.revision, 'bloqueo_mayorista', v_old::text, v_pct::text, '{}', p ->> 'motivo');
  return jsonb_build_object('entity', 'lote', 'entity_id', b.id, 'revision', b.revision);
end $$;

-- ========================= BARRA =========================

create or replace function private.h_abrir_turno(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare s record; v_id uuid; v_cash bigint := coalesce((p ->> 'efectivo_inicial')::bigint, 0);
begin
  if exists (select 1 from public.bar_shifts where status = 'abierto') then
    perform private.biz('turno_abierto', 'Ya hay un turno abierto. Cerralo antes de abrir otro.', '{}');
  end if;
  perform 1 from public.roast_batches where id = (p ->> 'lote_id')::uuid for update;
  select * into s from private.lot_stock_rows(null, (p ->> 'lote_id')::uuid);
  if not found or s.barra_available_g <= 0 then
    perform private.biz('lote_no_apto',
      case when s.status = 'En reposo' then format('Ese lote todavía está en reposo, elegí otro o esperá hasta %s.', private.human_when(s.rest_until))
           else 'Ese lote no tiene café para barra. Elegí otro.' end, '{}');
  end if;
  insert into public.bar_shifts (opened_at, opened_by, lot_id, opening_cash)
  values (private.now(), p_actor, s.lot_id, v_cash) returning id into v_id;
  perform private.emit(p_cmd, 'turno', v_id, 1, 'turno_abierto', null, 'abierto', jsonb_build_object('lote', s.code), null);
  return jsonb_build_object('entity', 'turno', 'entity_id', v_id, 'turno_id', v_id);
end $$;

create or replace function private.h_cambiar_lote_turno(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare t public.bar_shifts; s record; v_old uuid;
begin
  select * into t from public.bar_shifts where id = (p ->> 'turno_id')::uuid for update;
  if not found or t.status <> 'abierto' then perform private.biz('turno_cerrado', 'Ese turno ya está cerrado.', '{}'); end if;
  perform private.check_rev(t.revision, p_rev, 'el turno');
  perform 1 from public.roast_batches where id = (p ->> 'lote_id')::uuid for update;
  select * into s from private.lot_stock_rows(null, (p ->> 'lote_id')::uuid);
  if not found or s.barra_available_g <= 0 then
    perform private.biz('lote_no_apto',
      case when s.status = 'En reposo' then format('Ese lote todavía está en reposo, elegí otro o esperá hasta %s.', private.human_when(s.rest_until))
           else 'Ese lote no tiene café para barra. Elegí otro.' end, '{}');
  end if;
  v_old := t.lot_id;
  update public.bar_shifts set lot_id = s.lot_id, revision = revision + 1 where id = t.id returning * into t;
  perform private.emit(p_cmd, 'turno', t.id, t.revision, 'lote_de_barra', v_old::text, s.lot_id::text, jsonb_build_object('lote', s.code), null);
  return jsonb_build_object('entity', 'turno', 'entity_id', t.id, 'revision', t.revision);
end $$;

-- Ticket de barra: descuenta por receta (gramos del lote del turno + leche) en una transacción.
create or replace function private.h_vender_barra(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare t public.bar_shifts; s record; it jsonb; d public.drinks; v_qty int; v_alm boolean; n int := 0;
        v_need_g int := 0; v_milk int := 0; v_almond_ml int := 0; v_total bigint := 0; v_id uuid; v_line uuid;
        v_unit bigint; v_cfg public.settings := private.cfg(); v_whole uuid; v_alm_s uuid;
        v_method text := coalesce(p ->> 'metodo', 'efectivo'); o public.orders;
begin
  if v_method not in ('efectivo','tarjeta','transferencia','qr') then
    perform private.biz('metodo_invalido', 'Elegí cómo pagó: efectivo, tarjeta, transferencia o QR.', '{}');
  end if;
  select * into t from public.bar_shifts where id = (p ->> 'turno_id')::uuid for update;
  if not found or t.status <> 'abierto' then perform private.biz('turno_cerrado', 'No hay turno abierto. Abrí la caja para vender.', '{}'); end if;
  if jsonb_array_length(coalesce(p -> 'items', '[]')) = 0 then perform private.biz('ticket_vacio', 'Tocá al menos una bebida.', '{}'); end if;

  for it in select * from jsonb_array_elements(p -> 'items') loop
    select * into d from public.drinks where id = (it ->> 'bebida_id')::uuid and active;
    if not found then perform private.biz('bebida_inexistente', 'Esa bebida no está en la carta.', '{}'); end if;
    v_qty := coalesce((it ->> 'cantidad')::int, 1);
    if v_qty < 1 or v_qty > 30 then perform private.biz('cantidad_invalida', 'Cantidad entre 1 y 30.', '{}'); end if;
    v_alm := coalesce((it ->> 'almendras')::boolean, false) and d.milk_ml > 0;
    v_need_g := v_need_g + d.coffee_g * v_qty;
    if v_alm then v_almond_ml := v_almond_ml + d.milk_ml * v_qty; else v_milk := v_milk + d.milk_ml * v_qty; end if;
  end loop;

  perform 1 from public.roast_batches where id = t.lot_id for update;
  select * into s from private.lot_stock_rows(null, t.lot_id);
  if s.barra_available_g < v_need_g then
    perform private.biz('lote_sin_cafe',
      format('Al lote %s le quedan %s para barra y este ticket necesita %s. Cambiá el lote del turno.',
        s.code, private.fmt_g(s.barra_available_g), private.fmt_g(v_need_g)),
      jsonb_build_object('lote', s.code, 'disponible_g', s.barra_available_g, 'necesario_g', v_need_g));
  end if;
  select id into v_whole from public.supplies where code = 'leche';
  select id into v_alm_s from public.supplies where code = 'leche_almendras';
  perform 1 from public.supplies where id in (v_whole, v_alm_s) order by id for update;
  if v_milk > 0 and private.supply_stock(v_whole) < v_milk then
    perform private.biz('sin_leche', format('Queda %s ml de leche y el ticket pide %s ml. Cargá leche en insumos.',
      private.supply_stock(v_whole), v_milk), '{}');
  end if;
  if v_almond_ml > 0 and private.supply_stock(v_alm_s) < v_almond_ml then
    perform private.biz('sin_leche', format('Queda %s ml de leche de almendras y el ticket pide %s ml.',
      private.supply_stock(v_alm_s), v_almond_ml), '{}');
  end if;

  insert into public.orders (channel, status, fulfillment, shift_id, payment_method, created_by, created_at,
    confirmed_at, delivered_at)
  values ('barra', 'Confirmado', 'barra', t.id, v_method, p_actor, private.now(), private.now(), private.now())
  returning id into v_id;

  for it in select * from jsonb_array_elements(p -> 'items') loop
    n := n + 1;
    select * into d from public.drinks where id = (it ->> 'bebida_id')::uuid;
    v_qty := coalesce((it ->> 'cantidad')::int, 1);
    v_alm := coalesce((it ->> 'almendras')::boolean, false) and d.milk_ml > 0;
    v_unit := d.price + case when v_alm then v_cfg.almond_extra else 0 end;
    insert into public.order_lines (order_id, line_no, kind, drink_id, qty, grams, milk_ml, almond, unit_price, line_total)
    values (v_id, n, 'bebida', d.id, v_qty, d.coffee_g * v_qty, d.milk_ml * v_qty, v_alm, v_unit, v_unit * v_qty)
    returning id into v_line;
    v_total := v_total + v_unit * v_qty;
    insert into public.lot_movements (lot_id, kind, grams, order_line_id, command_id, created_by, created_at)
    values (t.lot_id, 'barra', -d.coffee_g * v_qty, v_line, p_cmd, p_actor, private.now());
    if d.milk_ml > 0 then
      insert into public.supply_movements (supply_id, kind, qty, order_line_id, command_id, created_by, created_at)
      values (case when v_alm then v_alm_s else v_whole end, 'barra', -d.milk_ml * v_qty, v_line, p_cmd, p_actor, private.now());
    end if;
  end loop;

  update public.orders set status = 'Entregado', subtotal = v_total, shipping_fee = 0, total = v_total,
         revision = revision + 1 where id = v_id returning * into o;
  insert into public.order_payments (order_id, amount, method, command_id, created_by, created_at)
  values (v_id, v_total, v_method, p_cmd, p_actor, private.now());
  perform private.emit(p_cmd, 'pedido', v_id, o.revision, 'ticket_barra', null, 'Entregado',
    jsonb_build_object('cafe_g', v_need_g, 'leche_ml', v_milk, 'almendras_ml', v_almond_ml, 'total', v_total), null);
  perform private.sync_lot_status(t.lot_id, p_cmd);
  return jsonb_build_object('entity', 'pedido', 'entity_id', v_id, 'pedido_id', v_id, 'numero', o.number,
    'total', v_total, 'cafe_g', v_need_g);
end $$;

create or replace function private.shift_expected_cash(p_shift uuid) returns bigint
language sql stable set search_path = '' as $$
  select t.opening_cash + coalesce((select sum(pay.amount) from public.order_payments pay
    join public.orders o on o.id = pay.order_id where o.shift_id = t.id and pay.method = 'efectivo'), 0)
  from public.bar_shifts t where t.id = p_shift
$$;

create or replace function private.h_cerrar_caja(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare t public.bar_shifts; v_exp bigint; v_counted bigint := (p ->> 'contado')::bigint; v_diff bigint;
        v_reason text := nullif(btrim(coalesce(p ->> 'motivo', '')), ''); v_id uuid; v_thr bigint := (private.cfg()).cash_diff_threshold;
begin
  select * into t from public.bar_shifts where id = (p ->> 'turno_id')::uuid for update;
  if not found then perform private.biz('turno_inexistente', 'No encontramos ese turno.', '{}'); end if;
  if t.status <> 'abierto' then perform private.biz('turno_cerrado', 'Esa caja ya está cerrada.', '{}'); end if;
  perform private.check_rev(t.revision, p_rev, 'el turno');
  if v_counted is null or v_counted < 0 then perform private.biz('falta_contado', 'Contá el efectivo y cargalo.', '{}'); end if;
  v_exp := private.shift_expected_cash(t.id);
  v_diff := v_counted - v_exp;
  if abs(v_diff) > v_thr and v_reason is null then
    perform private.biz('motivo_requerido',
      format('La diferencia es de %s (esperado %s, contado %s). Supera %s: contá de nuevo o cargá el motivo.',
        private.fmt_ars(v_diff), private.fmt_ars(v_exp), private.fmt_ars(v_counted), private.fmt_ars(v_thr)),
      jsonb_build_object('esperado', v_exp, 'contado', v_counted, 'diferencia', v_diff));
  end if;
  insert into public.cash_closures (shift_id, closed_at, closed_by, expected_cash, counted_cash, reason, command_id)
  values (t.id, private.now(), p_actor, v_exp, v_counted, v_reason, p_cmd) returning id into v_id;
  update public.bar_shifts set status = 'cerrado', revision = revision + 1 where id = t.id returning * into t;
  perform private.emit(p_cmd, 'turno', t.id, t.revision, 'caja_cerrada', 'abierto', 'cerrado',
    jsonb_build_object('esperado', v_exp, 'contado', v_counted, 'diferencia', v_diff), v_reason);
  return jsonb_build_object('entity', 'cierre', 'entity_id', v_id, 'cierre_id', v_id, 'esperado', v_exp,
    'contado', v_counted, 'diferencia', v_diff);
end $$;

-- Retiro en el local de un pedido web listo (barra o admin entregan y cobran).
create or replace function private.h_entregar_retiro(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders; v_from public.order_status; v_method text := p ->> 'metodo';
begin
  select * into o from public.orders where id = (p ->> 'pedido_id')::uuid for update;
  if not found or o.channel <> 'web' or o.fulfillment <> 'retiro' then
    perform private.biz('pedido_inexistente', 'No encontramos ese pedido para retirar.', '{}');
  end if;
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  v_from := o.status;
  perform private.assert_transition(o.status, 'Entregado');
  if v_method is not null and v_method not in ('efectivo','tarjeta','transferencia','qr') then
    perform private.biz('metodo_invalido', 'Método de pago inválido.', '{}');
  end if;
  perform private.consume_order_allocations(o.id, p_cmd);
  if v_method is not null and o.total > 0 then
    insert into public.order_payments (order_id, amount, method, command_id, created_by, created_at)
    values (o.id, o.total, v_method, p_cmd, p_actor, private.now());
  end if;
  update public.orders set status = 'Entregado', delivered_at = private.now(), payment_method = v_method,
         revision = revision + 1 where id = o.id returning * into o;
  perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'pedido_retirado', v_from::text, 'Entregado', '{}', null);
  return jsonb_build_object('entity', 'pedido', 'entity_id', o.id, 'estado', o.status, 'revision', o.revision);
end $$;

-- ========================= REPARTO =========================

create or replace function private.route_load_g(p_route uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(l.grams), 0)::int from public.route_stops s
    join public.order_lines l on l.order_id = s.order_id and l.kind = 'cafe'
   where s.route_id = p_route and s.result <> 'quitado'
$$;

create or replace function private.order_failed_attempts(p_order uuid) returns int
language sql stable set search_path = '' as $$
  select count(*)::int from public.route_stops where order_id = p_order and result = 'no_entregado'
$$;

create or replace function private.h_crear_recorrido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_id uuid; v_driver uuid := nullif(p ->> 'repartidor_id', '')::uuid;
begin
  if v_driver is not null and not exists (select 1 from public.profiles where id = v_driver and role = 'reparto') then
    perform private.biz('repartidor_invalido', 'Elegí un repartidor del equipo.', '{}');
  end if;
  if coalesce(p ->> 'franja', '') not in ('10-13','15-18') then
    perform private.biz('franja_invalida', 'Las franjas son 10 a 13 y 15 a 18.', '{}');
  end if;
  if exists (select 1 from public.routes where route_date = (p ->> 'fecha')::date and zone_id = (p ->> 'zona_id')::uuid and slot = p ->> 'franja') then
    perform private.biz('recorrido_existente', 'Ya hay un recorrido para esa zona, fecha y franja.', '{}');
  end if;
  insert into public.routes (route_date, zone_id, slot, capacity_g, driver_id, created_at)
  values ((p ->> 'fecha')::date, (p ->> 'zona_id')::uuid, p ->> 'franja',
    coalesce((p ->> 'capacidad_g')::int, (private.cfg()).route_capacity_g), v_driver, private.now())
  returning id into v_id;
  perform private.emit(p_cmd, 'recorrido', v_id, 1, 'recorrido_creado', null, 'Planificado', p, null);
  return jsonb_build_object('entity', 'recorrido', 'entity_id', v_id, 'recorrido_id', v_id);
end $$;

create or replace function private.h_asignar_a_recorrido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare r public.routes; o public.orders; v_load int; v_g int; v_from public.order_status; v_seq int; v_fail int;
begin
  select * into r from public.routes where id = (p ->> 'recorrido_id')::uuid for update;
  if not found then perform private.biz('recorrido_inexistente', 'No encontramos ese recorrido.', '{}'); end if;
  perform private.check_rev(r.revision, p_rev, 'el recorrido');
  if r.status <> 'Planificado' then perform private.biz('recorrido_en_curso', 'El recorrido ya salió. Armá otro.', '{}'); end if;
  select * into o from public.orders where id = (p ->> 'pedido_id')::uuid for update;
  if not found or o.fulfillment <> 'envio' then perform private.biz('pedido_inexistente', 'Ese pedido no es para envío.', '{}'); end if;
  if o.status not in ('Listo','Para reprogramar') then
    perform private.biz('pedido_no_listo', format('El pedido #%s está «%s». Solo se cargan pedidos listos o para reprogramar.', o.number, o.status), '{}');
  end if;
  if exists (select 1 from public.route_stops where order_id = o.id and result = 'pendiente') then
    perform private.biz('ya_asignado', 'Ese pedido ya está en un recorrido.', '{}');
  end if;
  v_fail := private.order_failed_attempts(o.id);
  if v_fail >= 2 and not coalesce((p ->> 'confirmo_reintento')::boolean, false) then
    perform private.biz('decision_admin', format('El pedido #%s ya falló %s veces. Decidí: cancelarlo y liberar la reserva, o confirmar otro intento.', o.number, v_fail),
      jsonb_build_object('intentos', v_fail));
  end if;
  v_load := private.route_load_g(r.id);
  select coalesce(sum(grams), 0) into v_g from public.order_lines where order_id = o.id and kind = 'cafe';
  if v_load + v_g > r.capacity_g then
    perform private.biz('capacidad_superada',
      format('El recorrido lleva %s de %s y este pedido suma %s. Armá otro recorrido o elegí otro pedido.',
        private.fmt_g(v_load), private.fmt_g(r.capacity_g), private.fmt_g(v_g)),
      jsonb_build_object('carga_g', v_load, 'capacidad_g', r.capacity_g, 'pedido_g', v_g));
  end if;
  select coalesce(max(seq), 0) + 1 into v_seq from public.route_stops where route_id = r.id;
  insert into public.route_stops (route_id, order_id, seq, command_id) values (r.id, o.id, v_seq, p_cmd);
  update public.routes set revision = revision + 1 where id = r.id returning * into r;
  v_from := o.status;
  if o.status = 'Para reprogramar' then
    update public.orders set status = 'Listo', revision = revision + 1 where id = o.id returning * into o;
    perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'reprogramado', v_from::text, 'Listo', '{}', null);
  end if;
  perform private.emit(p_cmd, 'recorrido', r.id, r.revision, 'pedido_asignado', null, null,
    jsonb_build_object('pedido', o.number, 'gramos', v_g, 'carga_g', v_load + v_g), null);
  return jsonb_build_object('entity', 'recorrido', 'entity_id', r.id, 'revision', r.revision, 'carga_g', v_load + v_g);
end $$;

create or replace function private.h_quitar_de_recorrido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare r public.routes; st public.route_stops;
begin
  select * into st from public.route_stops where id = (p ->> 'parada_id')::uuid for update;
  if not found or st.result <> 'pendiente' then perform private.biz('parada_inexistente', 'Esa parada ya no está pendiente.', '{}'); end if;
  select * into r from public.routes where id = st.route_id for update;
  perform private.check_rev(r.revision, p_rev, 'el recorrido');
  if r.status <> 'Planificado' then perform private.biz('recorrido_en_curso', 'El recorrido ya salió.', '{}'); end if;
  update public.route_stops set result = 'quitado' where id = st.id;
  update public.routes set revision = revision + 1 where id = r.id returning * into r;
  perform private.emit(p_cmd, 'recorrido', r.id, r.revision, 'pedido_quitado', null, null, jsonb_build_object('parada', st.id), null);
  return jsonb_build_object('entity', 'recorrido', 'entity_id', r.id, 'revision', r.revision);
end $$;

create or replace function private.h_iniciar_recorrido(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare r public.routes; o record; v_rev int;
begin
  select * into r from public.routes where id = (p ->> 'recorrido_id')::uuid for update;
  if not found or (private.my_role() = 'reparto' and r.driver_id is distinct from auth.uid()) then
    perform private.biz('recorrido_inexistente', 'No encontramos ese recorrido.', '{}');
  end if;
  perform private.check_rev(r.revision, p_rev, 'el recorrido');
  if r.status <> 'Planificado' then perform private.biz('recorrido_en_curso', 'El recorrido ya salió.', '{}'); end if;
  if not exists (select 1 from public.route_stops where route_id = r.id and result = 'pendiente') then
    perform private.biz('recorrido_vacio', 'El recorrido no tiene pedidos.', '{}');
  end if;
  for o in select ord.* from public.route_stops s join public.orders ord on ord.id = s.order_id
            where s.route_id = r.id and s.result = 'pendiente' order by ord.id for update of ord loop
    perform private.assert_transition(o.status, 'En reparto');
    update public.orders set status = 'En reparto', revision = revision + 1 where id = o.id returning revision into v_rev;
    perform private.emit(p_cmd, 'pedido', o.id, v_rev, 'en_reparto', o.status::text, 'En reparto', '{}', null);
  end loop;
  update public.routes set status = 'En curso', revision = revision + 1 where id = r.id returning * into r;
  perform private.emit(p_cmd, 'recorrido', r.id, r.revision, 'recorrido_iniciado', 'Planificado', 'En curso', '{}', null);
  return jsonb_build_object('entity', 'recorrido', 'entity_id', r.id, 'revision', r.revision);
end $$;

-- Resultado de una parada. No entregado → «Para reprogramar» con la reserva intacta.
create or replace function private.h_registrar_entrega(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare st public.route_stops; r public.routes; o public.orders; v_res text := p ->> 'resultado';
        v_from public.order_status; v_to public.order_status; rj jsonb; v_cfg public.settings := private.cfg();
        v_ret jsonb := '[]'; v_rid uuid; v_fail int; v_cobro jsonb := p -> 'cobro'; v_rev int;
begin
  select * into st from public.route_stops where id = (p ->> 'parada_id')::uuid for update;
  if not found then perform private.biz('parada_inexistente', 'No encontramos esa parada.', '{}'); end if;
  select * into r from public.routes where id = st.route_id for update;
  if private.my_role() = 'reparto' and r.driver_id is distinct from auth.uid() then
    perform private.biz('parada_inexistente', 'No encontramos esa parada.', '{}');
  end if;
  if st.result <> 'pendiente' then perform private.biz('parada_cerrada', 'Esa parada ya tiene resultado cargado.', '{}'); end if;
  if r.status <> 'En curso' then perform private.biz('recorrido_no_iniciado', 'Iniciá el recorrido antes de cargar entregas.', '{}'); end if;
  select * into o from public.orders where id = st.order_id for update;
  perform private.check_rev(o.revision, p_rev, 'el pedido');
  v_from := o.status;

  if v_res = 'no_entregado' then
    if length(btrim(coalesce(p ->> 'nota', ''))) < 3 then
      perform private.biz('falta_motivo', 'Contá qué pasó (no había nadie, dirección mal, etc.).', '{}');
    end if;
    perform private.assert_transition(o.status, 'Para reprogramar');
    update public.route_stops set result = 'no_entregado', attempted_at = private.now(), note = p ->> 'nota', command_id = p_cmd where id = st.id;
    update public.orders set status = 'Para reprogramar', revision = revision + 1 where id = o.id returning * into o;
    v_fail := private.order_failed_attempts(o.id);
    perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'no_entregado', v_from::text, 'Para reprogramar',
      jsonb_build_object('intento', v_fail, 'reserva', 'intacta'), p ->> 'nota');
  elsif v_res = 'entregado' then
    v_to := case when jsonb_array_length(coalesce(p -> 'rechazos', '[]')) > 0 then 'Entregado parcial' else 'Entregado' end;
    perform private.assert_transition(o.status, v_to);
    perform private.consume_order_allocations(o.id, p_cmd);
    update public.route_stops set result = case when v_to = 'Entregado' then 'entregado' else 'entregado_parcial' end,
           attempted_at = private.now(), note = p ->> 'nota', command_id = p_cmd where id = st.id;
    update public.orders set status = v_to, delivered_at = private.now(), revision = revision + 1 where id = o.id returning * into o;
    perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'entregado', v_from::text, v_to::text, '{}', p ->> 'nota');
    if o.channel = 'mayorista' and o.total > 0 then
      insert into public.account_movements (customer_id, kind, amount, order_id, due_date, command_id, created_by, created_at)
      values (o.customer_id, 'cargo', o.total, o.id, private.today() + v_cfg.payment_terms_days, p_cmd, p_actor, private.now());
      perform private.emit(p_cmd, 'cuenta', o.customer_id, null, 'cargo_pedido', null, null,
        jsonb_build_object('pedido', o.number, 'monto', o.total), null);
    elsif o.channel = 'web' and v_cobro is not null and o.total > 0 then
      insert into public.order_payments (order_id, amount, method, command_id, created_by, created_at)
      values (o.id, o.total, coalesce(v_cobro ->> 'metodo', 'efectivo'), p_cmd, p_actor, private.now());
    end if;
    -- Reposición entregada → la devolución queda resuelta.
    if o.replacement_for_return_id is not null then
      update public.returns set status = 'Resuelta', resolved_at = private.now(), revision = revision + 1
       where id = o.replacement_for_return_id and status = 'Aceptada' returning revision into v_rev;
      if found then
        perform private.emit(p_cmd, 'devolucion', o.replacement_for_return_id, v_rev, 'reposicion_entregada', 'Aceptada', 'Resuelta', '{}', null);
      end if;
    end if;
    -- Rechazos en la puerta: quedan como devolución pedida para que administración decida.
    for rj in select * from jsonb_array_elements(coalesce(p -> 'rechazos', '[]')) loop
      v_rid := private.create_return(o.id, (rj ->> 'linea_id')::uuid, (rj ->> 'bolsas')::int, rj ->> 'condicion',
        coalesce(rj ->> 'motivo', 'Rechazado en la entrega'), p_actor, p_cmd);
      v_ret := v_ret || to_jsonb(v_rid);
    end loop;
  else
    perform private.biz('resultado_invalido', 'Marcá entregado o no entregado.', '{}');
  end if;

  if not exists (select 1 from public.route_stops where route_id = r.id and result = 'pendiente') then
    update public.routes set status = 'Cerrado', revision = revision + 1 where id = r.id returning * into r;
    perform private.emit(p_cmd, 'recorrido', r.id, r.revision, 'recorrido_cerrado', 'En curso', 'Cerrado', '{}', null);
  end if;
  return jsonb_build_object('entity', 'pedido', 'entity_id', o.id, 'estado', o.status, 'revision', o.revision,
    'devoluciones', v_ret, 'intentos_fallidos', private.order_failed_attempts(o.id));
end $$;

-- ========================= DEVOLUCIONES =========================

create or replace function private.create_return(p_order uuid, p_line uuid, p_bags int, p_condition text,
  p_reason text, p_actor uuid, p_cmd uuid)
returns uuid language plpgsql set search_path = '' as $$
declare o public.orders; l public.order_lines; v_unit int; v_returned int; v_splits jsonb := '[]';
        v_need int; a record; v_take int; v_id uuid; v_days int := (private.cfg()).return_days;
begin
  select * into o from public.orders where id = p_order;
  select * into l from public.order_lines where id = p_line and order_id = p_order and kind = 'cafe' for update;
  if not found then perform private.biz('linea_inexistente', 'Elegí qué producto devolvés.', '{}'); end if;
  if o.status not in ('Entregado','Entregado parcial') or o.delivered_at is null then
    perform private.biz('no_entregado', 'Solo se devuelve café ya entregado.', '{}');
  end if;
  if private.now() > o.delivered_at + make_interval(days => v_days) then
    perform private.biz('fuera_de_plazo', format('Las devoluciones se aceptan hasta %s días después de la entrega.', v_days), '{}');
  end if;
  if p_condition not in ('cerrada','abierta','defectuosa','mal_sellada') then
    perform private.biz('condicion_invalida', 'Indicá cómo está la bolsa: cerrada, abierta, defectuosa o mal sellada.', '{}');
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then perform private.biz('falta_motivo', 'Contanos el motivo.', '{}'); end if;
  v_unit := private.unit_grams(l.presentation);
  select coalesce(sum(bags), 0) into v_returned from public.returns where order_line_id = l.id and status <> 'Rechazada';
  if p_bags is null or p_bags < 1 or v_returned + p_bags > l.qty then
    perform private.biz('bolsas_invalidas', format('Esa línea tiene %s bolsas y ya hay %s en devolución.', l.qty, v_returned), '{}');
  end if;
  -- De qué lote salió cada bolsa: se recorre la reserva consumida desde la última.
  v_need := (v_returned + p_bags) * v_unit;
  for a in select lot_id, grams from public.order_allocations where order_line_id = l.id and state = 'consumida' order by id desc loop
    exit when v_need <= 0;
    v_take := least(a.grams, v_need);
    v_need := v_need - v_take;
    v_splits := v_splits || jsonb_build_object('lot_id', a.lot_id, 'grams', v_take);
  end loop;
  -- quitar lo ya devuelto antes (primeros v_returned*v_unit gramos del recorrido)
  select jsonb_agg(x) into v_splits from (
    select jsonb_build_object('lot_id', e ->> 'lot_id', 'grams', g) as x from (
      select e, greatest(0, least((e ->> 'grams')::int, (sum((e ->> 'grams')::int) over (order by ord)) - v_returned * v_unit)) as g, ord
        from jsonb_array_elements(v_splits) with ordinality as t(e, ord)
    ) s where g > 0
  ) z;
  insert into public.returns (order_id, order_line_id, customer_id, bags, grams, lot_splits, condition, reason,
    amount, requested_by, requested_at)
  values (o.id, l.id, o.customer_id, p_bags, p_bags * v_unit, coalesce(v_splits, '[]'), p_condition, p_reason,
    coalesce(l.unit_price, 0) * p_bags, p_actor, private.now())
  returning id into v_id;
  perform private.emit(p_cmd, 'devolucion', v_id, 1, 'devolucion_pedida', null, 'Pedida',
    jsonb_build_object('pedido', o.number, 'bolsas', p_bags, 'condicion', p_condition), p_reason);
  return v_id;
end $$;

create or replace function private.h_pedir_devolucion(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders; v_id uuid;
begin
  o := private.lock_order_for_actor((p ->> 'pedido_id')::uuid);
  v_id := private.create_return(o.id, (p ->> 'linea_id')::uuid, (p ->> 'bolsas')::int, p ->> 'condicion', p ->> 'motivo', p_actor, p_cmd);
  return jsonb_build_object('entity', 'devolucion', 'entity_id', v_id, 'devolucion_id', v_id,
    'numero', (select number from public.returns where id = v_id));
end $$;

create or replace function private.h_revisar_devolucion(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare rt public.returns;
begin
  select * into rt from public.returns where id = (p ->> 'devolucion_id')::uuid for update;
  if not found then perform private.biz('devolucion_inexistente', 'No encontramos esa devolución.', '{}'); end if;
  perform private.check_rev(rt.revision, p_rev, 'la devolución');
  if rt.status <> 'Pedida' then perform private.biz('transicion_invalida', format('La devolución está «%s».', rt.status), '{}'); end if;
  update public.returns set status = 'En revisión', revision = revision + 1 where id = rt.id returning * into rt;
  perform private.emit(p_cmd, 'devolucion', rt.id, rt.revision, 'en_revision', 'Pedida', 'En revisión', '{}', null);
  return jsonb_build_object('entity', 'devolucion', 'entity_id', rt.id, 'revision', rt.revision);
end $$;

-- Aceptar: bolsa cerrada vuelve al mismo lote; abierta/defectuosa/mal sellada → merma.
-- Salida: reposición (próximo recorrido), nota de crédito (mayorista) o reintegro manual (minorista).
create or replace function private.h_decidir_devolucion(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare rt public.returns; o public.orders; l public.order_lines; v_dec text := p ->> 'decision';
        v_resol text := p ->> 'resolucion'; sp jsonb; s record; v_from public.return_status; v_repl uuid;
        v_amount bigint; v_effect jsonb := '[]'; v_res jsonb; v_rev int;
begin
  select * into rt from public.returns where id = (p ->> 'devolucion_id')::uuid for update;
  if not found then perform private.biz('devolucion_inexistente', 'No encontramos esa devolución.', '{}'); end if;
  perform private.check_rev(rt.revision, p_rev, 'la devolución');
  if rt.status not in ('Pedida','En revisión') then
    perform private.biz('ya_decidida', format('La devolución ya está «%s».', rt.status), '{}');
  end if;
  v_from := rt.status;
  select * into o from public.orders where id = rt.order_id;
  select * into l from public.order_lines where id = rt.order_line_id;

  if v_dec = 'rechazar' then
    update public.returns set status = 'Rechazada', decided_by = p_actor, decided_at = private.now(),
           decision_note = p ->> 'nota', revision = revision + 1 where id = rt.id returning * into rt;
    perform private.emit(p_cmd, 'devolucion', rt.id, rt.revision, 'devolucion_rechazada', v_from::text, 'Rechazada', '{}', p ->> 'nota');
    return jsonb_build_object('entity', 'devolucion', 'entity_id', rt.id, 'estado', rt.status, 'revision', rt.revision);
  elsif v_dec <> 'aceptar' then
    perform private.biz('decision_invalida', 'Elegí aceptar o rechazar.', '{}');
  end if;

  if v_resol is null or v_resol not in ('reposicion','nota_credito','reintegro') then
    perform private.biz('falta_resolucion', 'Elegí la salida: reposición, nota de crédito o reintegro.', '{}');
  end if;
  if v_resol = 'nota_credito' and o.channel <> 'mayorista' then
    perform private.biz('resolucion_invalida', 'La nota de crédito es solo para mayoristas.', '{}');
  end if;
  if v_resol = 'reintegro' and o.channel = 'mayorista' then
    perform private.biz('resolucion_invalida', 'A un mayorista se le hace nota de crédito o reposición.', '{}');
  end if;

  -- Movimiento físico
  for sp in select * from jsonb_array_elements(rt.lot_splits) loop
    perform 1 from public.roast_batches where id = (sp ->> 'lot_id')::uuid for update;
    select * into s from private.lot_stock_rows(null, (sp ->> 'lot_id')::uuid);
    if rt.condition = 'cerrada' then
      insert into public.lot_movements (lot_id, kind, grams, order_line_id, return_id, command_id, note, created_by, created_at)
      values (s.lot_id, 'devolucion', (sp ->> 'grams')::int, l.id, rt.id, p_cmd,
        case when s.status = 'Solo barra' then 'Vuelve como café de barra' else 'Bolsa cerrada vuelve al lote' end,
        p_actor, private.now());
      v_effect := v_effect || jsonb_build_object('lote', s.code, 'gramos', (sp ->> 'grams')::int, 'destino',
        case when s.status = 'Solo barra' then 'barra' else 'stock' end);
      perform private.sync_lot_status(s.lot_id, p_cmd, 'devolución');
    else
      insert into public.waste_records (lot_id, grams, source, return_id, reason, command_id, created_at)
      values (s.lot_id, (sp ->> 'grams')::int, 'devolucion', rt.id, 'Bolsa ' || replace(rt.condition, '_', ' '), p_cmd, private.now());
      v_effect := v_effect || jsonb_build_object('lote', s.code, 'gramos', (sp ->> 'grams')::int, 'destino', 'merma');
    end if;
  end loop;

  update public.returns set status = 'Aceptada', resolution = v_resol, decided_by = p_actor, decided_at = private.now(),
         decision_note = p ->> 'nota', revision = revision + 1 where id = rt.id returning * into rt;
  perform private.emit(p_cmd, 'devolucion', rt.id, rt.revision, 'devolucion_aceptada', v_from::text, 'Aceptada',
    jsonb_build_object('movimientos', v_effect, 'resolucion', v_resol), p ->> 'nota');

  if v_resol = 'nota_credito' then
    insert into public.account_movements (customer_id, kind, amount, order_id, return_id, command_id, created_by, created_at, reference)
    values (o.customer_id, 'nota_credito', -rt.amount, o.id, rt.id, p_cmd, p_actor, private.now(), 'NC devolución #' || rt.number);
    perform private.emit(p_cmd, 'cuenta', o.customer_id, null, 'nota_credito', null, null,
      jsonb_build_object('monto', rt.amount, 'devolucion', rt.number), null);
  elsif v_resol = 'reintegro' then
    v_amount := coalesce(nullif(p ->> 'monto_reintegro', '')::bigint, rt.amount);
    if v_amount <= 0 or v_amount > rt.amount then
      perform private.biz('monto_invalido', format('El reintegro va de $1 a %s.', private.fmt_ars(rt.amount)), '{}');
    end if;
    insert into public.refunds (return_id, order_id, amount, method, command_id, created_by, created_at)
    values (rt.id, o.id, v_amount, coalesce(p ->> 'metodo', 'efectivo'), p_cmd, p_actor, private.now());
  else
    -- Reposición: pedido nuevo a $0 que reserva del lote elegible y espera el próximo recorrido.
    insert into public.orders (channel, status, customer_id, retail_name, retail_phone, fulfillment, zone_id, address,
      scheduled_date, price_list_id, replacement_for_return_id, notes, created_by, created_at)
    values (o.channel, 'Borrador', o.customer_id, o.retail_name, o.retail_phone,
      case when o.fulfillment = 'barra' then 'retiro' else o.fulfillment end, o.zone_id, o.address,
      private.today() + 1, o.price_list_id, rt.id, 'Reposición de devolución #' || rt.number, p_actor, private.now())
    returning id into v_repl;
    insert into public.order_lines (order_id, line_no, kind, coffee_id, presentation, grind, qty, grams)
    values (v_repl, 1, 'cafe', l.coffee_id, l.presentation, l.grind, rt.bags, rt.grams);
    perform private.emit(p_cmd, 'pedido', v_repl, 1, 'pedido_creado', null, 'Borrador', jsonb_build_object('reposicion_de', rt.number), null);
    perform private.confirm_order(v_repl, p_cmd);
    update public.returns set replacement_order_id = v_repl where id = rt.id;
  end if;

  if v_resol in ('nota_credito','reintegro') then
    update public.returns set status = 'Resuelta', resolved_at = private.now(), revision = revision + 1
     where id = rt.id returning * into rt;
    perform private.emit(p_cmd, 'devolucion', rt.id, rt.revision, 'devolucion_resuelta', 'Aceptada', 'Resuelta',
      jsonb_build_object('resolucion', v_resol), null);
  end if;
  select * into rt from public.returns where id = rt.id;
  return jsonb_build_object('entity', 'devolucion', 'entity_id', rt.id, 'estado', rt.status, 'revision', rt.revision,
    'resolucion', v_resol, 'pedido_reposicion', v_repl, 'monto', rt.amount);
end $$;

-- ========================= CUENTA CORRIENTE =========================

create or replace function private.h_registrar_pago(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare c public.wholesale_customers; v_amount bigint := (p ->> 'monto')::bigint; v_cs jsonb;
begin
  select * into c from public.wholesale_customers where id = (p ->> 'cliente_id')::uuid for update;
  if not found then perform private.biz('cliente_invalido', 'No encontramos ese cliente.', '{}'); end if;
  if v_amount is null or v_amount <= 0 then perform private.biz('monto_invalido', 'Cargá el monto cobrado.', '{}'); end if;
  if coalesce(p ->> 'metodo', '') not in ('efectivo','transferencia','cheque','qr') then
    perform private.biz('metodo_invalido', 'Elegí cómo pagó: efectivo, transferencia, cheque o QR.', '{}');
  end if;
  insert into public.account_movements (customer_id, kind, amount, method, reference, command_id, created_by, created_at)
  values (c.id, 'pago', -v_amount, p ->> 'metodo', left(p ->> 'referencia', 120), p_cmd, p_actor, private.now());
  update public.wholesale_customers set revision = revision + 1 where id = c.id returning * into c;
  v_cs := private.credit_status(c.id);
  perform private.emit(p_cmd, 'cuenta', c.id, c.revision, 'pago_registrado', null, null,
    jsonb_build_object('monto', v_amount, 'saldo', v_cs -> 'saldo'), null);
  return jsonb_build_object('entity', 'cuenta', 'entity_id', c.id, 'saldo', v_cs -> 'saldo', 'credito', v_cs,
    'revision', c.revision);
end $$;

-- ========================= PROPUESTAS DE CORRECCIÓN =========================

create or replace function private.h_proponer_cambio(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_entity text := p ->> 'entidad'; v_eid uuid := (p ->> 'entidad_id')::uuid; v_rev int; v_id uuid;
begin
  if length(btrim(coalesce(p ->> 'motivo', ''))) < 5 then perform private.biz('falta_motivo', 'Explicá el motivo del ajuste.', '{}'); end if;
  if coalesce((p -> 'cambios' ->> 'monto')::bigint, 0) = 0 and coalesce((p -> 'cambios' ->> 'gramos')::int, 0) = 0 then
    perform private.biz('ajuste_vacio', 'El ajuste tiene que mover algún monto o gramos.', '{}');
  end if;
  v_rev := case v_entity
    when 'cierre_caja' then (select revision from public.cash_closures where id = v_eid)
    when 'lote' then (select revision from public.roast_batches where id = v_eid)
    when 'cuenta' then (select revision from public.wholesale_customers where id = v_eid) end;
  if v_rev is null then perform private.biz('registro_inexistente', 'No encontramos el registro a corregir.', '{}'); end if;
  perform private.check_rev(v_rev, p_rev, 'el registro');
  insert into public.change_proposals (entity, entity_id, base_revision, changes, reason, created_by, created_at)
  values (v_entity, v_eid, v_rev, p -> 'cambios', p ->> 'motivo', p_actor, private.now()) returning id into v_id;
  perform private.emit(p_cmd, 'propuesta', v_id, 1, 'propuesta_creada', null, 'pendiente', p -> 'cambios', p ->> 'motivo');
  return jsonb_build_object('entity', 'propuesta', 'entity_id', v_id, 'propuesta_id', v_id);
end $$;

create or replace function private.h_decidir_propuesta(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare pr public.change_proposals; v_dec text := p ->> 'decision'; v_cur int; v_g int; v_m bigint; s record;
begin
  select * into pr from public.change_proposals where id = (p ->> 'propuesta_id')::uuid for update;
  if not found then perform private.biz('propuesta_inexistente', 'No encontramos esa propuesta.', '{}'); end if;
  perform private.check_rev(pr.revision, p_rev, 'la propuesta');
  if pr.status <> 'pendiente' then perform private.biz('ya_decidida', 'Esa propuesta ya fue decidida.', '{}'); end if;
  if pr.created_by = p_actor then
    perform private.biz('misma_persona', 'La propuesta la tiene que revisar otra persona.', '{}');
  end if;
  if v_dec = 'rechazar' then
    update public.change_proposals set status = 'rechazada', decided_by = p_actor, decided_at = private.now(),
           decision_note = p ->> 'nota', revision = revision + 1 where id = pr.id returning * into pr;
    perform private.emit(p_cmd, 'propuesta', pr.id, pr.revision, 'propuesta_rechazada', 'pendiente', 'rechazada', '{}', p ->> 'nota');
    return jsonb_build_object('entity', 'propuesta', 'entity_id', pr.id, 'estado', pr.status);
  elsif v_dec <> 'aprobar' then
    perform private.biz('decision_invalida', 'Elegí aprobar o rechazar.', '{}');
  end if;

  v_m := (pr.changes ->> 'monto')::bigint;
  v_g := (pr.changes ->> 'gramos')::int;
  if pr.entity = 'cierre_caja' then
    select revision into v_cur from public.cash_closures where id = pr.entity_id for update;
    perform private.check_rev(v_cur, pr.base_revision, 'el cierre');
    insert into public.cash_adjustments (closure_id, amount, reason, proposal_id, command_id, created_by, created_at)
    values (pr.entity_id, v_m, pr.reason, pr.id, p_cmd, p_actor, private.now());
    update public.cash_closures set revision = revision + 1 where id = pr.entity_id returning revision into v_cur;
    perform private.emit(p_cmd, 'cierre', pr.entity_id, v_cur, 'ajuste_cierre', null, null, jsonb_build_object('monto', v_m), pr.reason);
  elsif pr.entity = 'lote' then
    select revision into v_cur from public.roast_batches where id = pr.entity_id for update;
    perform private.check_rev(v_cur, pr.base_revision, 'el lote');
    select * into s from private.lot_stock_rows(null, pr.entity_id);
    if v_g < 0 and s.available_g + v_g < 0 then
      perform private.biz('ajuste_excede', format('El lote tiene %s libres; el ajuste pide %s.', private.fmt_g(s.available_g), private.fmt_g(-v_g)), '{}');
    end if;
    insert into public.lot_movements (lot_id, kind, grams, proposal_id, command_id, note, created_by, created_at)
    values (pr.entity_id, 'ajuste', v_g, pr.id, p_cmd, pr.reason, p_actor, private.now());
    if v_g < 0 then
      insert into public.waste_records (lot_id, grams, source, proposal_id, reason, command_id, created_at)
      values (pr.entity_id, -v_g, 'ajuste', pr.id, pr.reason, p_cmd, private.now());
    end if;
    update public.roast_batches set revision = revision + 1 where id = pr.entity_id;
    perform private.sync_lot_status(pr.entity_id, p_cmd, 'ajuste');
  elsif pr.entity = 'cuenta' then
    select revision into v_cur from public.wholesale_customers where id = pr.entity_id for update;
    perform private.check_rev(v_cur, pr.base_revision, 'la cuenta');
    insert into public.account_movements (customer_id, kind, amount, proposal_id, reference, command_id, created_by, created_at)
    values (pr.entity_id, 'ajuste', v_m, pr.id, left(pr.reason, 120), p_cmd, p_actor, private.now());
    update public.wholesale_customers set revision = revision + 1 where id = pr.entity_id;
  end if;
  update public.change_proposals set status = 'aprobada', decided_by = p_actor, decided_at = private.now(),
         decision_note = p ->> 'nota', applied_command_id = p_cmd, revision = revision + 1 where id = pr.id returning * into pr;
  perform private.emit(p_cmd, 'propuesta', pr.id, pr.revision, 'propuesta_aprobada', 'pendiente', 'aprobada', pr.changes, p ->> 'nota');
  return jsonb_build_object('entity', 'propuesta', 'entity_id', pr.id, 'estado', pr.status);
end $$;

-- ========================= PRECIOS Y CONFIGURACIÓN =========================

create or replace function private.h_actualizar_precio(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v_id uuid; v_from date := (p ->> 'vigente_desde')::date; v_price bigint := (p ->> 'precio')::bigint;
begin
  if v_from is null or v_from < private.today() then
    perform private.biz('vigencia_invalida', 'La vigencia arranca hoy o en una fecha futura. Lo ya confirmado no cambia.', '{}');
  end if;
  if v_price is null or v_price <= 0 then perform private.biz('precio_invalido', 'Cargá un precio mayor a cero.', '{}'); end if;
  if exists (select 1 from public.price_items where list_id = (p ->> 'lista_id')::uuid and coffee_id = (p ->> 'cafe_id')::uuid
              and presentation = p ->> 'presentacion' and valid_from = v_from) then
    perform private.biz('precio_existente', 'Ya hay un precio con esa vigencia. Elegí otra fecha.', '{}');
  end if;
  insert into public.price_items (list_id, coffee_id, presentation, price, valid_from, created_by, created_at)
  values ((p ->> 'lista_id')::uuid, (p ->> 'cafe_id')::uuid, p ->> 'presentacion', v_price, v_from, p_actor, private.now())
  returning id into v_id;
  perform private.emit(p_cmd, 'precio', v_id, 1, 'precio_programado', null, null, p, null);
  return jsonb_build_object('entity', 'precio', 'entity_id', v_id);
end $$;

create or replace function private.h_actualizar_config(p jsonb, p_rev int, p_actor uuid, p_cmd uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare s public.settings; v_old jsonb;
begin
  select * into s from public.settings where id = 1 for update;
  perform private.check_rev(s.revision, p_rev, 'la configuración');
  v_old := to_jsonb(s);
  update public.settings set
    wholesale_block_pct = coalesce((p ->> 'wholesale_block_pct')::numeric, wholesale_block_pct),
    route_capacity_g = coalesce((p ->> 'route_capacity_g')::int, route_capacity_g),
    cash_diff_threshold = coalesce((p ->> 'cash_diff_threshold')::bigint, cash_diff_threshold),
    shipping_fee = coalesce((p ->> 'shipping_fee')::bigint, shipping_fee),
    free_shipping_from = coalesce((p ->> 'free_shipping_from')::bigint, free_shipping_from),
    shrink_min_pct = coalesce((p ->> 'shrink_min_pct')::numeric, shrink_min_pct),
    shrink_max_pct = coalesce((p ->> 'shrink_max_pct')::numeric, shrink_max_pct),
    revision = revision + 1
  where id = 1 returning * into s;
  perform private.emit(p_cmd, 'config', '00000000-0000-0000-0000-000000000001', s.revision, 'config_actualizada', null, null,
    jsonb_build_object('antes', v_old, 'despues', to_jsonb(s)), null);
  return jsonb_build_object('entity', 'config', 'revision', s.revision);
end $$;
