-- GENERADO por scripts/build-setup-sql.mjs: no editar a mano.
-- >>> 20261123000100_esquema.sql
-- =====================================================================
-- Calafate Coffee Roasters · 01 · Esquema
-- Unidad base de café: gramos (integer). Dinero: pesos argentinos enteros (bigint).
-- Dato editable  → tablas de catálogo (cafés, listas, zonas, bebidas, settings).
-- Instantánea    → valores congelados al confirmar (precios de línea, costo del lote,
--                  reposo/frescura del lote, envío, esperado de caja).
-- Derivado       → stock, reservas, saldos, carga de recorrido: SIEMPRE se calculan
--                  desde los movimientos; no hay contadores sueltos.
-- =====================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- ---------- Tipos ----------
create type public.app_role as enum ('admin','barra','tostaduria','reparto','mayorista');
create type public.order_channel as enum ('barra','web','mayorista');
create type public.order_status as enum ('Borrador','Confirmado','En preparación','Listo','En reparto',
  'Entregado','Entregado parcial','Para reprogramar','Cancelado','Retenido');
create type public.lot_status as enum ('En reposo','Disponible','Solo barra','Agotado');
create type public.return_status as enum ('Pedida','En revisión','Aceptada','Rechazada','Resuelta');

-- ---------- Reloj ----------
-- private.now() permite "viajar en el tiempo" SOLO a sesiones del dueño (semilla y pruebas
-- desde el editor SQL). Desde la API (sesión 'authenticator') siempre es now().
create or replace function private.now() returns timestamptz
language sql stable set search_path = '' as $$
  select case
    when session_user in ('postgres','supabase_admin')
     and nullif(current_setting('app.now', true), '') is not null
    then current_setting('app.now', true)::timestamptz
    else now() end
$$;

-- ---------- Configuración (una fila) ----------
create table public.settings (
  id int primary key default 1 check (id = 1),
  timezone text not null default 'America/Argentina/Buenos_Aires',
  rest_hours int not null default 24,
  fresh_days int not null default 30,
  shrink_min_pct numeric(5,2) not null default 12,
  shrink_max_pct numeric(5,2) not null default 20,
  wholesale_block_pct numeric(5,2) not null default 40,
  route_capacity_g int not null default 40000,
  cash_diff_threshold bigint not null default 2000,
  return_days int not null default 7,
  payment_terms_days int not null default 15,
  overdue_tolerance_days int not null default 15,
  shipping_fee bigint not null default 3500,
  free_shipping_from bigint not null default 50000,
  almond_extra bigint not null default 900,
  min_wholesale_kg int not null default 2,
  recurring_hour int not null default 8,
  store_open_hour int not null default 9,
  revision int not null default 1
);

create or replace function private.cfg() returns public.settings
language sql stable set search_path = '' as $$ select * from public.settings where id = 1 $$;

create or replace function private.today() returns date
language sql stable set search_path = '' as $$
  select (private.now() at time zone (select timezone from public.settings where id = 1))::date
$$;

-- ---------- Catálogos ----------
create table public.zones (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  notes text,
  active boolean not null default true,
  sort int not null default 0
);

create table public.green_coffees (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  country text not null,
  region text not null,
  process text not null,
  cost_per_kg bigint not null check (cost_per_kg > 0),
  active boolean not null default true
);

create table public.coffees (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  kind text not null check (kind in ('origen','blend')),
  green_id uuid references public.green_coffees(id),
  tasting_notes text,
  active boolean not null default true,
  sort int not null default 0,
  check ((kind = 'origen') = (green_id is not null))
);

create table public.blend_components (
  coffee_id uuid references public.coffees(id) on delete cascade,
  green_id uuid references public.green_coffees(id),
  pct numeric(5,2) not null check (pct > 0 and pct <= 100),
  primary key (coffee_id, green_id)
);

create table public.supplies (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  unit text not null check (unit in ('ml','u'))
);

create table public.drinks (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  price bigint not null check (price > 0),
  coffee_g int not null check (coffee_g > 0),
  milk_ml int not null default 0 check (milk_ml >= 0),
  active boolean not null default true,
  sort int not null default 0
);

create table public.price_lists (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  kind text not null check (kind in ('publico','mayorista')),
  credit_limit bigint check (credit_limit is null or credit_limit >= 0)
);

-- Versión de precio: nunca se actualiza, se agrega una nueva con vigencia desde una fecha.
create table public.price_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.price_lists(id),
  coffee_id uuid not null references public.coffees(id),
  presentation text not null check (presentation in ('bolsa_250','bolsa_1000','kg_grano','kg_molido')),
  price bigint not null check (price > 0),
  valid_from date not null,
  created_at timestamptz not null default private.now(),
  created_by uuid,
  unique (list_id, coffee_id, presentation, valid_from)
);

create table public.wholesale_customers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  kind text not null check (kind in ('hotel','restaurante','casa_de_te')),
  price_list_id uuid not null references public.price_lists(id),
  credit_limit bigint check (credit_limit is null or credit_limit >= 0),
  contact_name text,
  phone text,
  address text,
  zone_id uuid references public.zones(id),
  active boolean not null default true,
  revision int not null default 1
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null,
  full_name text not null,
  customer_id uuid references public.wholesale_customers(id),
  check ((role = 'mayorista') = (customer_id is not null))
);

-- ---------- Trazabilidad: comandos, eventos, propuestas ----------
create table public.command_types (
  type text primary key,
  handler text not null,
  allowed_roles public.app_role[] not null,
  allow_anon boolean not null default false,
  description text
);

create table public.commands (
  id uuid primary key,
  type text not null references public.command_types(type),
  entity text,
  entity_id uuid,
  actor_id uuid,
  actor_role public.app_role,
  expected_revision int,
  resulting_revision int,
  payload jsonb not null,
  payload_hash text not null,
  status text not null check (status in ('en_curso','aplicado','rechazado')),
  result jsonb,
  created_at timestamptz not null default private.now()
);

create table public.domain_events (
  id bigint generated always as identity primary key,
  command_id uuid references public.commands(id),
  entity text not null,
  entity_id uuid not null,
  entity_revision int,
  event_type text not null,
  from_state text,
  to_state text,
  effect jsonb not null default '{}',
  reason text,
  actor_id uuid,
  created_at timestamptz not null default private.now()
);
create index on public.domain_events (entity, entity_id);
create index on public.domain_events (command_id);

create table public.change_proposals (
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in ('cierre_caja','lote','cuenta')),
  entity_id uuid not null,
  base_revision int not null,
  changes jsonb not null,
  reason text not null,
  created_by uuid not null,
  created_at timestamptz not null default private.now(),
  status text not null default 'pendiente' check (status in ('pendiente','aprobada','rechazada')),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  applied_command_id uuid references public.commands(id),
  revision int not null default 1,
  check (decided_by is null or decided_by <> created_by)
);

-- ---------- Depósito: verde, lotes, envasado, insumos ----------
create table public.green_movements (
  id bigint generated always as identity primary key,
  green_id uuid not null references public.green_coffees(id),
  kind text not null check (kind in ('ingreso','tueste','ajuste')),
  grams int not null check (grams <> 0),
  cost_per_kg bigint,
  lot_id uuid,
  command_id uuid references public.commands(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default private.now()
);
create index on public.green_movements (green_id);

create table public.roast_batches (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  coffee_id uuid not null references public.coffees(id),
  roasted_at timestamptz not null,
  green_used_g int not null check (green_used_g > 0),
  roasted_g int not null check (roasted_g > 0 and roasted_g <= green_used_g),
  shrink_pct numeric(5,2) generated always as (round((green_used_g - roasted_g) * 100.0 / green_used_g, 2)) stored,
  shrink_reason text,
  -- instantáneas de reglas vigentes al tostar
  rest_until timestamptz not null,
  barra_only_from timestamptz not null,
  cost_per_kg bigint not null,          -- costo del kilo tostado (verde / rendimiento)
  wholesale_block_pct numeric(5,2) not null default 0 check (wholesale_block_pct between 0 and 100),
  status public.lot_status not null default 'En reposo',   -- cache visual; las reglas usan el estado efectivo
  revision int not null default 1,
  created_by uuid,
  command_id uuid references public.commands(id),
  created_at timestamptz not null default private.now()
);
alter table public.green_movements add foreign key (lot_id) references public.roast_batches(id);

create table public.roast_inputs (
  lot_id uuid references public.roast_batches(id),
  green_id uuid references public.green_coffees(id),
  grams int not null check (grams > 0),
  cost_per_kg bigint not null,
  primary key (lot_id, green_id)
);

-- ---------- Ventas: una sola tabla de pedidos para los tres canales ----------
create sequence public.order_number_seq start 1001;

create table public.recurring_orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.wholesale_customers(id),
  weekday int not null default 1 check (weekday between 1 and 7),
  active boolean not null default true,
  notes text
);
create table public.recurring_order_lines (
  id uuid primary key default gen_random_uuid(),
  recurring_id uuid not null references public.recurring_orders(id) on delete cascade,
  coffee_id uuid not null references public.coffees(id),
  presentation text not null check (presentation in ('kg_grano','kg_molido')),
  grind text not null default 'grano',
  qty int not null check (qty > 0)
);

create table public.bar_shifts (
  id uuid primary key default gen_random_uuid(),
  opened_at timestamptz not null,
  opened_by uuid,
  lot_id uuid not null references public.roast_batches(id),
  opening_cash bigint not null check (opening_cash >= 0),
  status text not null default 'abierto' check (status in ('abierto','cerrado')),
  revision int not null default 1
);
create unique index one_open_shift on public.bar_shifts ((status)) where status = 'abierto';

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  number int not null unique default nextval('public.order_number_seq'),
  channel public.order_channel not null,
  status public.order_status not null,
  customer_id uuid references public.wholesale_customers(id),
  retail_name text,
  retail_phone text,
  fulfillment text not null check (fulfillment in ('barra','retiro','envio')),
  zone_id uuid references public.zones(id),
  address text,
  scheduled_date date,
  price_list_id uuid references public.price_lists(id),
  subtotal bigint,
  shipping_fee bigint,
  total bigint,
  payment_method text,
  recurring_id uuid references public.recurring_orders(id),
  recurring_date date,
  replacement_for_return_id uuid,
  shift_id uuid references public.bar_shifts(id),
  hold_reason text,
  notes text,
  revision int not null default 1,
  created_by uuid,
  created_at timestamptz not null default private.now(),
  confirmed_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  unique (recurring_id, recurring_date),
  check ((channel = 'mayorista') = (customer_id is not null)),
  check (channel <> 'web' or (retail_name is not null and retail_phone is not null)),
  check (channel <> 'barra' or shift_id is not null)
);
create index on public.orders (customer_id);
create index on public.orders (status);
create index on public.orders (channel, confirmed_at);

create table public.order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  line_no int not null,
  kind text not null check (kind in ('cafe','bebida')),
  coffee_id uuid references public.coffees(id),
  drink_id uuid references public.drinks(id),
  presentation text check (presentation in ('bolsa_250','bolsa_1000','kg_grano','kg_molido')),
  grind text,
  qty int not null check (qty > 0),
  grams int not null check (grams > 0),       -- gramos de café de la línea
  milk_ml int not null default 0,
  almond boolean not null default false,
  unit_price bigint,                          -- congelado al confirmar
  line_total bigint,                          -- congelado al confirmar
  unique (order_id, line_no),
  check ((kind = 'cafe') = (coffee_id is not null and drink_id is null))
);
create index on public.order_lines (order_id);

-- Reserva por lote. Recurso reservado ≠ consumido: el estado lo distingue.
create table public.order_allocations (
  id bigint generated always as identity primary key,
  order_line_id uuid not null references public.order_lines(id) on delete cascade,
  lot_id uuid not null references public.roast_batches(id),
  grams int not null check (grams > 0),
  cost_per_kg bigint not null,                -- costo histórico del lote
  state text not null default 'reservada' check (state in ('reservada','consumida','liberada')),
  command_id uuid references public.commands(id),
  created_at timestamptz not null default private.now(),
  closed_at timestamptz
);
create index on public.order_allocations (lot_id, state);
create index on public.order_allocations (order_line_id);

-- Movimientos físicos del lote. on_hand = suma. No se borra nunca.
create table public.lot_movements (
  id bigint generated always as identity primary key,
  lot_id uuid not null references public.roast_batches(id),
  kind text not null check (kind in ('tueste','barra','entrega','devolucion','ajuste')),
  grams int not null check (grams <> 0),
  order_line_id uuid references public.order_lines(id),
  allocation_id bigint references public.order_allocations(id),
  return_id uuid,
  proposal_id uuid references public.change_proposals(id),
  command_id uuid references public.commands(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default private.now()
);
create index on public.lot_movements (lot_id);

create table public.packaging_runs (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references public.roast_batches(id),
  format text not null check (format in ('bolsa_250','bolsa_1000')),
  bags int not null check (bags > 0),
  grams int not null check (grams > 0),
  command_id uuid references public.commands(id),
  created_by uuid,
  created_at timestamptz not null default private.now()
);

create table public.supply_movements (
  id bigint generated always as identity primary key,
  supply_id uuid not null references public.supplies(id),
  kind text not null check (kind in ('ingreso','barra','envasado','ajuste')),
  qty int not null check (qty <> 0),
  order_line_id uuid references public.order_lines(id),
  packaging_id uuid references public.packaging_runs(id),
  command_id uuid references public.commands(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default private.now()
);
create index on public.supply_movements (supply_id);

create table public.order_payments (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id),
  amount bigint not null check (amount > 0),
  method text not null check (method in ('efectivo','tarjeta','transferencia','qr')),
  command_id uuid references public.commands(id),
  created_by uuid,
  created_at timestamptz not null default private.now()
);
create index on public.order_payments (order_id);

-- ---------- Barra: cierres ----------
create table public.cash_closures (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null unique references public.bar_shifts(id),
  closed_at timestamptz not null,
  closed_by uuid,
  expected_cash bigint not null,      -- instantánea al cerrar
  counted_cash bigint not null,
  difference bigint generated always as (counted_cash - expected_cash) stored,
  reason text,
  revision int not null default 1,
  command_id uuid references public.commands(id)
);
create table public.cash_adjustments (
  id uuid primary key default gen_random_uuid(),
  closure_id uuid not null references public.cash_closures(id),
  amount bigint not null check (amount <> 0),
  reason text not null,
  proposal_id uuid not null unique references public.change_proposals(id),
  command_id uuid references public.commands(id),
  created_by uuid,
  created_at timestamptz not null default private.now()
);

-- ---------- Reparto ----------
create table public.routes (
  id uuid primary key default gen_random_uuid(),
  route_date date not null,
  zone_id uuid not null references public.zones(id),
  slot text not null check (slot in ('10-13','15-18')),
  capacity_g int not null check (capacity_g > 0),
  driver_id uuid references public.profiles(id),
  status text not null default 'Planificado' check (status in ('Planificado','En curso','Cerrado')),
  revision int not null default 1,
  created_at timestamptz not null default private.now(),
  unique (route_date, zone_id, slot)
);
create table public.route_stops (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id),
  order_id uuid not null references public.orders(id),
  seq int not null,
  result text not null default 'pendiente' check (result in ('pendiente','entregado','entregado_parcial','no_entregado','quitado')),
  attempted_at timestamptz,
  note text,
  command_id uuid references public.commands(id)
);
create unique index one_active_stop_per_order on public.route_stops (order_id) where result = 'pendiente';
create index on public.route_stops (route_id);

-- ---------- Devoluciones, merma, cuenta corriente ----------
create sequence public.return_number_seq start 501;
create table public.returns (
  id uuid primary key default gen_random_uuid(),
  number int not null unique default nextval('public.return_number_seq'),
  order_id uuid not null references public.orders(id),
  order_line_id uuid not null references public.order_lines(id),
  customer_id uuid references public.wholesale_customers(id),
  bags int not null check (bags > 0),
  grams int not null check (grams > 0),
  lot_splits jsonb not null,               -- [{lot_id, grams}] según de qué lote salió cada bolsa
  condition text not null check (condition in ('cerrada','abierta','defectuosa','mal_sellada')),
  reason text not null,
  status public.return_status not null default 'Pedida',
  resolution text check (resolution in ('reposicion','nota_credito','reintegro')),
  amount bigint,                           -- valor a precio congelado de la línea
  replacement_order_id uuid references public.orders(id),
  decision_note text,
  requested_by uuid,
  requested_at timestamptz not null,
  decided_by uuid,
  decided_at timestamptz,
  resolved_at timestamptz,
  revision int not null default 1
);
alter table public.orders add foreign key (replacement_for_return_id) references public.returns(id);
alter table public.lot_movements add foreign key (return_id) references public.returns(id);

create table public.waste_records (
  id bigint generated always as identity primary key,
  lot_id uuid not null references public.roast_batches(id),
  grams int not null check (grams > 0),
  source text not null check (source in ('devolucion','ajuste')),
  return_id uuid references public.returns(id),
  proposal_id uuid references public.change_proposals(id),
  reason text not null,
  command_id uuid references public.commands(id),
  created_at timestamptz not null default private.now()
);

create table public.account_movements (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.wholesale_customers(id),
  kind text not null check (kind in ('cargo','pago','nota_credito','ajuste')),
  amount bigint not null check (amount <> 0),   -- + suma deuda, − la baja
  order_id uuid references public.orders(id),
  return_id uuid references public.returns(id),
  proposal_id uuid references public.change_proposals(id),
  due_date date,
  method text,
  reference text,
  command_id uuid references public.commands(id),
  created_by uuid,
  created_at timestamptz not null default private.now(),
  check ((kind = 'cargo') = (amount > 0) or kind = 'ajuste'),
  check (kind <> 'cargo' or due_date is not null)
);
create index on public.account_movements (customer_id);
create unique index one_charge_per_order on public.account_movements (order_id) where kind = 'cargo';
create unique index one_credit_note_per_return on public.account_movements (return_id) where kind = 'nota_credito';

create table public.refunds (
  id bigint generated always as identity primary key,
  return_id uuid not null unique references public.returns(id),
  order_id uuid not null references public.orders(id),
  amount bigint not null check (amount > 0),
  method text not null,
  command_id uuid references public.commands(id),
  created_by uuid,
  created_at timestamptz not null default private.now()
);

-- ---------- Transiciones válidas del pedido ----------
create table public.order_transitions (
  from_status public.order_status not null,
  to_status public.order_status not null,
  action text not null,
  primary key (from_status, to_status)
);
insert into public.order_transitions values
 ('Borrador','Confirmado','confirmar'),
 ('Borrador','Retenido','retener (crédito)'),
 ('Borrador','Cancelado','cancelar'),
 ('Retenido','Confirmado','liberar'),
 ('Retenido','Cancelado','cancelar'),
 ('Confirmado','En preparación','preparar'),
 ('Confirmado','Cancelado','cancelar (libera reserva)'),
 ('Confirmado','Entregado','barra / retiro inmediato'),
 ('En preparación','Listo','terminar'),
 ('En preparación','Cancelado','cancelar (libera reserva)'),
 ('Listo','En reparto','iniciar recorrido'),
 ('Listo','Entregado','retiro en el local'),
 ('Listo','Cancelado','cancelar (libera reserva)'),
 ('En reparto','Entregado','entregar'),
 ('En reparto','Entregado parcial','entregar con rechazo'),
 ('En reparto','Para reprogramar','no entregado (reserva intacta)'),
 ('Para reprogramar','Listo','reasignar a recorrido'),
 ('Para reprogramar','Cancelado','admin cancela tras 2 intentos (libera reserva)');

create or replace function private.assert_transition(p_from public.order_status, p_to public.order_status)
returns void language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from public.order_transitions where from_status = p_from and to_status = p_to) then
    perform private.biz('transicion_invalida',
      format('Un pedido en «%s» no puede pasar a «%s».', p_from, p_to),
      jsonb_build_object('desde', p_from, 'hacia', p_to));
  end if;
end $$;

-- ---------- Fallas inyectables (solo pruebas, solo dueño puede escribir) ----------
create table private.test_faults (name text primary key);


-- >>> 20261123000200_motor.sql
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


-- >>> 20261123000300_comandos.sql
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


-- >>> 20261123000400_api.sql
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


-- >>> 20261123000500_informes.sql
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


-- >>> 20261123000600_seguridad.sql
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


-- >>> seed.sql
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
