-- ============================================================================
-- BLOQUE 4 · la sala de ventas: hostess, liner y closer por turno (19-sep-2026)
--
-- Qué cambia:
--  1. Turno del día: quien tenga «armar_turnos» anota qué hostess, liners y closers
--     trabajan cada día y en qué lugar (la sala = el restaurante de la cita).
--  2. La hostess ve SOLO las citas confirmadas de HOY en el lugar donde tiene turno
--     (funnel_sala_hoy). Sale de funnel_ve_todo: ya no lee ni escribe la tabla directo.
--  3. Llegada y calificación por funciones. Al calificar, la RUEDA asigna el liner que
--     sigue (menos clientes hoy; empate: el que lleva más rato sin recibir). «Pasar a
--     closer» asigna el closer que sigue, igual. Candado por lugar y rol: dos llegadas al
--     mismo segundo nunca le caen al mismo.
--  4. Cambio a mano: quien atiende la sala reasigna a otro que esté en turno; queda
--     anotado quién y cómo (funnel_sala_asignaciones, que nadie escribe directo).
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. permisos nuevos en la matriz (George los reparte en la pestaña Roles) ──
insert into public.funnel_permisos(rol_clave, permiso, permitido)
select r.clave, p.permiso,
       case p.permiso
         when 'armar_turnos' then r.clave in ('admin','gerente_general','gerente_ventas','supervisor')
         else r.clave in ('admin','gerente_general','gerente_ventas','supervisor','recepcion') end
  from public.funnel_roles r cross join (values ('armar_turnos'), ('recibir_sala')) p(permiso)
on conflict do nothing;

-- La hostess trabaja como agente (para poder estar en un turno).
update public.funnel_roles set rol_operativo = 'recepcion'
 where clave = 'recepcion' and rol_operativo is null;

-- ── 2. la hostess sale de «ve todo» ───────────────────────────────────────
create or replace function public.funnel_ve_todo() returns boolean
  language sql stable as $$
  select funnel_es_gerente() or funnel_rol() = any(array['vendedor','cerrador','reservaciones','servicio','digitador','verificador'])
$$;

create or replace function public.funnel_hoy_gt() returns date
  language sql stable as $$ select (now() at time zone 'America/Guatemala')::date $$;

-- ── 3. turnos ─────────────────────────────────────────────────────────────
create table if not exists public.funnel_turnos (
  id bigint generated always as identity primary key,
  fecha date not null,
  restaurante_id bigint not null references public.funnel_restaurantes(id),
  agente_id bigint not null references public.funnel_agentes(id),
  disponible boolean not null default true,
  creado_por text,
  creado_en timestamptz not null default now(),
  unique (fecha, agente_id)            -- una persona, un lugar por día
);
comment on table public.funnel_turnos is
  'Bloque 4: quién trabaja cada día en qué sala (hostess, liner, closer). Se escribe solo por funciones.';
alter table public.funnel_turnos enable row level security;
revoke all on public.funnel_turnos from public, anon, authenticated;

create table if not exists public.funnel_sala_asignaciones (
  id bigint generated always as identity primary key,
  prospecto_id bigint not null references public.funnel_prospectos(id) on delete cascade,
  rol text not null check (rol in ('vendedor','cerrador')),
  agente_id bigint not null references public.funnel_agentes(id),
  modo text not null check (modo in ('rueda','manual')),
  antes bigint,
  actor text,
  creado_en timestamptz not null default now()
);
comment on table public.funnel_sala_asignaciones is
  'Bloque 4: cada asignación de liner/closer en la sala. La rueda cuenta de acá. Se escribe solo por funciones.';
create index if not exists ix_fsa_agente on public.funnel_sala_asignaciones(agente_id, creado_en);
alter table public.funnel_sala_asignaciones enable row level security;
revoke all on public.funnel_sala_asignaciones from public, anon, authenticated;

-- ¿En qué lugares atiende la sala quien llama, HOY?
create or replace function public.funnel_sala_mis_lugares() returns setof bigint
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() then return; end if;
  if public.funnel_puede('armar_turnos') or (public.funnel_puede('recibir_sala') and public.funnel_es_gerente()) then
    return query select r.id from public.funnel_restaurantes r;
  elsif public.funnel_puede('recibir_sala') then
    return query select t.restaurante_id from public.funnel_turnos t
      join public.funnel_agentes a on a.id = t.agente_id and a.activo and a.rol = 'recepcion'
     where t.fecha = public.funnel_hoy_gt() and a.id = public.funnel_mi_agente();
  end if;
end $$;
revoke all on function public.funnel_sala_mis_lugares() from public, anon;
grant execute on function public.funnel_sala_mis_lugares() to authenticated;

create or replace function public.funnel_turnos_dia(p_fecha date default null)
  returns table(id bigint, fecha date, restaurante_id bigint, agente_id bigint, nombre text, rol text,
                disponible boolean, clientes_hoy int)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_f date := coalesce(p_fecha, public.funnel_hoy_gt());
begin
  if not (public.funnel_puede('armar_turnos') or (v_f = public.funnel_hoy_gt() and public.funnel_puede('recibir_sala')))
     or public.funnel_es_tmk() then
    raise exception 'no autorizado';
  end if;
  return query
  select t.id, t.fecha, t.restaurante_id, t.agente_id, a.nombre, a.rol, t.disponible,
         (select count(*)::int from public.funnel_sala_asignaciones s
           where s.agente_id = t.agente_id and (s.creado_en at time zone 'America/Guatemala')::date = t.fecha)
    from public.funnel_turnos t join public.funnel_agentes a on a.id = t.agente_id
   where t.fecha = v_f
     and (public.funnel_puede('armar_turnos') or t.restaurante_id in (select public.funnel_sala_mis_lugares()))
   order by t.restaurante_id, a.rol, a.nombre;
end $$;
revoke all on function public.funnel_turnos_dia(date) from public, anon;
grant execute on function public.funnel_turnos_dia(date) to authenticated;

create or replace function public.funnel_turno_poner(p_fecha date, p_rest bigint, p_agente bigint)
  returns bigint language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_id bigint; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if not public.funnel_puede('armar_turnos') or public.funnel_es_tmk() then raise exception 'no autorizado'; end if;
  if p_fecha is null or p_fecha < public.funnel_hoy_gt() then raise exception 'esa fecha ya pasó'; end if;
  if p_fecha > public.funnel_hoy_gt() + 60 then raise exception 'la fecha queda muy lejos (máximo 60 días)'; end if;
  if not exists (select 1 from public.funnel_restaurantes where id = p_rest and activo) then
    raise exception 'elegí el lugar';
  end if;
  if not exists (select 1 from public.funnel_agentes where id = p_agente and activo
                  and rol in ('recepcion','vendedor','cerrador')) then
    raise exception 'esa persona no es hostess, liner ni closer activo';
  end if;
  insert into public.funnel_turnos(fecha, restaurante_id, agente_id, creado_por)
  values (p_fecha, p_rest, p_agente, v_actor)
  on conflict (fecha, agente_id) do update set restaurante_id = excluded.restaurante_id, disponible = true,
     creado_por = excluded.creado_por, creado_en = now()
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.funnel_turno_poner(date, bigint, bigint) from public, anon;
grant execute on function public.funnel_turno_poner(date, bigint, bigint) to authenticated;

create or replace function public.funnel_turno_quitar(p_id bigint)
  returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not public.funnel_puede('armar_turnos') or public.funnel_es_tmk() then raise exception 'no autorizado'; end if;
  delete from public.funnel_turnos where id = p_id and fecha >= public.funnel_hoy_gt();
  if not found then raise exception 'ese turno no existe o ya pasó'; end if;
end $$;
revoke all on function public.funnel_turno_quitar(bigint) from public, anon;
grant execute on function public.funnel_turno_quitar(bigint) to authenticated;

-- «Salió a comer»: la rueda lo salta mientras no esté disponible.
create or replace function public.funnel_turno_disponible(p_id bigint, p_disponible boolean)
  returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare t public.funnel_turnos%rowtype;
begin
  select * into t from public.funnel_turnos where id = p_id for update;
  if not found or public.funnel_es_tmk() or not (public.funnel_puede('armar_turnos')
       or (t.fecha = public.funnel_hoy_gt() and t.restaurante_id in (select public.funnel_sala_mis_lugares()))) then
    raise exception 'no autorizado';
  end if;
  if t.fecha < public.funnel_hoy_gt() then raise exception 'ese turno ya pasó'; end if;
  update public.funnel_turnos set disponible = coalesce(p_disponible, true) where id = p_id;
end $$;
revoke all on function public.funnel_turno_disponible(bigint, boolean) from public, anon;
grant execute on function public.funnel_turno_disponible(bigint, boolean) to authenticated;

-- ── 4. la sala de hoy ─────────────────────────────────────────────────────
create or replace function public.funnel_sala_hoy()
  returns table(id bigint, nombre text, telefono text, restaurante_id bigint, presenta_en timestamptz,
                recepcion_en timestamptz, etapa text, califica boolean, edad int, estado_civil text,
                tarjetas_credito int, tipo_tarjetas text, motivo_no text,
                vendedor_id bigint, vendedor text, cerrador_id bigint, cerrador text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() or not public.funnel_puede('recibir_sala') and not public.funnel_puede('armar_turnos') then
    raise exception 'no autorizado';
  end if;
  return query
  select p.id, p.nombre, p.telefono, p.restaurante_id, p.presenta_en, p.recepcion_en, p.etapa, p.califica,
         p.edad::int, p.estado_civil, p.tarjetas_credito::int, p.tipo_tarjetas, p.motivo_no,
         p.vendedor_id, v.nombre, p.cerrador_id, c.nombre
    from public.funnel_prospectos p
    left join public.funnel_agentes v on v.id = p.vendedor_id
    left join public.funnel_agentes c on c.id = p.cerrador_id
   where p.restaurante_id in (select public.funnel_sala_mis_lugares())
     and p.estado = 'asistira' and p.cita_confirmada_en is not null
     and (p.presenta_en at time zone 'America/Guatemala')::date = public.funnel_hoy_gt()
     and (p.etapa in ('telemarketing','presentacion') or (p.etapa = 'sala' and p.califica))
   order by p.presenta_en, p.id
   limit 500;
end $$;
revoke all on function public.funnel_sala_hoy() from public, anon;
grant execute on function public.funnel_sala_hoy() to authenticated;

-- El prospecto de hoy en una sala que atiendo, bloqueado para escribir. Si no, 'no autorizado'.
create or replace function public.funnel_sala_tomar(p_id bigint)
  returns public.funnel_prospectos language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype;
begin
  if public.funnel_es_tmk() or not (public.funnel_puede('recibir_sala') or public.funnel_puede('armar_turnos')) then
    raise exception 'no autorizado';
  end if;
  select * into p from public.funnel_prospectos where id = p_id for update;
  if not found or p.restaurante_id is null or p.restaurante_id not in (select public.funnel_sala_mis_lugares())
     or p.estado <> 'asistira' or p.cita_confirmada_en is null
     or (p.presenta_en at time zone 'America/Guatemala')::date <> public.funnel_hoy_gt() then
    raise exception 'no autorizado';
  end if;
  return p;
end $$;
revoke all on function public.funnel_sala_tomar(bigint) from public, anon, authenticated;

-- La rueda: el siguiente en turno HOY en ese lugar, con candado por lugar y rol.
create or replace function public.funnel_sala_rueda(p_rest bigint, p_rol text, p_excluir bigint default null)
  returns bigint language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_id bigint; v_hoy date := public.funnel_hoy_gt();
begin
  perform pg_advisory_xact_lock(hashtext('kux.sala.rueda'), hashtext(p_rest::text || ':' || p_rol));
  select t.agente_id into v_id
    from public.funnel_turnos t
    join public.funnel_agentes a on a.id = t.agente_id and a.activo and a.rol = p_rol
   where t.fecha = v_hoy and t.restaurante_id = p_rest and t.disponible
     and t.agente_id is distinct from p_excluir
   order by (select count(*) from public.funnel_sala_asignaciones s
              where s.agente_id = t.agente_id and s.rol = p_rol
                and (s.creado_en at time zone 'America/Guatemala')::date = v_hoy),
            (select max(s.creado_en) from public.funnel_sala_asignaciones s
              where s.agente_id = t.agente_id and s.rol = p_rol) nulls first,
            t.id
   limit 1;
  return v_id;
end $$;
revoke all on function public.funnel_sala_rueda(bigint, text, bigint) from public, anon, authenticated;

create or replace function public.funnel_sala_llegada(p_id bigint)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  p := public.funnel_sala_tomar(p_id);
  if p.etapa not in ('telemarketing','presentacion') then raise exception 'este cliente ya pasó a la sala'; end if;
  if p.recepcion_en is not null then raise exception 'la llegada ya estaba marcada'; end if;
  update public.funnel_prospectos set recepcion_en = now(), recepcionado_por = v_actor, actualizado_en = now()
   where id = p.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, 'llegada', v_actor, jsonb_build_object('restaurante_id', p.restaurante_id));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_sala_llegada(bigint) from public, anon;
grant execute on function public.funnel_sala_llegada(bigint) to authenticated;

-- Asignar liner o closer: sin p_agente, la rueda; con p_agente, a mano (debe estar en turno).
create or replace function public.funnel_sala_asignar(p_id bigint, p_rol text, p_agente bigint default null)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype; v_nuevo bigint; v_antes bigint; v_modo text;
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120); v_quien text;
begin
  if p_rol not in ('vendedor','cerrador') then raise exception 'rol desconocido'; end if;
  v_quien := case p_rol when 'vendedor' then 'liner' else 'closer' end;
  -- El liner asignado también puede pasarlo a closer (solo por la rueda).
  select * into p from public.funnel_prospectos where id = p_id;
  if found and p_rol = 'cerrador' and p_agente is null and p.vendedor_id is not null
     and p.vendedor_id = public.funnel_mi_agente() and not public.funnel_es_tmk() then
    select * into p from public.funnel_prospectos where id = p_id for update;
    if (p.presenta_en at time zone 'America/Guatemala')::date <> public.funnel_hoy_gt() then raise exception 'no autorizado'; end if;
  else
    p := public.funnel_sala_tomar(p_id);
  end if;
  if p.etapa <> 'sala' or not coalesce(p.califica, false) then raise exception 'primero tiene que calificar'; end if;
  if p_rol = 'cerrador' and p.vendedor_id is null then raise exception 'primero el liner'; end if;
  v_antes := case p_rol when 'vendedor' then p.vendedor_id else p.cerrador_id end;
  if p_agente is null then
    v_modo := 'rueda';
    v_nuevo := public.funnel_sala_rueda(p.restaurante_id, p_rol, v_antes);
    if v_nuevo is null then
      raise exception 'no hay ningún % disponible en turno hoy en este lugar: pedile al gerente que arme el turno', v_quien;
    end if;
  else
    v_modo := 'manual';
    if not exists (select 1 from public.funnel_turnos t join public.funnel_agentes a on a.id = t.agente_id
                    where t.agente_id = p_agente and t.fecha = public.funnel_hoy_gt()
                      and t.restaurante_id = p.restaurante_id and a.activo and a.rol = p_rol) then
      raise exception 'esa persona no está en turno hoy como % en este lugar', v_quien;
    end if;
    v_nuevo := p_agente;
  end if;
  if v_nuevo is not distinct from v_antes then raise exception 'ya lo tiene asignado'; end if;
  if p_rol = 'vendedor' then
    update public.funnel_prospectos set vendedor_id = v_nuevo, actualizado_en = now() where id = p.id;
  else
    update public.funnel_prospectos set cerrador_id = v_nuevo, actualizado_en = now() where id = p.id;
  end if;
  insert into public.funnel_sala_asignaciones(prospecto_id, rol, agente_id, modo, antes, actor)
  values (p.id, p_rol, v_nuevo, v_modo, v_antes, v_actor);
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, 'sala_asignado', v_actor, jsonb_strip_nulls(jsonb_build_object('rol', p_rol, 'agente_id', v_nuevo, 'modo', v_modo, 'antes', v_antes)));
  return jsonb_build_object('agente_id', v_nuevo, 'nombre', (select nombre from public.funnel_agentes where id = v_nuevo), 'modo', v_modo);
end $$;
revoke all on function public.funnel_sala_asignar(bigint, text, bigint) from public, anon;
grant execute on function public.funnel_sala_asignar(bigint, text, bigint) to authenticated;

create or replace function public.funnel_sala_calificar(
  p_id bigint, p_califica boolean, p_edad int default null, p_estado_civil text default null,
  p_tarjetas int default null, p_tipo_tarjetas text default null, p_motivo text default null)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare p public.funnel_prospectos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
  v_liner jsonb; v_aviso text;
begin
  p := public.funnel_sala_tomar(p_id);
  if p.etapa not in ('telemarketing','presentacion') then raise exception 'este cliente ya pasó a la sala'; end if;
  if p_califica is null then raise exception 'decí si califica o no'; end if;
  if p_edad is not null and (p_edad < 18 or p_edad > 110) then raise exception 'la edad no cuadra (18 a 110)'; end if;
  if p_estado_civil is not null and p_estado_civil not in ('casado','soltero','otro') then raise exception 'estado civil desconocido'; end if;
  if p_tarjetas is not null and (p_tarjetas < 0 or p_tarjetas > 50) then raise exception 'el número de tarjetas no cuadra'; end if;
  p_tipo_tarjetas := nullif(left(btrim(coalesce(p_tipo_tarjetas, '')), 100), '');
  p_motivo := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
  if not p_califica and p_motivo is null then raise exception 'escribí por qué no califica'; end if;
  update public.funnel_prospectos
     set edad = p_edad, estado_civil = p_estado_civil, tarjetas_credito = p_tarjetas, tipo_tarjetas = p_tipo_tarjetas,
         califica = p_califica, motivo_no = case when p_califica then null else p_motivo end,
         recepcion_en = coalesce(recepcion_en, now()), recepcionado_por = coalesce(recepcionado_por, v_actor),
         etapa = case when p_califica then 'sala' else 'baja' end, actualizado_en = now()
   where id = p.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (p.id, 'sala', v_actor, jsonb_strip_nulls(jsonb_build_object('califica', p_califica, 'motivo', p_motivo)));
  if p_califica then
    begin
      v_liner := public.funnel_sala_asignar(p.id, 'vendedor', null);
    exception when others then
      v_aviso := sqlerrm;   -- sin liner en turno: califica igual y se avisa (no se calla)
    end;
  end if;
  return jsonb_strip_nulls(jsonb_build_object('etapa', case when p_califica then 'sala' else 'baja' end,
                                              'liner', v_liner, 'aviso', v_aviso));
end $$;
revoke all on function public.funnel_sala_calificar(bigint, boolean, int, text, int, text, text) from public, anon;
grant execute on function public.funnel_sala_calificar(bigint, boolean, int, text, int, text, text) to authenticated;

-- ── 5. la bitácora de la sala solo la escriben las funciones ──────────────
drop policy if exists fev_ins on public.funnel_eventos;
create policy fev_ins on public.funnel_eventos for insert to authenticated
  with check (funnel_es_staff() and prospecto_id is not null and actor = (auth.jwt() ->> 'email')
    and ((lower(btrim(tipo)) <> all (array['no_contesta','interesado','no_interesado','reprogramar','citar','nota',
          'asignado','cita_confirmada','cita_regresada','llegada','sala','sala_asignado']))
         or (tipo = 'asignado' and funnel_es_gerente()))
    and case when funnel_es_tmk()
          then prospecto_id in (select l.id from funnel_tmk_mi_lista() l(id, nombre, telefono, estado, recontacto_en,
                                intentos, es_socio, restaurante_id, presenta_en, comentario))
          else exists (select 1 from funnel_prospectos p where p.id = funnel_eventos.prospecto_id) end);

commit;
