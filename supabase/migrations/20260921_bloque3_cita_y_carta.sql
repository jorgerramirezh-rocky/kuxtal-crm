-- ============================================================================
-- BLOQUE 3 · la cita y la carta (18-sep-2026)
--
-- Qué cambia:
--  1. Lugares y horarios: cada restaurante con dirección y mapa, y sus horarios (día de
--     la semana, hora de Guatemala y cupo). Los configura quien tenga «gestionar_lugares».
--  2. El telemarketer cita SOLO en un horario configurado y con cupo (funnel_tmk_resultado).
--  3. La cita nace «por confirmar». Quien tenga «confirmar_citas» la confirma (puede
--     cambiar lugar/día/hora) o la regresa al telemarketer con un motivo. A Recepción solo
--     llegan las confirmadas. Si después cambia el lugar, la hora o el estado, la
--     confirmación se borra sola (disparador), por el camino que sea.
--  4. Al confirmar se anota si el cliente aceptó recibir la carta por WhatsApp y/o correo.
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. permisos nuevos en la matriz (George los reparte en la pestaña Roles) ──
insert into public.funnel_permisos(rol_clave, permiso, permitido)
select r.clave, p.permiso, r.clave in ('admin','gerente_general','gerente_tmk','supervisor_tmk')
  from public.funnel_roles r cross join (values ('confirmar_citas'), ('gestionar_lugares')) p(permiso)
on conflict do nothing;

-- ── 2. lugares ────────────────────────────────────────────────────────────
alter table public.funnel_restaurantes
  add column if not exists direccion text,
  add column if not exists mapa_url text;
alter table public.funnel_restaurantes drop constraint if exists funnel_restaurantes_mapa_ck;
alter table public.funnel_restaurantes add constraint funnel_restaurantes_mapa_ck
  check (mapa_url is null or mapa_url ~ '^https://[^\s<>"]+$');
alter table public.funnel_restaurantes drop constraint if exists funnel_restaurantes_largos_ck;
alter table public.funnel_restaurantes add constraint funnel_restaurantes_largos_ck
  check (char_length(nombre) between 1 and 120 and char_length(coalesce(direccion,'')) <= 300
         and char_length(coalesce(mapa_url,'')) <= 500);
drop policy if exists funnel_restaurantes_wr on public.funnel_restaurantes;
create policy funnel_restaurantes_wr on public.funnel_restaurantes to authenticated
  using (public.funnel_puede('gestionar_lugares')) with check (public.funnel_puede('gestionar_lugares'));
drop policy if exists funnel_restaurantes_sel on public.funnel_restaurantes;
create policy funnel_restaurantes_sel on public.funnel_restaurantes for select to authenticated
  using (public.funnel_es_staff());
revoke delete, truncate on public.funnel_restaurantes from anon, authenticated;
revoke all on public.funnel_restaurantes from anon;

-- ── 3. horarios ───────────────────────────────────────────────────────────
create table if not exists public.funnel_horarios (
  id bigint generated always as identity primary key,
  restaurante_id bigint not null references public.funnel_restaurantes(id),
  dia_semana smallint not null check (dia_semana between 0 and 6),   -- 0 = domingo (como extract(dow))
  hora time not null check (hora = date_trunc('minute', hora)),       -- hora de Guatemala
  cupo integer not null default 20 check (cupo between 1 and 500),
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  unique (restaurante_id, dia_semana, hora)
);
comment on table public.funnel_horarios is
  'Bloque 3: sesiones de presentación por lugar (día de la semana + hora de Guatemala + cupo).';
alter table public.funnel_horarios enable row level security;
drop policy if exists fhor_sel on public.funnel_horarios;
create policy fhor_sel on public.funnel_horarios for select to authenticated using (public.funnel_es_staff());
drop policy if exists fhor_ins on public.funnel_horarios;
create policy fhor_ins on public.funnel_horarios for insert to authenticated
  with check (public.funnel_puede('gestionar_lugares'));
drop policy if exists fhor_upd on public.funnel_horarios;
create policy fhor_upd on public.funnel_horarios for update to authenticated
  using (public.funnel_puede('gestionar_lugares')) with check (public.funnel_puede('gestionar_lugares'));
revoke all on public.funnel_horarios from public, anon, authenticated;
grant select, insert, update (cupo, activo) on public.funnel_horarios to authenticated;

-- ── 4. la cita confirmada ─────────────────────────────────────────────────
alter table public.funnel_prospectos
  add column if not exists cita_confirmada_en timestamptz,
  add column if not exists cita_confirmada_por text,
  add column if not exists carta_whatsapp boolean not null default false,
  add column if not exists carta_correo boolean not null default false;
comment on column public.funnel_prospectos.carta_whatsapp is
  'Bloque 3: el cliente aceptó (al confirmar la cita) recibir la carta por WhatsApp.';
comment on column public.funnel_prospectos.carta_correo is
  'Bloque 3: el cliente aceptó (al confirmar la cita) recibir la carta por correo.';

-- Si cambia el lugar, la hora o deja de estar citado, la confirmación (y el permiso de
-- mandarle la carta) se borran solos. Solo funnel_cita_confirmar la pone (marca de sesión).
create or replace function public.funnel_cita_guardia() returns trigger
  language plpgsql set search_path to 'public', 'pg_temp' as $$
declare v_confirmando boolean; v_err text;
begin
  -- Solo ESTE update puede poner la confirmación: el de funnel_cita_confirmar (marca de sesión
  -- + corre como el dueño de la función + cambia cita_confirmada_en). Cualquier otro update
  -- —aunque venga de otra función con la marca puesta— pasa por la limpieza (ronda 2 ciber).
  v_confirmando := current_setting('kux.confirmando', true) = 'si'
                   and current_user not in ('authenticated','anon')
                   and new.cita_confirmada_en is distinct from old.cita_confirmada_en;
  if not v_confirmando then
    -- nadie la pone «a mano»: se conserva lo de antes
    new.cita_confirmada_en := old.cita_confirmada_en; new.cita_confirmada_por := old.cita_confirmada_por;
    new.carta_whatsapp := old.carta_whatsapp; new.carta_correo := old.carta_correo;
    if new.presenta_en is distinct from old.presenta_en
       or new.restaurante_id is distinct from old.restaurante_id
       or (old.estado = 'asistira' and new.estado <> 'asistira') then
      new.cita_confirmada_en := null; new.cita_confirmada_por := null;
      new.carta_whatsapp := false; new.carta_correo := false;
    end if;
  end if;
  -- Una cita escrita DIRECTO en la tabla por una cuenta del equipo también respeta horario y cupo
  -- (las funciones ya lo validan antes; esto cierra el camino de la tabla).
  if current_user in ('authenticated','anon') and new.estado = 'asistira' and new.etapa = 'telemarketing'
     and (new.presenta_en is distinct from old.presenta_en or new.restaurante_id is distinct from old.restaurante_id
          or old.estado is distinct from 'asistira') then
    v_err := public.funnel_horario_problema(new.restaurante_id, new.presenta_en, new.id);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  -- El consentimiento es de ESE teléfono y ESE correo: si cambian, se pierde (siempre).
  if new.telefono is distinct from old.telefono then new.carta_whatsapp := false; end if;
  if new.email is distinct from old.email then new.carta_correo := false; end if;
  return new;
end $$;
drop trigger if exists trg_funnel_cita_guardia on public.funnel_prospectos;
create trigger trg_funnel_cita_guardia before update on public.funnel_prospectos
  for each row execute function public.funnel_cita_guardia();

-- Un alta con la cita ya confirmada tampoco se cuela.
create or replace function public.funnel_cita_guardia_alta() returns trigger
  language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  new.cita_confirmada_en := null; new.cita_confirmada_por := null;
  new.carta_whatsapp := false; new.carta_correo := false;
  return new;
end $$;
drop trigger if exists trg_funnel_cita_guardia_alta on public.funnel_prospectos;
create trigger trg_funnel_cita_guardia_alta before insert on public.funnel_prospectos
  for each row execute function public.funnel_cita_guardia_alta();

-- ¿Se puede citar ahí a esa hora? null = sí; si no, el motivo en español.
create or replace function public.funnel_horario_problema(p_rest bigint, p_cuando timestamptz, p_excluir bigint default null)
  returns text language plpgsql volatile security definer set search_path to 'public', 'pg_temp' as $$
declare v_local timestamp := p_cuando at time zone 'America/Guatemala'; v_cupo int; v_ocup int;
begin
  if p_rest is null or not exists (select 1 from public.funnel_restaurantes where id = p_rest and activo) then
    return 'elegí el restaurante';
  end if;
  if not exists (select 1 from public.funnel_horarios where restaurante_id = p_rest and activo) then
    return 'ese lugar todavía no tiene horarios: pedile al supervisor que los cargue';
  end if;
  -- FOR UPDATE: dos citas al mismo tiempo al último cupo esperan su turno (revisión ciber, S2).
  select cupo into v_cupo from public.funnel_horarios
   where restaurante_id = p_rest and activo
     and dia_semana = extract(dow from v_local)::int and hora = v_local::time
   for update;
  if v_cupo is null then return 'ese día y hora no es un horario del lugar'; end if;
  select count(*) into v_ocup from public.funnel_prospectos
   where restaurante_id = p_rest and presenta_en = p_cuando and estado = 'asistira'
     and etapa in ('telemarketing','presentacion') and id is distinct from p_excluir;
  if v_ocup >= v_cupo then return 'ese horario ya está lleno'; end if;
  return null;
end $$;
revoke all on function public.funnel_horario_problema(bigint, timestamptz, bigint) from public, anon, authenticated;
-- El disparador de la tabla corre como la cuenta del equipo y la necesita (solo devuelve un motivo).
grant execute on function public.funnel_horario_problema(bigint, timestamptz, bigint) to authenticated;

-- ── 5. el telemarketer cita solo en horarios con cupo ─────────────────────
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
  v_max int; v_int int; v_nuevo bigint; v_ya bigint[]; v_estado text; v_err text;
begin
  select * into p from public.funnel_prospectos where id = p_id for update;
  -- Quién puede: el agente dueño; un supervisor sobre su equipo; o quien ve todo.
  -- coalesce(…, false): con tmk_id NULL la condición daba NULL y el IF no frenaba (revisión
  -- adversaria, S1). Un prospecto sin dueño solo lo toca quien ve todo. Mismo mensaje exista o
  -- no el prospecto: no se revela qué ids existen.
  if not found or not coalesce(
       (yo is not null and p.tmk_id is not null and p.tmk_id = yo)
       or public.funnel_ve_todo()
       or (p.tmk_id is not null and not public.funnel_es_tmk()
           and p.tmk_id in (select public.funnel_ve_equipo())), false) then
    raise exception 'no autorizado';
  end if;
  if p.etapa <> 'telemarketing' then raise exception 'este prospecto ya no está en telemarketing'; end if;
  if p.recepcion_en is not null then raise exception 'este cliente ya llegó a la sala: lo ve Recepción'; end if;
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
           intentos_sin_respuesta = 0, recontacto_en = null,
           presenta_en = case when v_estado = 'interesado' then presenta_en end,
           restaurante_id = case when v_estado = 'interesado' then restaurante_id end,
           actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'reprogramar' then
    if p_cuando is null then raise exception 'poné el día y la hora para volver a llamar'; end if;
    if p_cuando < now() - interval '5 minutes' then raise exception 'esa fecha y hora ya pasó'; end if;
    if p_cuando > now() + interval '180 days' then raise exception 'la fecha queda muy lejos (máximo 6 meses)'; end if;
    v_estado := 'recontactar'; v_int := 0;
    update public.funnel_prospectos
       set estado = v_estado, recontacto_en = p_cuando, es_socio = coalesce(p_es_socio, es_socio),
           intentos_sin_respuesta = 0, presenta_en = null, restaurante_id = null, actualizado_en = now()
     where id = p.id;

  elsif p_resultado = 'citar' then
    if p_restaurante is null or not exists (select 1 from public.funnel_restaurantes r
                                             where r.id = p_restaurante and r.activo) then
      raise exception 'elegí el restaurante';
    end if;
    if p_cuando is null then raise exception 'poné el día y la hora de la presentación'; end if;
    if p_cuando < now() - interval '5 minutes' then raise exception 'esa fecha y hora ya pasó'; end if;
    if p_cuando > now() + interval '180 days' then raise exception 'la fecha queda muy lejos (máximo 6 meses)'; end if;
    -- Bloque 3: solo en un horario configurado del lugar y con cupo.
    v_err := public.funnel_horario_problema(p_restaurante, p_cuando, p.id);
    if v_err is not null then raise exception '%', v_err; end if;
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
      if p.tmk_id is not null then v_ya := v_ya || p.tmk_id; end if;
      -- Solo a quien tiene cuenta: un agente sin cuenta no puede abrir su lista y el lead se perdería.
      select a.id into v_nuevo from public.funnel_agentes a
       where a.activo and a.rol = 'tmk' and a.user_id is not null and a.id <> all(v_ya)
       order by random() limit 1;
      -- Si ya lo intentaron todos, a cualquiera que no sea el de ahora; si no hay otro, se queda.
      if v_nuevo is null then
        select a.id into v_nuevo from public.funnel_agentes a
         where a.activo and a.rol = 'tmk' and a.user_id is not null and a.id is distinct from p.tmk_id
         order by random() limit 1;
      end if;
      v_nuevo := coalesce(v_nuevo, p.tmk_id);
    end if;
    update public.funnel_prospectos
       set estado = v_estado, intentos_sin_respuesta = v_int, tmk_id = v_nuevo,
           recontacto_en = null, presenta_en = null, restaurante_id = null, actualizado_en = now()
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
  'Bloques 2 y 3: resultado de la llamada con las reglas de George; citar exige un horario configurado con cupo.';


-- ── 6. confirmar o regresar la cita ───────────────────────────────────────
create or replace function public.funnel_citas_lista()
  returns table(id bigint, nombre text, telefono text, email text, es_socio boolean, estado text,
                restaurante_id bigint, presenta_en timestamptz, cita_confirmada_en timestamptz,
                cita_confirmada_por text, carta_whatsapp boolean, carta_correo boolean,
                tmk_nombre text, comentario text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not public.funnel_puede('confirmar_citas') or public.funnel_es_tmk() then raise exception 'no autorizado'; end if;
  return query
  select p.id, p.nombre, p.telefono, p.email, p.es_socio, p.estado, p.restaurante_id, p.presenta_en,
         p.cita_confirmada_en, p.cita_confirmada_por, p.carta_whatsapp, p.carta_correo,
         a.nombre, p.comentario
    from public.funnel_prospectos p left join public.funnel_agentes a on a.id = p.tmk_id
   where p.estado = 'asistira' and p.etapa = 'telemarketing'
     and p.presenta_en >= now() - interval '1 day'
     and p.recepcion_en is null
     and (public.funnel_ve_todo() or (p.tmk_id is not null and p.tmk_id in (select public.funnel_ve_equipo())))
   order by (p.cita_confirmada_en is not null), p.presenta_en, p.id
   limit 500;
end $$;
revoke all on function public.funnel_citas_lista() from public, anon;
grant execute on function public.funnel_citas_lista() to authenticated;

create or replace function public.funnel_cita_confirmar(
  p_id bigint, p_restaurante bigint, p_cuando timestamptz, p_whatsapp boolean, p_correo boolean)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype; v_err text;
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if not public.funnel_puede('confirmar_citas') or public.funnel_es_tmk() then raise exception 'no autorizado'; end if;
  select * into p from public.funnel_prospectos where id = p_id for update;
  if not found or not coalesce((public.funnel_ve_todo() or (p.tmk_id is not null and p.tmk_id in (select public.funnel_ve_equipo()))), false) then raise exception 'no autorizado'; end if;
  if p.estado <> 'asistira' or p.etapa <> 'telemarketing' then
    raise exception 'esta cita ya no está pendiente';
  end if;
  if p.recepcion_en is not null then raise exception 'este cliente ya llegó a la sala: lo ve Recepción'; end if;
  if p_cuando is null then raise exception 'poné el día y la hora'; end if;
  if p_cuando < now() - interval '5 minutes' then raise exception 'esa fecha y hora ya pasó'; end if;
  if p_cuando > now() + interval '180 days' then raise exception 'la fecha queda muy lejos (máximo 6 meses)'; end if;
  v_err := public.funnel_horario_problema(p_restaurante, p_cuando, p.id);
  if v_err is not null then raise exception '%', v_err; end if;
  if coalesce(p_correo, false) and coalesce(btrim(p.email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'no tiene un correo válido: no se puede marcar la carta por correo';
  end if;
  perform set_config('kux.confirmando', 'si', true);
  update public.funnel_prospectos
     set restaurante_id = p_restaurante, presenta_en = p_cuando,
         cita_confirmada_en = now(), cita_confirmada_por = v_actor,
         carta_whatsapp = coalesce(p_whatsapp, false), carta_correo = coalesce(p_correo, false),
         actualizado_en = now()
   where id = p.id;
  perform set_config('kux.confirmando', '', true);
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, 'cita_confirmada', v_actor, jsonb_build_object('restaurante_id', p_restaurante, 'cuando', p_cuando,
          'carta_whatsapp', coalesce(p_whatsapp, false), 'carta_correo', coalesce(p_correo, false)));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_cita_confirmar(bigint, bigint, timestamptz, boolean, boolean) from public, anon;
grant execute on function public.funnel_cita_confirmar(bigint, bigint, timestamptz, boolean, boolean) to authenticated;

create or replace function public.funnel_cita_regresar(p_id bigint, p_motivo text)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype;
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if not public.funnel_puede('confirmar_citas') or public.funnel_es_tmk() then raise exception 'no autorizado'; end if;
  p_motivo := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
  if p_motivo is null then raise exception 'escribí el motivo para el telemarketer'; end if;
  select * into p from public.funnel_prospectos where id = p_id for update;
  if not found or not coalesce((public.funnel_ve_todo() or (p.tmk_id is not null and p.tmk_id in (select public.funnel_ve_equipo()))), false) then raise exception 'no autorizado'; end if;
  if p.estado <> 'asistira' or p.etapa <> 'telemarketing' then
    raise exception 'esta cita ya no está pendiente';
  end if;
  if p.recepcion_en is not null then raise exception 'este cliente ya llegó a la sala: lo ve Recepción'; end if;
  update public.funnel_prospectos
     set estado = 'interesado', presenta_en = null, restaurante_id = null,
         comentario = left('Cita regresada: ' || p_motivo, 500), actualizado_en = now()
   where id = p.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, 'cita_regresada', v_actor, jsonb_build_object('motivo', p_motivo, 'tmk_id', p.tmk_id));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_cita_regresar(bigint, text) from public, anon;
grant execute on function public.funnel_cita_regresar(bigint, text) to authenticated;

-- ── 7. la bitácora: los tipos nuevos también son solo de las funciones ────
drop policy if exists fev_ins on public.funnel_eventos;
create policy fev_ins on public.funnel_eventos for insert to authenticated with check (
  public.funnel_es_staff()
  and prospecto_id is not null
  and actor = (auth.jwt()->>'email')
  and (lower(btrim(tipo)) not in ('no_contesta','interesado','no_interesado','reprogramar','citar','nota',
                                  'asignado','cita_confirmada','cita_regresada')
       or (tipo = 'asignado' and public.funnel_es_gerente()))
  and case when public.funnel_es_tmk()
        then prospecto_id in (select l.id from public.funnel_tmk_mi_lista() l)
        else exists (select 1 from public.funnel_prospectos p where p.id = prospecto_id)
      end
);

commit;
