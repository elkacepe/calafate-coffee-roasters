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
