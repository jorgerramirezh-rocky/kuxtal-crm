-- Fase 5 Kaizen · RBAC lee el árbol real
-- funnel_ve_equipo(p_agente_id): devuelve los ids de funnel_agentes del subárbol
-- de un supervisor (él mismo + todos los que le reportan, directa o indirectamente).
-- Si no se pasa id, resuelve el agente del usuario actual por email (auth.jwt email).
-- Cycle-safe: la columna `ruta` corta cualquier ciclo en la jerarquía.
--
-- IMPORTANTE (seguridad): esta función es ADITIVA. NO cambia ninguna política RLS
-- viva. Sirve para que el frontend sepa "quién es mi equipo" y filtre datos que el
-- supervisor YA puede leer. RESTRINGIR el RLS de funnel_prospectos para que un
-- supervisor vea SOLO su equipo es un cambio de política aparte, que queda PENDIENTE
-- DE OK de George (ver el plan al pie).

create or replace function public.funnel_ve_equipo(p_agente_id bigint default null)
returns setof bigint
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
  with recursive raiz as (
    select coalesce(
      p_agente_id,
      (select a.id from public.funnel_agentes a
        where lower(a.email) = lower(auth.jwt() ->> 'email') limit 1)
    ) as id
  ),
  arbol as (
    select a.id, a.supervisor_id, array[a.id] as ruta
      from public.funnel_agentes a
     where a.id = (select id from raiz)
    union all
    select h.id, h.supervisor_id, t.ruta || h.id
      from public.funnel_agentes h
      join arbol t on h.supervisor_id = t.id
     where not (h.id = any(t.ruta))   -- corta ciclos: nadie se repite en la rama
  )
  select id from arbol
$fn$;

grant execute on function public.funnel_ve_equipo(bigint) to authenticated;

comment on function public.funnel_ve_equipo(bigint) is
  'Fase 5 Kaizen. Devuelve los ids de funnel_agentes del subárbol de un supervisor (el mismo + todos los que le reportan, directa o indirectamente). Sin id, resuelve el agente del usuario actual por email. Cycle-safe. Aditiva: NO cambia RLS.';

-- ─────────────────────────────────────────────────────────────────────────────
-- PENDIENTE DE OK DE GEORGE (cambio de seguridad — NO aplicado en esta migración):
-- Si se quiere que un supervisor vea SOLO su equipo (y no TODO), hay que cambiar la
-- política SELECT/UPDATE de funnel_prospectos. Hoy `funnel_ve_todo()` deja a gerencia
-- (incluye supervisores) ver todo. El cambio sería algo como reemplazar el OR por:
--
--   funnel_es_gerente_alto()                         -- gerentes generales/ventas/tmk: todo
--   OR (tmk_id in (select funnel_ve_equipo()))       -- supervisor: solo su subárbol
--   OR (tmk propio: el email del lead coincide)       -- TMK: solo lo suyo
--
-- Eso RESTRINGE acceso => es cambio de política de seguridad. Requiere OK explícito y
-- prueba con token real de cada rol antes de publicarse.
