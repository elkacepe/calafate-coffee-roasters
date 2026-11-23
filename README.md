# Calafate Coffee Roasters

Sistema de punta a punta para una cafetería que tuesta su propio café y lo vende por **tres canales que compiten por el mismo lote**: la barra, la web minorista y los mayoristas (hoteles, restaurantes, casas de té). Cada pedido reserva gramos de un **lote concreto** en el momento de confirmarse, dentro de una función de la base. El stock, los saldos y las capacidades se calculan siempre a partir de sus movimientos, así que no pueden «mentir».

React 18 + Vite + Tailwind CSS · Supabase (Postgres, Auth, RLS) · mobile first (360 px).

---

## 1. Cómo arrancar

**Node 20 o superior.**

```bash
npm install
cp .env.example .env.local        # completá URL y clave pública de tu proyecto
npm run dev                       # http://localhost:5173
npm test                          # pruebas del motor de reglas (Vitest)
npm run build                     # build de producción en dist/
```

### Base de datos (una sola vez)

**Opción A: SQL Editor de Supabase (proyecto nuevo y vacío)**
1. `npm run db:setup-sql` genera `supabase/setup_completo.sql`, que contiene las migraciones y la semilla.
2. Pegalo en *SQL Editor* y ejecutalo. Crea el esquema, las funciones, la RLS, los usuarios de prueba y los datos sintéticos.
3. En *Authentication → Providers → Email*, dejá **desactivado** «Confirm email». Las cuentas de prueba ya vienen confirmadas y no se usa recuperación por correo.

**Opción B: Supabase CLI**
```bash
supabase link --project-ref <tu-ref>
supabase db push                  # aplica supabase/migrations/*
psql "$DB_URL" -f supabase/seed.sql
```
En local alcanza con `supabase start` y después `supabase db reset` (aplica migraciones y semilla).

`.env.example` solo trae nombres de variables y valores de prueba. **La clave `service_role` no se usa en ninguna parte**: ni en el navegador ni en el repositorio.

### Cuentas de prueba

Todas usan la contraseña `Calafate2026!`. Las cuentas se crean desde la semilla y el rol se asigna en la tabla `profiles`: no existe un formulario público de registro ni de cambio de rol.

| Correo | Rol | Entra a |
|---|---|---|
| admin@calafate.test | Administración | `/admin` |
| barra@calafate.test | Barra | `/barra` |
| tostaduria@calafate.test | Tostaduría y depósito | `/tostaduria` |
| reparto@calafate.test | Reparto | `/reparto` |
| hotel@calafate.test | Mayorista · Hotel Lenga Azul | `/mayorista` |
| resto@calafate.test | Mayorista · Restó Fogón del Ñire | `/mayorista` |

El público compra sin cuenta en `/` y sigue su pedido en `/seguimiento` con el número y el celular.

---

## 2. Dónde está cada cosa

```
supabase/
  migrations/
    …0100_esquema.sql     tablas, tipos, transiciones válidas del pedido
    …0200_motor.sql       reloj, estado de lote, stock derivado, reservas FIFO, crédito, confirmación
    …0300_comandos.sql    un manejador por comando (ventas, tueste, barra, reparto, devoluciones, cuenta, propuestas)
    …0400_api.sql         run_command (idempotencia + registro) y lecturas RPC con chequeo de rol
    …0500_informes.sql    ventas por canal, merma, deudores, conciliación
    …0600_seguridad.sql   RLS en todas las tablas, grants mínimos
  seed.sql                datos sintéticos (re-ejecutarlo reinicia todo)
  tests/
    00_local_supabase_mock.sql   simula auth/roles de Supabase en un Postgres pelado
    10_dominio.sql               pruebas de reglas, RLS, idempotencia, rollback, conciliación
    20_concurrencia.sh           dos sesiones reales compitiendo
src/
  domain/rules.js         motor de reglas puro (previsualización) + rules.test.js
  lib/                    cliente Supabase, useCommand (ids de comando), formatos, CSV, WhatsApp
  auth/                   sesión, perfil y guardas de ruta
  components/             UI base, detalle de pedido, tarjetas de lote, layouts
  pages/
    publico/              catálogo, carrito (borrador → datos → revisión → confirmar), seguimiento, ingreso
    mayorista/            comprar, pedidos y reclamos, cuenta corriente
    barra/                caja/POS, retiros, stock
    tostaduria/           lotes, registrar tueste, café verde, insumos
    reparto/              recorridos del día
    admin/                inicio, pedidos, reparto, devoluciones, cuentas, lotes, caja y propuestas, precios, zonas, informes, auditoría
```

**Lógica de datos:** toda escritura pasa por `public.run_command(id, tipo, datos, revisión_esperada)`, que llama a `private.h_<tipo>`. Las pantallas solo leen (RLS o RPC de lectura) y envían comandos. `src/domain/rules.js` replica las reglas para mostrar merma, totales o capacidad antes de enviar, pero **la base es la autoridad** y vuelve a validar todo.

---

## 3. Modelo

| Dato editable | Instantánea histórica (se congela) | Derivado (se calcula, nunca se guarda) |
|---|---|---|
| cafés, blend, bebidas, zonas, listas de precio (versionadas), clientes, `settings` | precio y total de cada línea al confirmar · costo del kilo tostado del lote · `rest_until`/`barra_only_from` del lote · envío · efectivo esperado del cierre · costo por reserva | stock por lote (`lot_movements` − reservas), verde, insumos, saldo de cuenta, carga del recorrido, intentos fallidos, estado efectivo del lote |

- **Unidad base:** gramos enteros. **Dinero:** pesos enteros. La merma se redondea a 2 decimales y el costo por kg al peso más cercano.
- **Reservado ≠ consumido:** `order_allocations.state` pasa de `reservada` a `consumida` (y suma un movimiento físico de salida) o a `liberada`.
- **Transiciones de pedido** en la tabla `order_transitions`, validadas por `private.assert_transition`.
- **Trazabilidad:** `commands` guarda id, tipo, entidad, actor, rol, instante, revisión esperada y resultante, datos, hash y resultado. `domain_events` guarda comando de origen, estado anterior y nuevo, efecto y motivo. `change_proposals` guarda registro y versión de partida, cambios, motivo, creador, decisión y decisor (con un CHECK que obliga a que decisor ≠ creador).

### Garantías de consistencia (en la base)

- **Reserva:** `SELECT … FOR UPDATE` sobre todos los lotes del café en orden fijo; luego reparte FIFO en bolsas enteras y puede partir la línea entre lotes. Dos transacciones no pueden tomar el último kilo.
- **Idempotencia:** mismo id + mismos datos → devuelve el resultado guardado (`repetido: true`). Mismo id + otros datos → `comando_conflicto`, sin escrituras.
- **Revisión:** cada entidad tiene `revision`. Si la revisión esperada no coincide → `revision_desactualizada`, sin cambios.
- **Rechazo de negocio** (SQLSTATE `CF001`): se revierte el subbloque completo y el comando queda «rechazado», sin eventos.
- **Error inesperado:** se revierte todo, incluido el registro del comando, así que reintentar el mismo id aplica una sola vez.
- Los cierres y movimientos confirmados no se editan: las correcciones son propuestas que, al aprobarse, crean un ajuste vinculado.

---

## 4. Reglas implementadas (dónde)

| Regla | Función |
|---|---|
| Stock por lote, reserva FIFO, partición entre lotes | `private.reserve`, `private.lot_stock_rows` |
| Tueste: descuenta verde, calcula merma, pide motivo fuera de 12–20 % | `h_registrar_tueste` |
| Reposo 24 h · 30 días → Solo barra · Agotado en cero | `private.lot_status_at` (instantáneas por lote) + `refresh_lot_states()` al abrir paneles |
| Recurrentes del lunes 8 h · bloqueo mayorista 40 % | `h_correr_recurrentes` (se dispara al abrir el panel de admin con id derivado de la fecha) · `wholesale_block_pct` |
| Barra por receta + cierre de caja con motivo > $2.000 | `h_vender_barra`, `h_cerrar_caja` |
| Recorrido 40 kg · no entregado conserva reserva · 2º fallo decide admin | `h_asignar_a_recorrido`, `h_registrar_entrega` |
| Devoluciones 7 días · cerrada vuelve al lote · resto merma · reposición / NC / reintegro | `create_return`, `h_decidir_devolucion` |
| Cuenta corriente 15 días · bloqueo por vencido > 15 días o límite | `private.credit_status` |
| Precio congelado al confirmar · versiones con vigencia | `private.confirm_order`, `price_items` |

---

## 5. Qué está simulado y cómo se comporta

- **Pagos:** no hay pasarela. Los cobros se registran a mano: método en el ticket de barra, en el retiro o en la entrega, y pagos de mayoristas en *Admin → Cuentas*. «QR» y «tarjeta» son solo etiquetas. **Punto de conexión:** `h_vender_barra`, `h_entregar_retiro`, `h_registrar_entrega` (`cobro`) y `h_registrar_pago`.
- **Avisos:** no hay email ni SMS. Cada aviso es un botón que abre `wa.me` con el texto ya armado (`src/lib/whatsapp.js`): aviso de pedido, «estoy llegando», hoja de ruta y recordatorio de saldo.
- **Mapas:** no hay. Las zonas son una lista editable (*Admin → Zonas*).
- **Tareas programadas:** no hacen falta. Los estados por tiempo se recalculan al abrir los paneles de lotes, barra o admin. Los recurrentes se reservan al abrir el panel de admin un lunes desde las 8; si se abre 20 veces, el id de comando es el mismo y no se duplica nada. Opcional con `pg_cron`: `select cron.schedule('recurrentes', '0 11 * * 1', 'select private.cron_lunes()');` (11 UTC = 8 h de Argentina).
- **Reloj de prueba:** `private.now()` lee `app.now` **solo** en sesiones del dueño (`postgres`), que son la semilla y las pruebas. Desde la API siempre es `now()`.
- **Falla inyectable:** si existe la fila `private.test_faults('reserva_tras_primera_escritura')`, la reserva falla después de su primera escritura. Solo el dueño puede escribir en esa tabla y se usa en las pruebas de rollback.

---

## 6. Datos de ejemplo y cómo reiniciarlos

`supabase/seed.sql` vacía todo y lo vuelve a cargar. Para volver al estado inicial, **ejecutalo de nuevo** en el SQL Editor (o con `supabase db reset`). La historia se arma llamando a las mismas funciones de negocio con un reloj simulado, anclado al **último lunes a las 8:00** (hora de Argentina) anterior a la carga.

- 5 cafés verdes ($18.000–$34.000/kg, ingreso inicial 40–90 kg), 5 orígenes y el blend de la casa (60 % Brasil + 40 % Colombia).
- **14 lotes**: 2 en reposo (tostados hoy antes de abrir), 2 Solo barra, 2 Agotado y el resto Disponible. Uno tiene merma fuera de rango, con su motivo.
- **40 pedidos**: 13 tickets de barra, 14 web y 13 mayoristas (incluida una reposición). Hay pedidos en todos los estados salvo Borrador.
- **6 mayoristas** sintéticos: tres hoteles, dos restaurantes y una casa de té. Listas Gastronomía A (límite $600.000) y B ($300.000), con un cambio de precio futuro (blend A a $48.000 dentro de 7 días).
- **2 recorridos de hoy**: Centro 10–13 en curso y Costanera (zona hotelera) 15–18 planificado, con la reposición del Hotel Viento Blanco. Además hay recorridos históricos cerrados y un pedido «Para reprogramar».
- **6 devoluciones**, una en cada estado: Pedida, En revisión, Aceptada (reposición), Rechazada, Resuelta con NC y Resuelta con reintegro.
- **1 cierre de caja** con diferencia y motivo, **2 propuestas**: una pendiente sobre el cierre (creada por barra) y una rechazada sobre un lote (creada por tostaduría y rechazada por admin).
- **6 comandos** sobre el pedido del Bodegón La Matra: 5 aplicados con revisiones 1→5 y 1 rechazado por revisión vieja, sin evento de dominio.
- **Caso de aceptación preparado:** el Hotel Lenga Azul tiene $264.000 vencidos hace 18 días y su recurrente de 6 kg de blend quedó **Retenido** el lunes a las 8.

### Reproducir el caso del hotel en la app
1. Ingresá como `admin@`. En *Inicio* vas a ver el pedido retenido.
2. En *Cuentas → Hotel Lenga Azul*, registrá un pago de $264.000. Si repetís el toque, no se duplica.
3. Tocá «Liberar y reservar»: queda Confirmado y reserva 6 kg del lote disponible más antiguo.
4. En *Pedidos*, pasalo a En preparación y después a Listo. En *Reparto*, asignalo al recorrido Costanera 15–18 y tocá «Salir».
5. Ingresá como `reparto@`, tocá «Entregado» y después «El cliente rechazó una bolsa» (1 bolsa, mal sellada).
6. Como `admin@`, en *Devoluciones*, aceptá con nota de crédito. Se registra la merma y el saldo queda en **$264.000 − $44.000 = $220.000**.

---

## 7. Pruebas

```bash
npm test                                   # 19 pruebas del motor JS (reloj fijo, unidades, redondeos)
DB_URL=postgresql://…/base_vacia ./scripts/test-db-local.sh   # Postgres local: migraciones + semilla + pruebas
```

`10_dominio.sql` cubre:
- el caso de 1.000 g verdes → 850 g tostados → 600 g disponibles tras vender 250 g;
- merma, reposo, Solo barra, receta de barra y cierre de caja;
- capacidad del recorrido, segundo fallo de entrega, devoluciones y plazos;
- el caso del hotel completo y los precios futuros;
- RLS con cuentas de distintos propietarios: ids ajenos, tablas hijas, escrituras directas e informes;
- que el CSV coincida con el total, que los indicadores sin datos no muestren 0 y la conciliación;
- idempotencia, revisión vieja, rollback con falla inyectada, y un solo cierre más un ajuste vinculado.

`20_concurrencia.sh` usa dos sesiones reales para probar el último recurso, la misma revisión, el mismo id en paralelo y el reintento tras perder la respuesta.

---

## 8. Decisiones que no estaban en el encargo

- **Vencimiento:** cada cargo vence a los 15 días de la entrega. Se bloquea cuando lo impago lleva **más de 15 días vencido** (el caso del briefing: 18 días). Los pagos se imputan FIFO a los cargos más viejos.
- **Límite de crédito:** se compara saldo + pedidos confirmados aún no entregados + el pedido nuevo.
- **Bloqueo mayorista:** cada lote nace con el % de `settings` (40 %) y administración lo cambia por lote. Protege la parte que los mayoristas todavía no usaron. La barra cuenta como canal minorista mientras el lote está Disponible; en Solo barra no hay bloqueo.
- **Agotado:** significa disponible = 0 (en mano − reservado). Si se cancela una reserva o vuelve una bolsa cerrada, el lote sube y recupera su estado por tiempo. Nunca se «reinicia»: el café nuevo siempre entra como lote nuevo.
- **Bolsas enteras:** la reserva parte una línea entre lotes solo en múltiplos de la bolsa (250 g o 1 kg), así cada bolsa sale de un único lote y la devolución sabe a qué lote vuelve.
- **Rechazo en la puerta:** el pedido queda «Entregado parcial», se carga completo a la cuenta y la bolsa rechazada se convierte en devolución, que administración resuelve. Por eso saldo = pedido − nota de crédito.
- **Reposición:** es un pedido nuevo a $0 que reserva stock y espera el próximo recorrido. La devolución queda «Resuelta» cuando se entrega.
- **Envasado:** se registra con descuento de bolsas vacías. No cambia el disponible del lote, porque las bolsas siguen siendo gramos de ese lote.
- **Barra:** hay un solo turno abierto a la vez y cada turno tiene un lote asignado, que se puede cambiar. Los retiros web en el local los entrega barra o administración.
- **Tostaduría no ve pedidos** (como pide el alcance): la preparación de pedidos (En preparación / Listo) la marca administración.
- Las fechas de entrega web excluyen el domingo, porque el local está cerrado.
