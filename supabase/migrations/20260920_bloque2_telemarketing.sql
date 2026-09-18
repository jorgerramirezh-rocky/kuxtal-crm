-- ============================================================================
-- BLOQUE 2 · telemarketing — el flujo que dictó George (18-sep-2026)
--
-- Qué cambia:
--  1. El telemarketer ve SOLO nombre, teléfono y el resultado de su gestión.
--     Antes leía y editaba la fila entera de sus prospectos (31 columnas: correo,
--     edad, tarjetas, vendedor, cerrador…). Ahora un rol de agente «tmk» ya no toca
--     la tabla: lee su lista con funnel_tmk_mi_lista() y anota con
--     funnel_tmk_resultado(). Cerrado en la base, no solo en la pantalla.
--  2. Resultado de la llamada, con reglas en el servidor:
--       contestó      → interesado / no interesado (+ socio / no socio)
--       no contestó   → pasa a OTRO telemarketer, al azar entre los que todavía
--                       no lo intentaron; al tope de intentos queda «no contactable»
--       reprogramar   → fecha y hora; se queda con el MISMO telemarketer
--       citar         → restaurante + día y hora (la confirma el supervisor, bloque 3)
--  3. El tope de intentos es un parámetro (3), que gerencia puede bajar a 2.
--  4. El reparto de una base nueva es parejo pero al AZAR (antes, en orden de id).
--
-- Todo en una transacción. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. columnas y estado nuevo ─────────────────────────────────────────────
alter table public.funnel_prospectos
  add column if not exists intentos_sin_respuesta integer not null default 0,
  add column if not exists es_socio boolean;
alter table public.funnel_prospectos drop constraint if exists funnel_prospectos_intentos_ck;
alter table public.funnel_prospectos add constraint funnel_prospectos_intentos_ck
  check (intentos_sin_respuesta >= 0);
comment on column public.funnel_prospectos.intentos_sin_respuesta is
  'Llamadas seguidas sin contestar (cada una por un telemarketer distinto). Vuelve a 0 cuando contesta.';
comment on column public.funnel_prospectos.es_socio is
  'Lo que dijo el cliente al contestar: ya es socio de Kuxtal (true) o no (false). Null = no se sabe.';

insert into public.funnel_estados(clave, etiqueta, color, orden, cuenta_como, dispara_recontacto, activo)
values ('no_contactable', 'No contactable', '#8a94a6', 75, 'descartado', false, true)
on conflict (clave) do nothing;

-- ── 2. parámetros de la operación ──────────────────────────────────────────
create table if not exists public.funnel_parametros (
  clave text primary key,
  valor integer not null,
  descripcion text,
  actualizado_en timestamptz not null default now(),
  constraint funnel_parametros_intentos_ck
    check (clave <> 'tmk_intentos_max' or valor between 2 and 5)
);
comment on table public.funnel_parametros is
  'Números de la operación que gerencia ajusta sin tocar código (bloque 2).';
alter table public.funnel_parametros enable row level security;
drop policy if exists fpar_sel on public.funnel_parametros;
create policy fpar_sel on public.funnel_parametros for select to authenticated
  using (public.funnel_es_staff());
drop policy if exists fpar_upd on public.funnel_parametros;
create policy fpar_upd on public.funnel_parametros for update to authenticated
  using (public.funnel_es_gerente()) with check (public.funnel_es_gerente());
revoke all on public.funnel_parametros from public, anon, authenticated;
grant select, update (valor, actualizado_en) on public.funnel_parametros to authenticated;
insert into public.funnel_parametros(clave, valor, descripcion)
values ('tmk_intentos_max', 3, 'Llamadas sin contestar antes de marcar «no contactable» (2 a 5).')
on conflict (clave) do nothing;

-- ── 3. quién es telemarketer ───────────────────────────────────────────────
-- Por el rol de la CUENTA (el que manda desde el bloque 1): todo rol cuyo agente es «tmk».
-- A propósito no mira «activo»: un rol apagado no debe caer al camino de supervisor.
create or replace function public.funnel_es_tmk() returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (select 1 from public.funnel_roles
                  where clave = public.funnel_rol() and rol_operativo = 'tmk')
$$;
revoke all on function public.funnel_es_tmk() from public, anon;
grant execute on function public.funnel_es_tmk() to authenticated, service_role;

-- ── 4. el telemarketer ya no lee ni edita la tabla directo ─────────────────
drop policy if exists fp_sel on public.funnel_prospectos;
create policy fp_sel on public.funnel_prospectos for select to authenticated using (
  public.funnel_ve_todo()
  or (not public.funnel_es_tmk() and tmk_id in (select public.funnel_ve_equipo()))
);
drop policy if exists fp_upd on public.funnel_prospectos;
create policy fp_upd on public.funnel_prospectos for update to authenticated using (
  public.funnel_ve_todo()
  or (not public.funnel_es_tmk() and tmk_id in (select public.funnel_ve_equipo()))
) with check (
  public.funnel_ve_todo()
  or (not public.funnel_es_tmk() and tmk_id in (select public.funnel_ve_equipo()))
);

-- ── 5. la lista del telemarketer: lo mínimo ────────────────────────────────
create or replace function public.funnel_tmk_mi_lista()
  returns table(id bigint, nombre text, telefono text, estado text, recontacto_en timestamptz,
                intentos integer, es_socio boolean, restaurante_id bigint,
                presenta_en timestamptz, comentario text)
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select p.id, p.nombre, p.telefono, p.estado, p.recontacto_en, p.intentos_sin_respuesta,
         p.es_socio, p.restaurante_id, p.presenta_en, p.comentario
    from public.funnel_prospectos p
   where public.funnel_mi_agente() is not null
     and p.tmk_id = public.funnel_mi_agente()
     and p.etapa = 'telemarketing'
     and p.estado <> 'no_contactable'
   order by p.recontacto_en asc nulls last, p.id asc
$$;
revoke all on function public.funnel_tmk_mi_lista() from public, anon;
grant execute on function public.funnel_tmk_mi_lista() to authenticated;
comment on function public.funnel_tmk_mi_lista() is
  'Bloque 2: la lista del día del agente que llama (por cuenta). Solo nombre, teléfono y lo de su gestión.';

-- ── 6. anotar el resultado de la llamada ───────────────────────────────────
create or replace function public.funnel_tmk_resultado(
  p_id bigint, p_resultado text, p_es_socio boolean default null,
  p_cuando timestamptz default null, p_restaurante bigint default null,
  p_comentario text default null)
  returns jsonb
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  p public.funnel_prospectos%rowtype;
  yo bigint := public.funnel_mi_agente();
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
  v_max int; v_int int; v_nuevo bigint; v_ya bigint[]; v_estado text;
begin
  select * into p from public.funnel_prospectos where id = p_id for update;
  if not found then raise exception 'no existe el prospecto'; end if;
  -- Quién puede: el agente dueño; un supervisor sobre su equipo; o quien ve todo.
  if not ((yo is not null and p.tmk_id = yo)
          or public.funnel_ve_todo()
          or (not public.funnel_es_tmk() and p.tmk_id in (select public.funnel_ve_equipo()))) then
    raise exception 'no autorizado';
  end if;
  if p.etapa <> 'telemarketing' then raise exception 'este prospecto ya no está en telemarketing'; end if;
  if p.estado = 'no_contactable' and not public.funnel_ve_todo() then
    raise exception 'este prospecto ya quedó como no contactable';
  end if;
  p_comentario := nullif(left(btrim(coalesce(p_comentario, '')), 500), '');
  v_int := p.intentos_sin_respuesta;
  v_nuevo := p.tmk_id;

  if p_resultado in ('interesado', 'no_interesado') then
    v_estado := p_resultado; v_int := 0;
    update public.funnel_prospectos
       set estado = v_estado, es_socio = coalesce(p_es_socio, es_socio),
           intentos_sin_respuesta = 0, recontacto_en = null, actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'reprogramar' then
    if p_cuando is null then raise exception 'poné el día y la hora para volver a llamar'; end if;
    if p_cuando < now() - interval '5 minutes' then raise exception 'esa fecha y hora ya pasó'; end if;
    if p_cuando > now() + interval '180 days' then raise exception 'la fecha queda muy lejos (máximo 6 meses)'; end if;
    v_estado := 'recontactar'; v_int := 0;
    update public.funnel_prospectos
       set estado = v_estado, recontacto_en = p_cuando, es_socio = coalesce(p_es_socio, es_socio),
           intentos_sin_respuesta = 0, actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'citar' then
    if p_restaurante is null or not exists (select 1 from public.funnel_restaurantes r
                                             where r.id = p_restaurante and r.activo) then
      raise exception 'elegí el restaurante';
    end if;
    if p_cuando is null then raise exception 'poné el día y la hora de la presentación'; end if;
    if p_cuando < now() - interval '1 hour' then raise exception 'esa fecha y hora ya pasó'; end if;
    if p_cuando > now() + interval '180 days' then raise exception 'la fecha queda muy lejos (máximo 6 meses)'; end if;
    v_estado := 'asistira'; v_int := 0;
    update public.funnel_prospectos
       set estado = v_estado, restaurante_id = p_restaurante, presenta_en = p_cuando,
           es_socio = coalesce(p_es_socio, es_socio), intentos_sin_respuesta = 0,
           recontacto_en = null, actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'no_contesta' then
    select valor into v_max from public.funnel_parametros where clave = 'tmk_intentos_max';
    v_max := coalesce(v_max, 3);
    v_int := p.intentos_sin_respuesta + 1;
    if v_int >= v_max then
      v_estado := 'no_contactable';
    else
      v_estado := 'no_contesta';
      -- Los que ya lo intentaron salen de la bitácora (y el de ahora).
      select coalesce(array_agg(distinct (e.payload->>'tmk_id')::bigint), '{}')
        into v_ya
        from public.funnel_eventos e
       where e.prospecto_id = p.id and e.tipo = 'no_contesta'
         and (e.payload->>'tmk_id') ~ '^[0-9]+$';
      v_ya := v_ya || p.tmk_id;
      select a.id into v_nuevo from public.funnel_agentes a
       where a.activo and a.rol = 'tmk' and a.id <> all(v_ya)
       order by random() limit 1;
      -- Si ya lo intentaron todos, a cualquiera que no sea el de ahora; si no hay otro, se queda.
      if v_nuevo is null then
        select a.id into v_nuevo from public.funnel_agentes a
         where a.activo and a.rol = 'tmk' and a.id is distinct from p.tmk_id
         order by random() limit 1;
      end if;
      v_nuevo := coalesce(v_nuevo, p.tmk_id);
    end if;
    update public.funnel_prospectos
       set estado = v_estado, intentos_sin_respuesta = v_int, tmk_id = v_nuevo,
           recontacto_en = null, actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'nota' then
    if p_comentario is null then raise exception 'la nota está vacía'; end if;
    v_estado := p.estado;

  else
    raise exception 'resultado desconocido';
  end if;

  if p_comentario is not null then
    update public.funnel_prospectos set comentario = p_comentario, actualizado_en = now() where id = p.id;
  end if;

  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, p_resultado, v_actor, jsonb_strip_nulls(jsonb_build_object(
    'tmk_id', p.tmk_id, 'pasa_a', case when v_nuevo is distinct from p.tmk_id then v_nuevo end,
    'intento', case when p_resultado = 'no_contesta' then v_int end,
    'es_socio', p_es_socio, 'cuando', p_cuando, 'restaurante_id', p_restaurante,
    'nota', p_comentario)));

  return jsonb_build_object('estado', v_estado, 'intentos', v_int,
                            'sigue_conmigo', v_nuevo is not distinct from p.tmk_id);
end $$;
revoke all on function public.funnel_tmk_resultado(bigint, text, boolean, timestamptz, bigint, text) from public, anon;
grant execute on function public.funnel_tmk_resultado(bigint, text, boolean, timestamptz, bigint, text) to authenticated;
comment on function public.funnel_tmk_resultado(bigint, text, boolean, timestamptz, bigint, text) is
  'Bloque 2: resultado de la llamada (interesado, no_interesado, reprogramar, citar, no_contesta, nota) con las reglas de George.';

-- ── 7. reparto parejo, pero al azar ────────────────────────────────────────
create or replace function public.funnel_repartir(p_base bigint) returns integer
  language plpgsql security definer set search_path to 'public' as $$
declare ags bigint[]; n int; idx int := 0; cnt int := 0; r record;
begin
  if not funnel_es_gerente() then raise exception 'solo un gerente puede repartir'; end if;
  -- agentes activos tmk expandidos por su PESO, en orden al azar
  select array_agg(a.id order by random()) into ags from (
    select ag.id, generate_series(1, greatest(ag.peso,1)) from funnel_agentes ag
    where ag.activo and ag.rol='tmk'
  ) a;
  if ags is null then raise exception 'no hay TMK activos'; end if;
  n := array_length(ags,1);
  perform 1 from funnel_reparto where id=1 for update;
  -- los prospectos también en orden al azar: parejo en cantidad, sin patrón en quién le toca a quién
  for r in select id from funnel_prospectos where base_id=p_base and tmk_id is null order by random() for update loop
    idx := (idx % n) + 1;
    update funnel_prospectos set tmk_id = ags[idx], actualizado_en=now() where id = r.id;
    insert into funnel_eventos(prospecto_id,tipo,actor,payload) values (r.id,'asignado','sistema',jsonb_build_object('agente_id',ags[idx]));
    cnt := cnt + 1;
  end loop;
  if idx > 0 then update funnel_reparto set ultimo_agente_id = ags[idx] where id=1; end if;
  return cnt;
end $$;

commit;
