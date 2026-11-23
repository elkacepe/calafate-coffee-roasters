-- =====================================================================
-- Calafate Coffee Roasters · 06 · RLS y permisos
-- Nadie escribe tablas de negocio directo: solo run_command (security definer).
-- Las lecturas pasan por RLS; rol y propietario salen de auth.uid() + profiles.
-- =====================================================================

-- Quién puede ver un pedido (también usado por tablas hijas).
create or replace function private.can_see_order(p_order uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.orders o
     where o.id = p_order and (
       private.has_role('admin')
       or (private.has_role('mayorista') and o.customer_id = private.my_customer())
       or (private.has_role('barra') and (o.channel = 'barra' or (o.channel = 'web' and o.fulfillment = 'retiro')))
       or (private.has_role('reparto') and exists (
            select 1 from public.route_stops s join public.routes r on r.id = s.route_id
             where s.order_id = o.id and r.driver_id = auth.uid()))))
$$;

create or replace function private.my_price_list() returns uuid
language sql stable security definer set search_path = '' as $$
  select c.price_list_id from public.wholesale_customers c where c.id = private.my_customer()
$$;

-- ---------- Activar RLS en TODAS las tablas expuestas ----------
do $$ declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------- Privilegios de tabla: solo lectura (la RLS filtra filas) ----------
revoke all on all tables in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;
grant select on all tables in schema public to authenticated;
-- Catálogos editables directamente por administración (la RLS exige rol admin):
grant insert, update on public.zones to authenticated;
grant update (price, active, sort) on public.drinks to authenticated;
grant update (tasting_notes, active, sort) on public.coffees to authenticated;

-- ---------- Políticas ----------
create policy settings_read on public.settings for select to authenticated using (true);
create policy order_transitions_read on public.order_transitions for select to authenticated using (true);
create policy command_types_read on public.command_types for select to authenticated using (true);
create policy coffees_read on public.coffees for select to authenticated using (true);
create policy coffees_admin_upd on public.coffees for update to authenticated using (private.has_role('admin')) with check (private.has_role('admin'));
create policy blend_read on public.blend_components for select to authenticated using (true);

create policy zones_read on public.zones for select to authenticated using (true);
create policy zones_admin_ins on public.zones for insert to authenticated with check (private.has_role('admin'));
create policy zones_admin_upd on public.zones for update to authenticated using (private.has_role('admin')) with check (private.has_role('admin'));

create policy drinks_read on public.drinks for select to authenticated using (private.has_role('admin','barra'));
create policy drinks_admin_upd on public.drinks for update to authenticated using (private.has_role('admin')) with check (private.has_role('admin'));

create policy green_read on public.green_coffees for select to authenticated using (private.has_role('admin','tostaduria'));
create policy green_mov_read on public.green_movements for select to authenticated using (private.has_role('admin','tostaduria'));
create policy lots_read on public.roast_batches for select to authenticated using (private.has_role('admin','tostaduria','barra'));
create policy roast_inputs_read on public.roast_inputs for select to authenticated using (private.has_role('admin','tostaduria'));
create policy lot_mov_read on public.lot_movements for select to authenticated using (private.has_role('admin','tostaduria'));
create policy alloc_read on public.order_allocations for select to authenticated using (private.has_role('admin','tostaduria'));
create policy packaging_read on public.packaging_runs for select to authenticated using (private.has_role('admin','tostaduria'));
create policy supplies_read on public.supplies for select to authenticated using (private.has_role('admin','tostaduria','barra'));
create policy supply_mov_read on public.supply_movements for select to authenticated using (private.has_role('admin','tostaduria'));
create policy waste_read on public.waste_records for select to authenticated using (private.has_role('admin','tostaduria'));

create policy price_lists_read on public.price_lists for select to authenticated
  using (private.has_role('admin') or id = private.my_price_list());
create policy price_items_read on public.price_items for select to authenticated
  using (private.has_role('admin') or list_id = private.my_price_list());

create policy customers_read on public.wholesale_customers for select to authenticated
  using (private.has_role('admin') or id = private.my_customer());
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or private.has_role('admin'));

create policy commands_read on public.commands for select to authenticated
  using (private.has_role('admin') or actor_id = auth.uid());
create policy events_read on public.domain_events for select to authenticated using (private.has_role('admin'));
create policy proposals_read on public.change_proposals for select to authenticated
  using (private.has_role('admin') or created_by = auth.uid());

create policy recurring_read on public.recurring_orders for select to authenticated
  using (private.has_role('admin') or customer_id = private.my_customer());
create policy recurring_lines_read on public.recurring_order_lines for select to authenticated
  using (exists (select 1 from public.recurring_orders r where r.id = recurring_id
                  and (private.has_role('admin') or r.customer_id = private.my_customer())));

create policy shifts_read on public.bar_shifts for select to authenticated using (private.has_role('admin','barra'));
create policy closures_read on public.cash_closures for select to authenticated using (private.has_role('admin','barra'));
create policy cash_adj_read on public.cash_adjustments for select to authenticated using (private.has_role('admin','barra'));

create policy orders_read on public.orders for select to authenticated using (private.can_see_order(id));
create policy order_lines_read on public.order_lines for select to authenticated using (private.can_see_order(order_id));
create policy order_payments_read on public.order_payments for select to authenticated
  using (private.has_role('admin') or (private.has_role('barra') and private.can_see_order(order_id)));

create policy routes_read on public.routes for select to authenticated
  using (private.has_role('admin') or driver_id = auth.uid());
create policy stops_read on public.route_stops for select to authenticated
  using (private.has_role('admin') or exists (select 1 from public.routes r where r.id = route_id and r.driver_id = auth.uid()));

create policy returns_read on public.returns for select to authenticated
  using (private.has_role('admin') or (customer_id is not null and customer_id = private.my_customer()));
create policy account_read on public.account_movements for select to authenticated
  using (private.has_role('admin') or customer_id = private.my_customer());
create policy refunds_read on public.refunds for select to authenticated using (private.has_role('admin'));

-- ---------- Funciones: acceso mínimo ----------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

-- Helpers que la RLS y los defaults evalúan con el rol de quien consulta:
grant execute on function private.now(), private.my_role(), private.my_customer(), private.my_price_list(),
  private.has_role(public.app_role[]), private.can_see_order(uuid) to authenticated, anon;

-- API
grant execute on function public.run_command(uuid, text, jsonb, int) to anon, authenticated;
grant execute on function public.public_catalog() to anon, authenticated;
grant execute on function public.track_order(int, text) to anon, authenticated;
grant execute on function public.wholesale_catalog(), public.credit_status(uuid), public.order_detail(uuid),
  public.lot_panel(), public.green_panel(), public.supply_panel(), public.shift_panel(), public.route_board(date),
  public.refresh_lot_states(), public.admin_open_panel(),
  public.report_sales(date, date), public.report_waste(date, date), public.report_debtors(), public.report_reconciliation()
  to authenticated;
