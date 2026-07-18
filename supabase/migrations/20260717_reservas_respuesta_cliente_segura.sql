-- ─────────────────────────────────────────────────────────────────────────────
-- Reservas · Respuesta al cliente de forma SEGURA  (2026-07-17)
--
-- SIN APLICAR AUTOMÁTICAMENTE. Lo revisa y lo corre un humano (George/Lola) aparte.
-- Aplicar exactamente igual que las otras migraciones del repo:
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260717_reservas_respuesta_cliente_segura.sql').read()}))")
--
-- POR QUÉ EXISTE
--   El PR #32 (defectuoso) mostraba al cliente el campo `funnel_reservas.notas`.
--   `notas` es el BLOC INTERNO del staff (IDs de chat de terceros, decisiones
--   operativas) → FUGA DE PRIVACIDAD (hallazgo ALTA c186a189). Además el cliente
--   recibía 0 filas porque la RLS de funnel_reservas (funnel_ve_todo()) EXCLUYE al
--   rol cliente → la función quedaba rota (7b16f9a3).
--
-- QUÉ HACE (todo idempotente)
--   1. Campo dedicado `respuesta_socio` (texto que el staff escribe A PROPÓSITO para
--      el cliente) — ya existe vivo en la base; el ADD ... IF NOT EXISTS es no-op en
--      producción y solo cubre bases nuevas. NO se inventa `respuesta_cliente`: usar
--      dos campos con el mismo poder rompería la deduplicación (ya hay `respuesta_socio`).
--   2. Vista cara-al-cliente `funnel_reservas_cliente` con SOLO columnas seguras
--      (nunca `notas`, ni hotel/confirmación/itinerario/presupuesto/gestionado_por).
--      Filtra por el socio del claim server-controlled del JWT.
--   3. GRANT mínimo: SELECT de la vista a `authenticated`. La tabla base NO cambia:
--      su RLS sigue siendo staff-only, así el cliente NUNCA puede leer `notas` por
--      ninguna vía (ni tabla ni vista).
--   4. Endurecimiento: elimina la vista huérfana y peligrosa `reserva_publica`.
--
-- NO toca las policies de funnel_reservas. NO da acceso de tabla al cliente.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- 1) Campo dedicado que el staff escribe explícitamente PARA el cliente.
--    (Ya existe vivo — 0 filas usadas al 2026-07-17. IF NOT EXISTS = no-op seguro.)
alter table public.funnel_reservas
  add column if not exists respuesta_socio text;

comment on column public.funnel_reservas.respuesta_socio is
  'Respuesta que el staff escribe A PROPÓSITO para que la vea el cliente (vía la vista funnel_reservas_cliente). SEPARADA de notas (bloc interno del staff, que el cliente NUNCA debe ver).';

-- 2) Vista cara-al-cliente: SOLO columnas seguras + filtro por socio del claim.
--
--    Es una vista SECURITY DEFINER (security_invoker OFF, dueño postgres): por eso
--    puede leer la tabla base saltándose la RLS staff-only, PERO su propio WHERE la
--    encierra a las filas del socio del JWT. security_barrier=true garantiza que ese
--    predicado se evalúe ANTES que cualquier filtro que mande el cliente por PostgREST
--    (no se puede "colar" leyendo filas de otro socio).
--
--    El claim `app_metadata.socio_id` es server-controlled (lo pone el backend al
--    emitir el token, el cliente no lo puede falsificar) — mismo patrón ya vivo en
--    la policy socios_auth_select.
create or replace view public.funnel_reservas_cliente
  with (security_barrier = true) as
  select
    id,
    socio_id,
    destino,
    fecha_viaje,
    fecha_regreso,
    personas,
    estado,
    respuesta_socio,
    actualizado_en
  from public.funnel_reservas
  where socio_id = nullif(auth.jwt() -> 'app_metadata' ->> 'socio_id', '')::bigint;

comment on view public.funnel_reservas_cliente is
  'Vista cara-al-cliente de sus propias reservas. SOLO columnas seguras (nunca notas, hotel, confirmacion, itinerario, presupuestos ni gestionado_por). Encerrada por socio via el claim JWT app_metadata.socio_id (server-controlled). security_barrier: el filtro de socio se evalua primero. La tabla base funnel_reservas sigue con RLS staff-only.';

-- 3) GRANT mínimo. authenticated es el rol de PostgREST para cualquier sesión
--    logueada (el "cliente" es un claim de rol en el JWT, no un rol de Postgres).
--    NO se otorga a anon. La vista definer + su WHERE hacen el resto del trabajo.
grant select on public.funnel_reservas_cliente to authenticated;
revoke all on public.funnel_reservas_cliente from anon;

-- 4) ENDURECIMIENTO — quitar la vista huérfana `reserva_publica`.
--    Riesgo verificado el 2026-07-17: es una vista SECURITY DEFINER (dueño postgres,
--    security_invoker OFF) que hace `select ... from funnel_reservas` SIN NINGÚN
--    filtro por socio → si algún día alguien le hace GRANT SELECT, expone TODAS las
--    reservas de TODOS los socios (destino, hotel, confirmación, itinerario) saltándose
--    la RLS. Hoy no tiene GRANT a roles de app ni ningún objeto que dependa de ella
--    (verificado en pg_depend) ni referencia en el código → borrarla no rompe nada y
--    cierra un footgun. La reemplaza funnel_reservas_cliente (con filtro por socio).
--    (Si preferís conservarla, comentá esta línea — pero entonces NUNCA le des SELECT.)
drop view if exists public.reserva_publica;

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN sugerida DESPUÉS de aplicar (con un token real de rol cliente):
--   -- La vista NO debe tener columna notas:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='funnel_reservas_cliente';
--   -- El cliente logueado ve SOLO sus reservas (probar por PostgREST con su token):
--   GET /rest/v1/funnel_reservas_cliente?select=id,estado,respuesta_socio
--   -- Y NO puede leer notas por la tabla base (RLS staff-only debe dar 0 filas):
--   GET /rest/v1/funnel_reservas?select=notas   -> []  (o 401/permiso)
-- ─────────────────────────────────────────────────────────────────────────────
