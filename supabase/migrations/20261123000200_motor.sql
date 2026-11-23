-- =====================================================================
-- Calafate Coffee Roasters · 02 · Motor de reglas (funciones internas)
-- Todo vive en el esquema private (no expuesto por la API).
-- =====================================================================

-- Error de negocio: SQLSTATE CF001. message = código, detail = texto para la persona,
-- hint = jsonb con datos. run_command lo atrapa, revierte el subbloque y lo registra.
create or replace function private.biz(p_code text, p_message text, p_detail jsonb default '{}')
returns void language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'CF001', message = p_code, detail = p_message,
    hint = coalesce(p_detail, '{}'::jsonb)::text;
end $$;

create or replace function private.fault_point(p_name text)
returns void language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from private.test_faults where name = p_name) then
    raise exception 'falla_simulada: %', p_name using errcode = 'XX000';
  end if;
end $$;

-- ---------- Identidad (siempre desde auth.uid(), nunca desde el navegador) ----------
create or replace function private.my_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where id = auth.uid()
$$;
create or replace function private.my_customer() returns uuid
language sql stable security definer set search_path = '' as $$
  select customer_id from public.profiles where id = auth.uid() and role = 'mayorista'
$$;
create or replace function private.has_role(variadic p_roles public.app_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = any(p_roles) from public.profiles where id = auth.uid()), false)
$$;
create or replace function private.require_role(variadic p_roles public.app_role[]) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.has_role(variadic p_roles) then
    raise exception 'No tenés permiso para esta acción.' using errcode = '42501';
  end if;
end $$;

-- ---------- Utilidades ----------
create or replace function private.fmt_g(p_g bigint) returns text
language sql immutable set search_path = '' as $$
  select case when abs(p_g) >= 1000
    then replace(trim(to_char(p_g / 1000.0, 'FM999G990D0')), '.', ',') || ' kg'
    else p_g::text || ' g' end
$$;
create or replace function private.fmt_ars(p bigint) returns text
language sql immutable set search_path = '' as $$
  select '$' || replace(to_char(p, 'FM999G999G999'), ',', '.')
$$;

-- "mañana a las 9", "hoy a las 15:30", "el 02/12 a las 9". Si cae antes de abrir, muestra la apertura.
create or replace function private.human_when(p_ts timestamptz) returns text
language plpgsql stable set search_path = '' as $$
declare
  v_tz text := (private.cfg()).timezone;
  v_open int := (private.cfg()).store_open_hour;
  v_local timestamp := p_ts at time zone v_tz;
  v_day date := v_local::date;
  v_today date := private.today();
  v_hour text;
begin
  if extract(hour from v_local) < v_open then
    v_hour := v_open::text;
  elsif extract(minute from v_local) = 0 then
    v_hour := to_char(v_local, 'FMHH24');
  else
    v_hour := to_char(v_local, 'HH24:MI');
  end if;
  return case
    when v_day = v_today then 'hoy a las ' || v_hour
    when v_day = v_today + 1 then 'mañana a las ' || v_hour
    else 'el ' || to_char(v_local, 'DD/MM') || ' a las ' || v_hour end;
end $$;

create or replace function private.unit_grams(p_presentation text) returns int
language sql immutable set search_path = '' as $$
  select case p_presentation when 'bolsa_250' then 250 else 1000 end
$$;

create or replace function private.emit(
  p_cmd uuid, p_entity text, p_entity_id uuid, p_rev int, p_type text,
  p_from text, p_to text, p_effect jsonb default '{}', p_reason text default null)
returns void language plpgsql set search_path = '' as $$
begin
  insert into public.domain_events (command_id, entity, entity_id, entity_revision, event_type,
    from_state, to_state, effect, reason, actor_id, created_at)
  values (p_cmd, p_entity, p_entity_id, p_rev, p_type, p_from, p_to, coalesce(p_effect, '{}'),
    p_reason, (select actor_id from public.commands where id = p_cmd), private.now());
end $$;

create or replace function private.check_rev(p_current int, p_expected int, p_what text)
returns void language plpgsql set search_path = '' as $$
begin
  if p_expected is null then
    perform private.biz('revision_requerida',
      format('Falta la versión de %s que estabas mirando. Actualizá y volvé a intentar.', p_what), '{}');
  end if;
  if p_current <> p_expected then
    perform private.biz('revision_desactualizada',
      format('Alguien modificó %s mientras lo mirabas (versión %s, ahora %s). Actualizá los datos: lo que escribiste se conserva.',
        p_what, p_expected, p_current),
      jsonb_build_object('esperada', p_expected, 'actual', p_current));
  end if;
end $$;

-- ---------- Estado efectivo de un lote (fuente única de la regla de tiempo) ----------
create or replace function private.lot_status_at(
  p_rest_until timestamptz, p_barra_only_from timestamptz, p_available int, p_now timestamptz)
returns public.lot_status language sql immutable set search_path = '' as $$
  select case
    when p_available <= 0 then 'Agotado'::public.lot_status
    when p_now < p_rest_until then 'En reposo'
    when p_now >= p_barra_only_from then 'Solo barra'
    else 'Disponible' end
$$;

-- Stock por lote calculado SOLO desde movimientos y reservas.
create or replace function private.lot_stock_rows(p_coffee uuid default null, p_lot uuid default null)
returns table (
  lot_id uuid, code text, coffee_id uuid, roasted_at timestamptz, roasted_g int,
  rest_until timestamptz, barra_only_from timestamptz, cost_per_kg bigint, block_pct numeric,
  on_hand_g int, reserved_g int, available_g int, wholesale_used_g int, protected_g int,
  status public.lot_status, retail_available_g int, wholesale_available_g int, barra_available_g int)
language sql stable set search_path = '' as $$
  with base as (
    select b.*,
      (select coalesce(sum(m.grams), 0)::int from public.lot_movements m where m.lot_id = b.id) as on_hand,
      (select coalesce(sum(a.grams), 0)::int from public.order_allocations a
        where a.lot_id = b.id and a.state = 'reservada') as reserved,
      (select coalesce(sum(a.grams), 0)::int from public.order_allocations a
         join public.order_lines l on l.id = a.order_line_id
         join public.orders o on o.id = l.order_id
        where a.lot_id = b.id and a.state in ('reservada','consumida') and o.channel = 'mayorista') as wh_used
    from public.roast_batches b
    where (p_coffee is null or b.coffee_id = p_coffee) and (p_lot is null or b.id = p_lot)
  ), calc as (
    select base.*, (on_hand - reserved) as avail,
      greatest(0, round(roasted_g * wholesale_block_pct / 100.0)::int - wh_used) as prot,
      private.lot_status_at(rest_until, barra_only_from, on_hand - reserved, private.now()) as st
    from base
  )
  select id, code, coffee_id, roasted_at, roasted_g, rest_until, barra_only_from, cost_per_kg,
    wholesale_block_pct, on_hand, reserved, avail, wh_used, prot, st,
    case when st = 'Disponible' then greatest(0, avail - prot) else 0 end,
    case when st = 'Disponible' then avail else 0 end,
    case when st = 'Disponible' then greatest(0, avail - prot) when st = 'Solo barra' then avail else 0 end
  from calc
$$;

-- Sincroniza el estado cacheado y deja evento si cambió (por tiempo o por quedar en cero).
create or replace function private.sync_lot_status(p_lot uuid, p_cmd uuid, p_reason text default null)
returns void language plpgsql set search_path = '' as $$
declare v_old public.lot_status; v_new public.lot_status; v_rev int;
begin
  select b.status into v_old from public.roast_batches b where b.id = p_lot;
  select s.status into v_new from private.lot_stock_rows(null, p_lot) s;
  if v_old is distinct from v_new then
    update public.roast_batches set status = v_new, revision = revision + 1
      where id = p_lot returning revision into v_rev;
    perform private.emit(p_cmd, 'lote', p_lot, v_rev, 'estado_lote', v_old::text, v_new::text,
      '{}', coalesce(p_reason, case when v_new = 'Agotado' then 'kilos en cero' else 'cambio por tiempo' end));
  end if;
end $$;

-- ---------- Precios ----------
create or replace function private.price_for(p_list uuid, p_coffee uuid, p_presentation text, p_date date)
returns bigint language plpgsql stable set search_path = '' as $$
declare v bigint;
begin
  select price into v from public.price_items
   where list_id = p_list and coffee_id = p_coffee and presentation = p_presentation and valid_from <= p_date
   order by valid_from desc limit 1;
  if v is null then
    perform private.biz('sin_precio', 'Ese café no tiene precio vigente en tu lista. Avisanos y lo cargamos.',
      jsonb_build_object('cafe', p_coffee, 'presentacion', p_presentation));
  end if;
  return v;
end $$;

-- ---------- Cuenta corriente: estado de crédito (FIFO de pagos sobre cargos) ----------
create or replace function private.credit_status(p_customer uuid, p_extra bigint default 0, p_exclude_order uuid default null)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  c public.wholesale_customers; v_limit bigint; v_balance bigint; v_credits bigint;
  v_today date := private.today(); v_tol int := (private.cfg()).overdue_tolerance_days;
  v_overdue_amount bigint; v_oldest_due date; v_open bigint; v_exposure bigint;
  v_blocked boolean := false; v_reason text; v_msg text; v_overdue_days int;
begin
  select * into c from public.wholesale_customers where id = p_customer;
  select coalesce(c.credit_limit, pl.credit_limit, 0) into v_limit from public.price_lists pl where pl.id = c.price_list_id;
  select coalesce(sum(amount), 0) into v_balance from public.account_movements where customer_id = p_customer;
  select coalesce(-sum(amount), 0) into v_credits from public.account_movements where customer_id = p_customer and amount < 0;

  with ch as (
    select due_date, amount, sum(amount) over (order by created_at, id) as cum
      from public.account_movements where customer_id = p_customer and amount > 0
  ), unpaid as (
    select due_date, greatest(0, least(amount, cum - v_credits)) as unpaid from ch
  )
  select coalesce(sum(unpaid) filter (where due_date < v_today), 0),
         min(due_date) filter (where unpaid > 0 and due_date < v_today)
    into v_overdue_amount, v_oldest_due from unpaid;
  v_overdue_days := case when v_oldest_due is null then 0 else v_today - v_oldest_due end;

  select coalesce(sum(total), 0) into v_open from public.orders
   where customer_id = p_customer and total is not null
     and status in ('Confirmado','En preparación','Listo','En reparto','Para reprogramar')
     and (p_exclude_order is null or id <> p_exclude_order);
  v_exposure := v_balance + v_open + coalesce(p_extra, 0);

  if v_overdue_days > v_tol then
    v_blocked := true; v_reason := 'deuda_vencida';
    v_msg := format('Tenés %s vencidos hace %s días. Cuando registremos el pago liberamos tus pedidos.',
      private.fmt_ars(v_overdue_amount), v_overdue_days);
  elsif v_exposure > v_limit then
    v_blocked := true; v_reason := 'limite_credito';
    v_msg := format('Con este pedido tu cuenta llegaría a %s y tu límite es %s. Registrá un pago o achicá el pedido.',
      private.fmt_ars(v_exposure), private.fmt_ars(v_limit));
  end if;

  return jsonb_build_object('saldo', v_balance, 'vencido', v_overdue_amount, 'dias_vencido', v_overdue_days,
    'limite', v_limit, 'comprometido', v_open, 'exposicion', v_exposure,
    'bloqueado', v_blocked, 'motivo', v_reason, 'mensaje', v_msg);
end $$;

-- ---------- Reserva FIFO por lote (bloqueo de filas: nadie toma dos veces el último kilo) ----------
create or replace function private.reserve(
  p_line uuid, p_coffee uuid, p_grams int, p_channel public.order_channel, p_unit int, p_cmd uuid)
returns void language plpgsql set search_path = '' as $$
declare r record; v_need int := p_grams; v_avail int; v_take int; v_total int := 0;
        v_rest timestamptz; v_name text;
begin
  -- Bloquea TODOS los lotes de ese café en orden fijo: serializa reservas concurrentes.
  perform 1 from public.roast_batches where coffee_id = p_coffee order by roasted_at, id for update;

  for r in select * from private.lot_stock_rows(p_coffee, null) s order by s.roasted_at, s.lot_id loop
    v_avail := case when p_channel = 'mayorista' then r.wholesale_available_g else r.retail_available_g end;
    v_total := v_total + v_avail;
    v_take := least(v_need, (v_avail / p_unit) * p_unit);   -- cada bolsa sale de un solo lote
    continue when v_take <= 0;
    insert into public.order_allocations (order_line_id, lot_id, grams, cost_per_kg, command_id, created_at)
    values (p_line, r.lot_id, v_take, r.cost_per_kg, p_cmd, private.now());
    perform private.fault_point('reserva_tras_primera_escritura');
    v_need := v_need - v_take;
    exit when v_need = 0;
  end loop;

  if v_need > 0 then
    select name into v_name from public.coffees where id = p_coffee;
    select min(s.rest_until) into v_rest from private.lot_stock_rows(p_coffee, null) s
     where s.status = 'En reposo' and s.available_g > 0;
    perform private.biz('stock_insuficiente',
      case when v_rest is not null then
        format('Hay %s listos de %s y pediste %s. El próximo lote todavía está en reposo: elegí otro café o esperá hasta %s.',
          private.fmt_g(v_total), v_name, private.fmt_g(p_grams), private.human_when(v_rest))
      else
        format('No alcanza %s: hay %s disponibles y pediste %s.', v_name, private.fmt_g(v_total), private.fmt_g(p_grams))
      end,
      jsonb_build_object('cafe', v_name, 'disponible_g', v_total, 'pedido_g', p_grams, 'reposo_hasta', v_rest));
  end if;
end $$;

create or replace function private.release_order_allocations(p_order uuid, p_cmd uuid, p_reason text)
returns int language plpgsql set search_path = '' as $$
declare v_n int; v_lot uuid;
begin
  update public.order_allocations a set state = 'liberada', closed_at = private.now()
    from public.order_lines l
   where l.id = a.order_line_id and l.order_id = p_order and a.state = 'reservada';
  get diagnostics v_n = row_count;
  for v_lot in select distinct a.lot_id from public.order_allocations a
                 join public.order_lines l on l.id = a.order_line_id where l.order_id = p_order loop
    perform private.sync_lot_status(v_lot, p_cmd, p_reason);
  end loop;
  return v_n;
end $$;

-- Consumo físico al entregar: reservada → consumida + movimiento de salida.
create or replace function private.consume_order_allocations(p_order uuid, p_cmd uuid)
returns int language plpgsql set search_path = '' as $$
declare a record; v_n int := 0;
begin
  for a in select al.* from public.order_allocations al join public.order_lines l on l.id = al.order_line_id
            where l.order_id = p_order and al.state = 'reservada' for update of al loop
    update public.order_allocations set state = 'consumida', closed_at = private.now() where id = a.id;
    insert into public.lot_movements (lot_id, kind, grams, order_line_id, allocation_id, command_id, created_at)
    values (a.lot_id, 'entrega', -a.grams, a.order_line_id, a.id, p_cmd, private.now());
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------- Confirmar pedido: congela precios, valida crédito, reserva ----------
create or replace function private.confirm_order(p_order uuid, p_cmd uuid, p_to public.order_status default 'Confirmado')
returns jsonb language plpgsql set search_path = '' as $$
declare o public.orders; l record; v_price bigint; v_sub bigint := 0; v_ship bigint := 0;
        v_cfg public.settings := private.cfg(); v_today date := private.today(); v_cs jsonb; v_kg int;
        v_from public.order_status;
begin
  select * into o from public.orders where id = p_order for update;
  v_from := o.status;
  perform private.assert_transition(o.status, p_to);
  if not exists (select 1 from public.order_lines where order_id = o.id) then
    perform private.biz('pedido_vacio', 'El pedido no tiene productos.', '{}');
  end if;

  for l in select * from public.order_lines where order_id = o.id and kind = 'cafe' order by line_no loop
    v_price := case when o.replacement_for_return_id is not null then 0
                    else private.price_for(o.price_list_id, l.coffee_id, l.presentation, v_today) end;
    update public.order_lines set unit_price = v_price, line_total = v_price * l.qty where id = l.id;
    v_sub := v_sub + v_price * l.qty;
  end loop;

  if o.channel = 'web' and o.fulfillment = 'envio' and o.replacement_for_return_id is null then
    v_ship := case when v_sub >= v_cfg.free_shipping_from then 0 else v_cfg.shipping_fee end;
  end if;

  if o.channel = 'mayorista' and o.replacement_for_return_id is null then
    select coalesce(sum(qty), 0) into v_kg from public.order_lines where order_id = o.id;
    if v_kg < v_cfg.min_wholesale_kg then
      perform private.biz('minimo_mayorista',
        format('El pedido mínimo es de %s kg y este suma %s kg.', v_cfg.min_wholesale_kg, v_kg), '{}');
    end if;
    v_cs := private.credit_status(o.customer_id, v_sub + v_ship, o.id);
    if (v_cs ->> 'bloqueado')::boolean then
      perform private.biz('mayorista_bloqueado', v_cs ->> 'mensaje', v_cs);
    end if;
  end if;

  for l in select * from public.order_lines where order_id = o.id and kind = 'cafe' order by line_no loop
    perform private.reserve(l.id, l.coffee_id, l.grams, o.channel, private.unit_grams(l.presentation), p_cmd);
  end loop;

  update public.orders set status = p_to, subtotal = v_sub, shipping_fee = v_ship, total = v_sub + v_ship,
         confirmed_at = private.now(), hold_reason = null, revision = revision + 1
   where id = o.id returning * into o;
  perform private.emit(p_cmd, 'pedido', o.id, o.revision, 'pedido_confirmado', v_from::text, p_to::text,
    jsonb_build_object('total', o.total, 'reservado_g',
      (select sum(grams) from public.order_lines where order_id = o.id and kind = 'cafe')));
  for l in select distinct a.lot_id from public.order_allocations a join public.order_lines ol on ol.id = a.order_line_id
            where ol.order_id = o.id loop
    perform private.sync_lot_status(l.lot_id, p_cmd);
  end loop;
  return jsonb_build_object('pedido_id', o.id, 'numero', o.number, 'estado', o.status, 'total', o.total,
    'revision', o.revision);
end $$;

-- Inserta líneas de café desde un arreglo jsonb [{cafe_id, presentacion, molienda, cantidad}]
create or replace function private.insert_coffee_lines(p_order uuid, p_items jsonb, p_allowed text[])
returns void language plpgsql set search_path = '' as $$
declare it jsonb; n int := 0; v_pres text; v_qty int; v_coffee uuid;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    perform private.biz('pedido_vacio', 'Agregá al menos un café.', '{}');
  end if;
  if jsonb_array_length(p_items) > 20 then
    perform private.biz('pedido_muy_largo', 'Máximo 20 líneas por pedido.', '{}');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    v_pres := it ->> 'presentacion';
    v_qty := (it ->> 'cantidad')::int;
    v_coffee := (it ->> 'cafe_id')::uuid;
    if v_pres is null or not (v_pres = any(p_allowed)) then
      perform private.biz('presentacion_invalida', 'Elegí una presentación válida.', jsonb_build_object('linea', n));
    end if;
    if v_qty is null or v_qty < 1 or v_qty > 200 then
      perform private.biz('cantidad_invalida', 'La cantidad tiene que ser entre 1 y 200.', jsonb_build_object('linea', n));
    end if;
    if not exists (select 1 from public.coffees where id = v_coffee and active) then
      perform private.biz('cafe_inexistente', 'Ese café ya no está en el catálogo.', jsonb_build_object('linea', n));
    end if;
    if coalesce(it ->> 'molienda', 'grano') not in ('grano','espresso','filtro','prensa francesa') then
      perform private.biz('molienda_invalida', 'Elegí tu molienda: grano, espresso, filtro o prensa francesa.', jsonb_build_object('linea', n));
    end if;
    insert into public.order_lines (order_id, line_no, kind, coffee_id, presentation, grind, qty, grams)
    values (p_order, n, 'cafe', v_coffee, v_pres, coalesce(it ->> 'molienda', 'grano'), v_qty,
            v_qty * private.unit_grams(v_pres));
  end loop;
end $$;
