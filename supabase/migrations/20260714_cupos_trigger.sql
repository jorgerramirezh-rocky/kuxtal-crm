-- 20260714_cupos_trigger.sql — Tope de CUPOS y candado 1-uso del lado SERVIDOR.
-- Proyecto: KUXTAL (tevzfdiumfekvapamovw). NO auto-aplicada: George la corre tras su OK.
-- Aplicar con (una sola vez, en transacción):
--   psql "$KUXTAL_DB_URL" -1 -f supabase/migrations/20260714_cupos_trigger.sql
--   (o pegarla completa en el SQL Editor del dashboard de Supabase y ejecutar)
--
-- Por qué (revisión ola 2): el enforcement de cupos era check-then-act en el CLIENTE
-- (app.html cuenta usos y recién después inserta). Dos canjes simultáneos leen el
-- mismo conteo y ambos pasan → el cupo se excede. Igual el candado "1 uso por socio":
-- solo lo miraba la UI del socio, no la base.
--
-- Qué hace: trigger BEFORE INSERT en public.usos que, si el uso trae oferta_id:
--   1) SELECT ... FOR UPDATE sobre LA FILA de ofertas → serializa los canjes
--      concurrentes de la misma oferta (el segundo insert espera al commit del
--      primero y recién entonces cuenta; ofertas distintas no se bloquean entre sí).
--   2) Candado 1-uso: si ofertas.cupon_multi = false (o null) y ya existe un uso del
--      MISMO socio para esa oferta → RAISE EXCEPTION 'YA_USADO'.
--   3) Tope de cupos: si ofertas.cantidad no es null y count(usos de la oferta)
--      >= cantidad → RAISE EXCEPTION 'CUPOS_AGOTADOS'.
--
-- SECURITY DEFINER es necesario: el CRM inserta en usos como 'authenticated' y ese
-- rol NO puede (ni debe poder) hacer FOR UPDATE sobre ofertas ni leer usos ajenos;
-- la función corre como su dueño (postgres) con search_path fijado a public.
--
-- Qué mensaje llega a los clientes cuando el trigger rechaza (PostgREST devuelve
-- HTTP 400 con {"code":"P0001","message":"CUPOS_AGOTADOS"} o "YA_USADO"):
--   · Edge 'validar' (comercio vía validar.html): con el ajuste de este mismo PR
--     revisa la respuesta del insert, LIBERA el código (usado=false) y responde
--     {ok:false, reason:"cupos_agotados"|"ya_usado"}; validar.html no conoce esos
--     reasons y cae en su pantalla de error genérica ("No se pudo validar / Algo
--     salió mal") — legible, sin romper. Sumar textos bonitos queda para el lote
--     de UI.
--   · CRM app.html validarCodigo (NO se toca en este lote): hoy no revisa la
--     respuesta del POST a usos → si el trigger rechaza, el comercio ve "ok" pero
--     el uso NO queda registrado (la base nunca excede el cupo; el pre-chequeo del
--     cliente bloquea los canjes siguientes). El lote que tiene app.html debe
--     revisar r.ok del insert y mostrar "Cupos agotados"/"Ya usado".
--
-- Idempotente: create or replace + drop trigger if exists.
-- Columnas verificadas contra producción (SELECT de solo lectura, 14-jul-2026):
--   ofertas(id, cantidad int null, cupon_multi bool) · usos(socio_id, oferta_id null).

begin;

create or replace function public.usos_guarda_cupos()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_cantidad integer;
  v_multi boolean;
  v_count integer;
begin
  -- Usos sin oferta (registros históricos/manuales) no participan del tope.
  if new.oferta_id is null then
    return new;
  end if;

  -- Lock de la fila de la oferta: serializa el count→insert de canjes concurrentes.
  select o.cantidad, coalesce(o.cupon_multi, false)
    into v_cantidad, v_multi
    from public.ofertas o
   where o.id = new.oferta_id
     for update;

  -- Oferta inexistente (borrada): no bloquear el registro del uso histórico.
  if not found then
    return new;
  end if;

  -- Candado 1-uso por socio (servidor): cupón NO multi + ya hay un uso del socio.
  if not v_multi and new.socio_id is not null then
    if exists (
      select 1 from public.usos u
       where u.oferta_id = new.oferta_id
         and u.socio_id = new.socio_id
    ) then
      raise exception 'YA_USADO';
    end if;
  end if;

  -- Tope de cupos: mismo criterio de conteo que la UI (todos los usos de la oferta).
  if v_cantidad is not null then
    select count(*) into v_count
      from public.usos u
     where u.oferta_id = new.oferta_id;
    if v_count >= v_cantidad then
      raise exception 'CUPOS_AGOTADOS';
    end if;
  end if;

  return new;
end
$$;

-- Función de trigger: nadie la llama directo.
revoke all on function public.usos_guarda_cupos() from public;
revoke all on function public.usos_guarda_cupos() from anon;
revoke all on function public.usos_guarda_cupos() from authenticated;

drop trigger if exists trg_usos_cupos on public.usos;
create trigger trg_usos_cupos
  before insert on public.usos
  for each row
  execute function public.usos_guarda_cupos();

commit;
