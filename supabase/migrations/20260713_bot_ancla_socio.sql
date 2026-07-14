-- 20260713_bot_ancla_socio.sql — Ancla las conversaciones y reservas del bot al socio real.
-- Proyecto: KUXTAL (tevzfdiumfekvapamovw). NO auto-aplicada: George la corre tras su OK.
-- Aplicar con (una sola vez, en transacción):
--   psql "$KUXTAL_DB_URL" -1 -f supabase/migrations/20260713_bot_ancla_socio.sql
--   (o pegarla completa en el SQL Editor del dashboard de Supabase y ejecutar)
--
-- Qué hace:
--   (a) kuxtal_bot_conversaciones.socio_id → FK a socios(id): la conversación queda
--       anclada al socio cuando el cliente se identifica con su DPI.
--   (b) funnel_reservar_cliente gana el parámetro OPCIONAL p_socio_id (default null)
--       y resuelve/escribe socio_id en funnel_reservas. La reserva sigue naciendo
--       como 'solicitada' (columna estado ya existe con ese default) — es una
--       SOLICITUD que el equipo confirma, no una reserva confirmada.
--       ⚠️ Cambia la lista de parámetros → hay que DROP + CREATE (un CREATE OR
--       REPLACE crearía una SEGUNDA función sobrecargada y PostgREST no sabría
--       cuál elegir). Se restauran los grants exactos leídos de producción el
--       13-jul-2026: EXECUTE solo para service_role (revocado a PUBLIC/anon/authenticated).
--   (c) Backfill de funnel_reservas.socio_id para las reservas viejas del bot:
--       match determinista por nombre exacto (case-insensitive) o por No. de socio
--       exacto contra socio_nombre. Idempotente (solo toca filas con socio_id null).
--       Verificado con SELECTs de solo lectura el 13-jul-2026: matchea exactamente
--       1 de las 3 reservas históricas; las otras 2 no corresponden a ningún socio
--       del padrón y quedan con socio_id null a propósito.
--   (d) Backfill de kuxtal_bot_conversaciones.lead_id desde leads por chat_id
--       (leads.chat_id es único; verificado: ancla 1 conversación real, las
--       conversaciones QA sin lead quedan null).

begin;

-- (a) Ancla conversación → socio.
alter table public.kuxtal_bot_conversaciones
  add column if not exists socio_id bigint references public.socios(id);

-- (b) RPC con p_socio_id opcional. DROP + CREATE porque cambia la firma.
--     El bot v8 desplegado llama SIN p_socio_id → sigue funcionando (default null).
--     Se dropean AMBAS firmas (la vieja de 7 params y la nueva de 8) para que la
--     migración sea re-ejecutable sin error si ya se aplicó una vez.
drop function if exists public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text);
drop function if exists public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text, bigint);

create function public.funnel_reservar_cliente(
  p_socio text,
  p_destino text,
  p_fecha date,
  p_personas integer,
  p_notas text default null::text,
  p_prospecto bigint default null::bigint,
  p_fuente text default null::text,
  p_socio_id bigint default null::bigint
)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id bigint; v_pros bigint; v_cnt int; v_clave text; v_socio_id bigint;
begin
  -- Antes: el chequeo completo estaba dentro de "if p_fuente is not null" → omitir
  -- p_fuente desactivaba el límite. Ahora corre SIEMPRE; sin fuente cae en un cupo
  -- compartido chico ('sin-fuente'), no en cero límite.
  v_clave := coalesce(p_fuente, 'sin-fuente');
  -- Lock por fuente: cierra el TOCTOU count→insert (dos llamadas concurrentes del
  -- mismo chat ya no pueden colar una 6ta reserva viendo ambas v_cnt=4).
  perform pg_advisory_xact_lock(hashtext('reserva:' || v_clave));
  select count(*) into v_cnt from funnel_reservas
    where notas like ('%chat:' || v_clave || '%') and creado_en > now() - interval '24 hours';
  if v_cnt >= 5 then raise exception 'limite de reservas por hoy alcanzado'; end if;

  p_socio := left(coalesce(p_socio, ''), 80);
  p_destino := left(coalesce(p_destino, ''), 80);
  p_notas := left(coalesce(p_notas, ''), 200);
  select id into v_pros from funnel_prospectos
    where etapa = 'socio' and (id = p_prospecto or lower(nombre) = lower(p_socio)) limit 1;

  -- Ancla al socio real: p_socio_id (viene de la conversación anclada por DPI) o,
  -- si no vino, lookup interno por nombre exacto / No. de socio. Es resolución
  -- SERVIDOR-adentro: nada de esto se divulga al chat (candado de privacidad intacto).
  -- Solo ancla si el match es ÚNICO: hay homónimos en el padrón y un limit 1 sin
  -- order by anclaría a un socio ARBITRARIO (peor que dejar null para revisión humana).
  v_socio_id := p_socio_id;
  if v_socio_id is null then
    select min(id) into v_socio_id from socios
      where lower(nombre) = lower(p_socio) or no_socio = trim(p_socio)
      having count(distinct id) = 1;
  end if;

  -- La reserva nace como SOLICITUD ('solicitada'): el equipo la confirma después.
  insert into funnel_reservas(prospecto_id, socio_id, socio_nombre, destino, fecha_viaje, personas, estado, notas)
    values (coalesce(p_prospecto, v_pros), v_socio_id, p_socio, p_destino, p_fecha,
            greatest(coalesce(p_personas, 1), 1), 'solicitada',
            trim(p_notas || ' chat:' || v_clave))
    returning id into v_id;
  return v_id;
end
$function$;

-- Grants idénticos a los de producción (leídos el 13-jul): solo service_role ejecuta.
revoke all on function public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text, bigint) from public;
revoke all on function public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text, bigint) from anon;
revoke all on function public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text, bigint) from authenticated;
grant execute on function public.funnel_reservar_cliente(text, text, date, integer, text, bigint, text, bigint) to service_role;

-- (c) Backfill de reservas viejas del bot: mismo criterio que el RPC (nombre exacto
--     o No. de socio exacto), y SOLO si el match es único (mismo candado anti-homónimos
--     que el RPC: un UPDATE...FROM con 2+ matches anclaría a un socio arbitrario).
--     Idempotente; matches verificados con SELECTs antes de versionar esta migración.
update public.funnel_reservas r
   set socio_id = m.socio_id
  from (
    select r2.id as reserva_id, min(s.id) as socio_id
      from public.funnel_reservas r2
      join public.socios s
        on (lower(s.nombre) = lower(trim(r2.socio_nombre)) or s.no_socio = trim(r2.socio_nombre))
     where r2.socio_id is null
     group by r2.id
    having count(distinct s.id) = 1
  ) m
 where r.id = m.reserva_id;

-- (d) Backfill lead_id de conversaciones desde leads por chat_id (leads.chat_id es único).
update public.kuxtal_bot_conversaciones c
   set lead_id = l.id
  from public.leads l
 where l.chat_id = c.chat_id
   and c.lead_id is null;

commit;
