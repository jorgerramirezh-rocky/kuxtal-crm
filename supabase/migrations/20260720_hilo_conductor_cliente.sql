-- ─────────────────────────────────────────────────────────────────────────────
-- Hilo conductor único por cliente/familia  (Vista consolidada, primer ladrillo)
-- PENDIENTE George (feedback_lola c608e8bb): "un solo registro/vista con TODO el
-- recorrido de punta a punta (de lead a baja), sin perder nada".
--
-- SIN APLICAR AUTOMÁTICAMENTE. Lo revisa y lo corre un humano (George/Lola) aparte,
-- igual que las otras migraciones del repo, contra el proyecto KUXTAL
-- (tevzfdiumfekvapamovw):
--
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260720_hilo_conductor_cliente.sql').read()}))")
--
-- POR QUÉ EXISTE
--   Hoy el "expediente" de un socio (línea de tiempo en app.html, función
--   expedienteHTML) arma el hilo conductor A MANO en el navegador: 6 fetches
--   separados (funnel_prospectos, funnel_contratos, interacciones, usos,
--   funnel_reservas, más el propio socio) que el CLIENTE junta y ordena. Cada
--   pantalla nueva que quiera "todo el recorrido de esta familia" (reportes,
--   Rocky, otra vista admin) tendría que RE-IMPLEMENTAR esa misma unión a mano.
--   Este es el primer ladrillo para moverlo a la base: una vista única,
--   consolidada, que cualquier consumidor (app, script, Rocky) puede leer con
--   un solo SELECT.
--
-- QUÉ ES EL "cliente/familia" ACÁ (esquema es ley — verificado contra el código
-- vivo, no supuesto)
--   No existe una tabla `familia`/`cliente` separada: `socios.id` YA ES el
--   identificador estable de una familia socia (una fila = una membresía =
--   una familia), y es el mismo ancla que usa hoy expedienteHTML (agrupa por
--   `x.id`) y el propio audit trail (`socios_historial.registro_id`, PR #35).
--   Por eso esta vista NO crea una tabla de identidad nueva: reutiliza
--   `socios.id` como `cliente_id`, tal como ya lo hace el resto del sistema.
--   Alcance de este primer ladrillo: cubre el hilo de socios YA CONVERTIDOS
--   (con socio_id asignado en funnel_prospectos). Un lead que nunca llegó a
--   ser socio no tiene fila acá — vive solo en `funnel_prospectos` — porque
--   ninguna otra tabla del hilo (reservas/canjes/interacciones/historial) se
--   engancha a un prospecto sin socio_id en el esquema actual.
--
-- QUÉ HACE (aditivo, no destructivo, idempotente — CREATE OR REPLACE VIEW)
--   1. `public.cliente_hilo_conductor`: una fila por EVENTO del recorrido de
--      un socio/familia — alta, hitos del embudo (lead/presentación/asistió/
--      baja del embudo), contrato firmado, interacción (nota/llamada/WhatsApp/
--      edición/beneficio — sin duplicar 'uso', que ya entra desde `usos`),
--      canje de beneficio, reserva, y cambio de campo (reusa `socios_historial`
--      del PR #35). Columnas homogéneas: cliente_id, evento_tipo, evento_en,
--      titulo, detalle, fuente_tabla, fuente_id (para poder ir a la fila real).
--   2. RLS: mismo criterio de lectura que `socios_historial` (PR #35) — SOLO
--      admin/gerente_general/gerente_ventas. Vista SECURITY DEFINER con
--      security_barrier=true y el filtro de rol DENTRO de la vista (mismo
--      patrón ya usado por `funnel_reservas_cliente`, migración 20260717): acá
--      NO hay predicado de "es tu propio socio" porque es una vista de STAFF,
--      no cara-al-cliente — el gate es el ROL del JWT, evaluado antes que
--      cualquier filtro que mande PostgREST.
--
-- POR QUÉ VISTA Y NO TABLA NUEVA
--   Todo el dato YA EXISTE en las tablas fuente. Una tabla nueva necesitaría
--   triggers de sincronización en 6 tablas (más superficie, más riesgo, nada
--   reversible en un solo DROP). Una vista es de solo lectura, se recalcula
--   sola con cada fuente, y se puede tirar con un `drop view` sin dejar rastro
--   — el movimiento MÍNIMO y reversible para este primer ladrillo.
--
-- OJO REVISOR (dudas explícitas, por la lección "el esquema es ley")
--   - Asumo que los `id` de socios/funnel_prospectos/funnel_contratos/
--     interacciones/usos/funnel_reservas/socios_historial son todos `bigint`
--     (mismo patrón "generated always as identity" que ya se ve en
--     `socios_historial.id` y en `socios_historial.registro_id bigint`
--     referenciando `socios.id`). No pude confirmarlo contra el esquema vivo
--     (sin llave de DB en este obrero) — si algún `id` real es `uuid`, el
--     UNION ALL de esta vista fallará al aplicar y hay que ajustar el cast.
--   - Las columnas usadas (socio_id, creado_en, presenta_en, recepcion_en,
--     baja_en, motivo_baja, tipo_membresia, monto, plan_pago, firmado_en,
--     tipo, nota, oferta_id, codigo, usado_en, destino, fecha_viaje, personas,
--     estado) SÍ están confirmadas: son las mismas que ya usa en producción
--     `expedienteHTML`/`getJSON` en app.html (funcionando hoy contra la base
--     real), no son un supuesto mío.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create or replace view public.cliente_hilo_conductor
  with (security_barrier = true) as
  with eventos as (
    -- 1) Alta de socio (arranque del hilo cuando no hubo lead registrado antes)
    select
      s.id::bigint                as cliente_id,
      'alta'::text                as evento_tipo,
      s.ingreso::timestamptz      as evento_en,
      'Se hizo socio N.' || coalesce(s.no::text, '—') as titulo,
      case when s.tipo is not null then 'Membresía ' || s.tipo else '' end as detalle,
      'socios'::text              as fuente_tabla,
      s.id::bigint                as fuente_id
    from public.socios s
    where s.ingreso is not null

    union all
    -- 2) Hitos del embudo, ligados al socio en que terminó convirtiendo
    select p.socio_id::bigint, 'lead', p.creado_en,
      'Entró al embudo como prospecto (lead)', ''::text,
      'funnel_prospectos', p.id::bigint
    from public.funnel_prospectos p
    where p.socio_id is not null and p.creado_en is not null

    union all
    select p.socio_id::bigint, 'presentacion', p.presenta_en,
      'Citado a presentación', ''::text,
      'funnel_prospectos', p.id::bigint
    from public.funnel_prospectos p
    where p.socio_id is not null and p.presenta_en is not null

    union all
    select p.socio_id::bigint, 'asistio', p.recepcion_en,
      'Asistió a la presentación', ''::text,
      'funnel_prospectos', p.id::bigint
    from public.funnel_prospectos p
    where p.socio_id is not null and p.recepcion_en is not null

    union all
    select p.socio_id::bigint, 'baja_embudo', p.baja_en,
      'Baja del club', coalesce(p.motivo_baja, ''),
      'funnel_prospectos', p.id::bigint
    from public.funnel_prospectos p
    where p.socio_id is not null and p.baja_en is not null

    union all
    -- 3) Contratos firmados
    select c.socio_id::bigint, 'contrato', coalesce(c.firmado_en, c.creado_en),
      'Contrato firmado · ' || coalesce(c.tipo_membresia, '—')
        || ' $' || coalesce(c.monto::text, '0'),
      coalesce(c.plan_pago, ''),
      'funnel_contratos', c.id::bigint
    from public.funnel_contratos c
    where c.socio_id is not null

    union all
    -- 4) Interacciones del CRM. 'uso' se omite: ya entra como hito propio desde `usos`.
    select i.socio_id::bigint, 'interaccion', i.creado_en,
      coalesce(i.tipo, 'interaccion'), coalesce(i.nota, ''),
      'interacciones', i.id::bigint
    from public.interacciones i
    where i.socio_id is not null and coalesce(i.tipo, '') <> 'uso'

    union all
    -- 5) Canjes de beneficios
    select u.socio_id::bigint, 'canje', coalesce(u.usado_en, u.creado_en),
      'Canjeó beneficio' || case when u.codigo is not null then ' (' || u.codigo || ')' else '' end,
      coalesce(u.tipo, ''),
      'usos', u.id::bigint
    from public.usos u
    where u.socio_id is not null

    union all
    -- 6) Reservas
    select r.socio_id::bigint, 'reserva', r.creado_en,
      'Reserva: ' || coalesce(r.destino, 'destino')
        || case when r.personas is not null then ' · ' || r.personas || ' pers' else '' end,
      coalesce(r.estado, ''),
      'funnel_reservas', r.id::bigint
    from public.funnel_reservas r
    where r.socio_id is not null

    union all
    -- 7) Cambios de campo (Field Audit Trail, PR #35) — el rastro de "qué cambió y quién"
    select h.registro_id::bigint, 'cambio', h.cambiado_en,
      'Cambió ' || h.campo,
      coalesce(h.valor_anterior, '—') || ' → ' || coalesce(h.valor_nuevo, '—'),
      'socios_historial', h.id::bigint
    from public.socios_historial h
    where h.tabla = 'socios'
  )
  select cliente_id, evento_tipo, evento_en, titulo, detalle, fuente_tabla, fuente_id
  from eventos
  where cliente_id is not null
    and evento_en is not null
    and ((auth.jwt() -> 'app_metadata'::text) ->> 'role'::text)
      = any (array['admin'::text, 'gerente_general'::text, 'gerente_ventas'::text]);

comment on view public.cliente_hilo_conductor is
  'Hilo conductor único por cliente/familia (PENDIENTE c608e8bb): una fila por evento del recorrido completo de un socio — alta, hitos del embudo (lead/presentación/asistió/baja), contrato, interacción, canje, reserva y cambio de campo (socios_historial, PR #35). cliente_id = socios.id (mismo ancla que expedienteHTML). Vista SECURITY DEFINER con security_barrier=true; solo-lectura para admin/gerente_general/gerente_ventas (mismo criterio que socios_historial). Consultar: select * from public.cliente_hilo_conductor where cliente_id = <id> order by evento_en asc.';

-- GRANT mínimo — el rol se filtra DENTRO de la vista (arriba); acá solo abrimos
-- la puerta de PostgREST a `authenticated` y la cerramos explícita a `anon`.
grant select on public.cliente_hilo_conductor to authenticated;
revoke all on public.cliente_hilo_conductor from anon;

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN sugerida DESPUÉS de aplicar (prueba el guardián, no lo razones):
--
--   -- (a) La vista existe y trae columnas homogéneas:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='cliente_hilo_conductor';
--
--   -- (b) El hilo de un socio de prueba sale ORDENADO y sin huecos (comparar
--   --     contra lo que hoy arma expedienteHTML a mano para el mismo socio):
--   select evento_tipo, evento_en, titulo, detalle, fuente_tabla
--     from public.cliente_hilo_conductor
--    where cliente_id = <id_de_prueba>
--    order by evento_en asc;
--
--   -- (c) Un cambio de campo (PR #35) aparece como evento 'cambio' sin duplicar
--   --     ni perder el rastro:
--   --     UPDATE public.socios SET celular='00000000' WHERE id=<id_de_prueba>;
--   --     -- debe aparecer una fila evento_tipo='cambio', titulo='Cambió celular'.
--
--   -- (d) RLS: anon no ve nada (GET /rest/v1/cliente_hilo_conductor sin
--   --     Authorization -> [] o 401). Un rol NO autorizado (ej. telemarketing)
--   --     logueado tampoco (RLS por rol lo filtra -> []).
--   --
--   -- (e) admin/gerente_general/gerente_ventas logueados SÍ leen el hilo completo.
-- ─────────────────────────────────────────────────────────────────────────────
