-- =====================================================================
-- Calafate Coffee Roasters · 05 · Informes (solo lectura, solo administración)
-- Filas y resumen salen de la MISMA consulta base: el CSV y los totales coinciden.
-- =====================================================================

create or replace function private.sales_rows(p_from date, p_to date)
returns table (pedido_id uuid, numero int, fecha date, canal public.order_channel, estado public.order_status,
  cliente text, subtotal bigint, envio bigint, total bigint, costo bigint)
language sql stable set search_path = '' as $$
  select o.id, o.number, (o.confirmed_at at time zone (private.cfg()).timezone)::date, o.channel, o.status,
    coalesce(wc.name, o.retail_name, 'Barra'), coalesce(o.subtotal, 0), coalesce(o.shipping_fee, 0), coalesce(o.total, 0),
    -- costo histórico: gramos reservados/consumidos al costo congelado del lote + café de barra al costo del lote
    coalesce((select round(sum(a.grams * a.cost_per_kg) / 1000.0)::bigint from public.order_allocations a
               join public.order_lines l on l.id = a.order_line_id where l.order_id = o.id and a.state <> 'liberada'), 0)
    + coalesce((select round(sum(-m.grams * b.cost_per_kg) / 1000.0)::bigint from public.lot_movements m
               join public.order_lines l on l.id = m.order_line_id join public.roast_batches b on b.id = m.lot_id
               where l.order_id = o.id and m.kind = 'barra'), 0)
  from public.orders o left join public.wholesale_customers wc on wc.id = o.customer_id
  where o.status not in ('Borrador','Retenido','Cancelado')
    and o.replacement_for_return_id is null
    and o.confirmed_at is not null
    and (o.confirmed_at at time zone (private.cfg()).timezone)::date between p_from and p_to
$$;

create or replace function public.report_sales(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin');
  return (with r as (select * from private.sales_rows(p_from, p_to))
    select jsonb_build_object(
      'desde', p_from, 'hasta', p_to,
      'filas', (select coalesce(jsonb_agg(to_jsonb(r) order by r.fecha, r.numero), '[]') from r),
      'por_canal', (select coalesce(jsonb_object_agg(c.canal, jsonb_build_object(
          'pedidos', (select count(*) from r where r.canal = c.canal),
          'total', (select sum(total) from r where r.canal = c.canal),
          'costo', (select sum(costo) from r where r.canal = c.canal),
          'ticket_promedio', (select round(avg(total)) from r where r.canal = c.canal))), '{}')
        from (select unnest(enum_range(null::public.order_channel)) as canal) c),
      'total', (select sum(total) from r),
      'pedidos', (select count(*) from r),
      'notas_credito', (select -sum(amount) from public.account_movements
                         where kind = 'nota_credito' and (created_at at time zone (private.cfg()).timezone)::date between p_from and p_to),
      'reintegros', (select sum(amount) from public.refunds
                         where (created_at at time zone (private.cfg()).timezone)::date between p_from and p_to)));
end $$;

create or replace function public.report_waste(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_tz text := (private.cfg()).timezone;
begin
  perform private.require_role('admin');
  return jsonb_build_object(
    'tueste', (select jsonb_build_object('lotes', count(*), 'verde_g', sum(green_used_g), 'tostado_g', sum(roasted_g),
                 'merma_g', sum(green_used_g - roasted_g),
                 'merma_pct', case when sum(green_used_g) > 0 then round(sum(green_used_g - roasted_g) * 100.0 / sum(green_used_g), 2) end,
                 'fuera_de_rango', count(*) filter (where shrink_reason is not null))
               from public.roast_batches where (roasted_at at time zone v_tz)::date between p_from and p_to),
    'devoluciones', (select jsonb_build_object('registros', count(*), 'gramos', sum(grams))
               from public.waste_records where source = 'devolucion' and (created_at at time zone v_tz)::date between p_from and p_to),
    'ajustes', (select jsonb_build_object('registros', count(*), 'gramos', sum(grams))
               from public.waste_records where source = 'ajuste' and (created_at at time zone v_tz)::date between p_from and p_to),
    'por_lote', (select coalesce(jsonb_agg(jsonb_build_object('codigo', b.code, 'cafe', c.name, 'merma_tueste_g', b.green_used_g - b.roasted_g,
                    'merma_pct', b.shrink_pct, 'merma_devolucion_g', (select sum(grams) from public.waste_records w where w.lot_id = b.id))
                  order by b.roasted_at), '[]')
               from public.roast_batches b join public.coffees c on c.id = b.coffee_id
               where (b.roasted_at at time zone v_tz)::date between p_from and p_to));
end $$;

create or replace function public.report_debtors() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('cliente_id', c.id, 'cliente', c.name, 'tipo', c.kind, 'telefono', c.phone,
      'revision', c.revision, 'lista', pl.name, 'credito', private.credit_status(c.id),
      'retenidos', (select count(*) from public.orders o where o.customer_id = c.id and o.status = 'Retenido'))
    order by c.name), '[]')
    from public.wholesale_customers c join public.price_lists pl on pl.id = c.price_list_id where c.active);
end $$;

-- Conciliación: reconstruye desde eventos y registros de origen y muestra la diferencia (sin taparla).
create or replace function public.report_reconciliation() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role('admin');
  return jsonb_build_object(
    'cuentas', (select coalesce(jsonb_agg(jsonb_build_object('cliente', c.name,
        'saldo_movimientos', m.saldo,
        'saldo_reconstruido', r.cargos - r.pagos - r.notas + r.ajustes,
        'cargos_pedidos_entregados', r.cargos, 'pagos', r.pagos, 'notas_credito', r.notas, 'ajustes', r.ajustes,
        'diferencia', m.saldo - (r.cargos - r.pagos - r.notas + r.ajustes)) order by c.name), '[]')
      from public.wholesale_customers c
      cross join lateral (select coalesce(sum(amount), 0) saldo from public.account_movements where customer_id = c.id) m
      cross join lateral (select
          coalesce((select sum(o.total) from public.orders o where o.customer_id = c.id and o.status in ('Entregado','Entregado parcial')
                      and o.total > 0), 0) cargos,
          coalesce((select -sum(amount) from public.account_movements where customer_id = c.id and kind = 'pago'), 0) pagos,
          coalesce((select sum(r2.amount) from public.returns r2 where r2.customer_id = c.id and r2.resolution = 'nota_credito'
                      and r2.status in ('Aceptada','Resuelta')), 0) notas,
          coalesce((select sum(amount) from public.account_movements where customer_id = c.id and kind = 'ajuste'), 0) ajustes) r),
    'lotes', (select coalesce(jsonb_agg(jsonb_build_object('codigo', b.code,
        'en_mano_movimientos', (select coalesce(sum(grams), 0) from public.lot_movements where lot_id = b.id),
        'en_mano_reconstruido', b.roasted_g
            - coalesce((select sum(a.grams) from public.order_allocations a where a.lot_id = b.id and a.state = 'consumida'), 0)
            - coalesce((select sum(l.grams) from public.lot_movements m join public.order_lines l on l.id = m.order_line_id
                         where m.lot_id = b.id and m.kind = 'barra'), 0)
            + coalesce((select sum((sp ->> 'grams')::int) from public.returns r, jsonb_array_elements(r.lot_splits) sp
                         where (sp ->> 'lot_id')::uuid = b.id and r.condition = 'cerrada' and r.status in ('Aceptada','Resuelta')), 0)
            + coalesce((select sum(grams) from public.lot_movements where lot_id = b.id and kind = 'ajuste'), 0)
      ) order by b.roasted_at), '[]') from public.roast_batches b),
    'verde', (select coalesce(jsonb_agg(jsonb_build_object('verde', g.name,
        'stock_movimientos', private.green_stock(g.id),
        'ingresos', (select coalesce(sum(grams), 0) from public.green_movements where green_id = g.id and kind = 'ingreso'),
        'usado_en_lotes', (select coalesce(sum(grams), 0) from public.roast_inputs where green_id = g.id),
        'diferencia', private.green_stock(g.id)
            - (select coalesce(sum(grams), 0) from public.green_movements where green_id = g.id and kind in ('ingreso','ajuste'))
            + (select coalesce(sum(grams), 0) from public.roast_inputs where green_id = g.id)) order by g.name), '[]')
      from public.green_coffees g),
    'comandos', (select jsonb_build_object('aplicados', count(*) filter (where status = 'aplicado'),
        'rechazados', count(*) filter (where status = 'rechazado'),
        'rechazados_con_evento', (select count(*) from public.commands c2 where c2.status = 'rechazado'
                                    and exists (select 1 from public.domain_events e where e.command_id = c2.id)))
      from public.commands));
end $$;
