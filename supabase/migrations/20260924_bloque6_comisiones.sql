-- ============================================================================
-- BLOQUE 6 · comisiones y cabos sueltos (19-sep-2026)
--
-- Qué cambia:
--  1. Tabla de comisiones editable (pestaña «Reglas de comisión»): solo gerencia de ventas, gerente
--     general y admin (TMK deja de tenerlo). Valores sanos (0–50 % o monto fijo con tope). Un cambio NO
--     toca contratos ya cerrados (las comisiones se calculan al cerrar y quedan guardadas).
--  2. La comisión del gerente de ventas se paga al gerente de ventas del closer (funnel_agentes.gerente_id).
--  3. Se arrepintió: la verificación guarda el vencimiento anterior del socio; gerencia de ventas ve los
--     cancelados (con reservas y enganche a devolver) y puede REABRIR uno marcado por error.
--  4. Seguridad: fuera TRUNCATE de anon/authenticated en todo el esquema; un digitador ya no cierra solo.
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. reglas de comisión ─────────────────────────────────────────────────
update public.funnel_permisos set permitido = (rol_clave in ('admin', 'gerente_general', 'gerente_ventas'))
 where permiso = 'gestionar_comisiones' and permitido is distinct from (rol_clave in ('admin', 'gerente_general', 'gerente_ventas'));
alter table public.funnel_comision_reglas drop constraint if exists funnel_comision_reglas_valores_ck;
alter table public.funnel_comision_reglas add constraint funnel_comision_reglas_valores_ck
  check (coalesce(tasa, 0) between 0 and 50 and coalesce(tasa, 0) <> 'NaN'::numeric
         and coalesce(monto_fijo, 0) between 0 and 100000 and coalesce(monto_fijo, 0) <> 'NaN'::numeric
         and rol in ('tmk', 'supervisor_tmk', 'gerente_tmk', 'vendedor', 'cerrador', 'gerente_ventas', 'digitador', 'verificador'));
revoke delete, truncate on public.funnel_comision_reglas from anon, authenticated;
-- Lente de diseño (P1-1): una regla por puesto y membresía (no se paga doble por duplicar una regla).
create unique index if not exists ux_fcr_rol_membresia on public.funnel_comision_reglas (rol, coalesce(tipo_membresia, '')) where activo;
revoke all on public.funnel_comision_reglas from anon;
alter table public.funnel_comision_reglas drop constraint if exists funnel_comision_reglas_memb_fk;
alter table public.funnel_comision_reglas add constraint funnel_comision_reglas_memb_fk
  foreign key (tipo_membresia) references public.funnel_membresias(tipo) on update cascade;
-- Ronda 1 ciber: nadie fija su propia comisión. La regla del gerente de ventas la tocan admin o el gerente general.
create or replace function public.funnel_regla_guardia() returns trigger
  language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  if current_user in ('authenticated', 'anon') and public.funnel_rol() not in ('admin', 'gerente_general')
     and (new.rol in ('gerente_ventas', 'supervisor_tmk', 'gerente_tmk')
          or (tg_op = 'UPDATE' and old.rol in ('gerente_ventas', 'supervisor_tmk', 'gerente_tmk'))) then
    -- Ronda 2: nadie que cobre por su equipo fija su propia comisión.
    raise exception 'la comisión del gerente de ventas la fija el gerente general';
  end if;
  return new;
end $$;
drop trigger if exists trg_funnel_regla_guardia on public.funnel_comision_reglas;
create trigger trg_funnel_regla_guardia before insert or update on public.funnel_comision_reglas
  for each row execute function public.funnel_regla_guardia();

-- El gerente de ventas trabaja como agente (para poder ser «el gerente» de un closer y cobrar).
update public.funnel_roles set rol_operativo = 'gerente_ventas' where clave = 'gerente_ventas' and rol_operativo is null;
-- Quién es el gerente de ventas de alguien: solo admin o el gerente general, y tiene que ser un gerente de ventas activo.
-- ¿Esa cuenta es la de ese correo? (auth.users no se lee con la cuenta del equipo: solo esto, sí/no)
create or replace function public.funnel_cuenta_es_de(p_uid uuid, p_email text) returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (select 1 from auth.users u where u.id = p_uid and lower(u.email) = lower(trim(coalesce(p_email, ''))))
$$;
revoke all on function public.funnel_cuenta_es_de(uuid, text) from public, anon;
grant execute on function public.funnel_cuenta_es_de(uuid, text) to authenticated;

create or replace function public.funnel_agente_gerente_guardia() returns trigger
  language plpgsql set search_path to 'public', 'pg_temp' as $$
declare v_jefe boolean := current_user not in ('authenticated', 'anon')
                          or public.funnel_rol() in ('admin', 'gerente_general');
begin
  -- Ronda 2 ciber: lo que decide quién cobra (puesto, cuenta atada, correo, jefe, gerente de ventas) lo
  -- cambian solo admin o el gerente general. La pantalla de Equipo solo crea agentes y los activa/desactiva.
  if not v_jefe then
    if tg_op = 'UPDATE' and (new.rol is distinct from old.rol or new.email is distinct from old.email
                             or new.supervisor_id is distinct from old.supervisor_id
                             or new.gerente_id is distinct from old.gerente_id
                             or (old.user_id is not null and new.user_id is distinct from old.user_id)) then
      raise exception 'el gerente de ventas de alguien lo asigna el gerente general';
    end if;
    if tg_op = 'INSERT' and (new.supervisor_id is not null or new.gerente_id is not null) then
      raise exception 'el gerente de ventas de alguien lo asigna el gerente general';
    end if;
    -- Los que cobran por su equipo no los crea, apaga ni prende cualquiera.
    if new.rol in ('gerente_ventas', 'supervisor_tmk', 'gerente_tmk')
       and (tg_op = 'INSERT' or new.activo is distinct from old.activo) then
      raise exception 'a los gerentes y supervisores los da de alta el gerente general';
    end if;
  end if;
  -- Atar una cuenta: solo la del mismo correo (así lo hace el alta; nadie se ata a un agente ajeno).
  if new.user_id is not null and (tg_op = 'INSERT' or new.user_id is distinct from old.user_id)
     and not v_jefe
     and not public.funnel_cuenta_es_de(new.user_id, new.email) then
    raise exception 'esa cuenta no es la de ese agente';
  end if;
  if new.gerente_id is not null and (tg_op = 'INSERT' or new.gerente_id is distinct from old.gerente_id)
     and not exists (select 1 from public.funnel_agentes g where g.id = new.gerente_id and g.activo and g.rol = 'gerente_ventas') then
    raise exception 'ese no es un gerente de ventas activo';
  end if;
  return new;
end $$;
drop trigger if exists trg_funnel_agente_gerente_guardia on public.funnel_agentes;
create trigger trg_funnel_agente_gerente_guardia before insert or update on public.funnel_agentes
  for each row execute function public.funnel_agente_gerente_guardia();

-- ── 2 y 4b. cierre: comisión del gerente de ventas + el digitador no cierra solo ──
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.funnel_cerrar_contrato(bigint,text,text,bigint,bigint,bigint,integer,bigint)'::regprocedure);
  if position('kux.b6' in d) = 0 then
    d := replace(d, $a$      when 'supervisor_tmk' then (select supervisor_id from funnel_agentes where id = pr.tmk_id) else null end;$a$,
                    $a$      when 'supervisor_tmk' then (select supervisor_id from funnel_agentes where id = pr.tmk_id)
      -- kux.b6: el gerente de ventas que cobra es el del closer (Equipo → gerente).
      when 'gerente_ventas' then (select g.id from funnel_agentes c2 join funnel_agentes g on g.id = c2.gerente_id
                                  where c2.id = p_cerrador and g.activo and g.rol = 'gerente_ventas') else null end;$a$);
    d := replace(d, $a$    if v_yo is null or v_yo not in (coalesce(p_vendedor, -1), coalesce(p_cerrador, -1), coalesce(p_digitador, -1)) then$a$,
                    $a$    -- kux.b6: cierra el liner o el closer (o gerencia); un digitador nombrándose, no.
    if v_yo is null or v_yo not in (coalesce(p_vendedor, -1), coalesce(p_cerrador, -1)) then$a$);
    -- kux.b6: la regla de una membresía REEMPLAZA a la general del mismo puesto (antes se sumaban).
    d := replace(d, $a$  for rg in select * from funnel_comision_reglas where activo and rol <> 'verificador'
                and (tipo_membresia is null or tipo_membresia = p_membresia) loop$a$,
                    $a$  for rg in select * from funnel_comision_reglas g where g.activo and g.rol <> 'verificador'
                and (g.tipo_membresia = p_membresia
                     or (g.tipo_membresia is null and not exists (select 1 from funnel_comision_reglas e   -- kux.b6
                          where e.activo and e.rol = g.rol and e.tipo_membresia = p_membresia))) loop$a$);
    if (length(d) - length(replace(d, 'kux.b6', ''))) / 6 <> 3 then
      raise exception 'no encontré dónde parchar funnel_cerrar_contrato (bloque 6)';
    end if;
    execute d;
  end if;
end $p$;

-- ── 3. se arrepintió: guardar para poder reabrir ──────────────────────────
alter table public.funnel_contratos add column if not exists socio_vencimiento_antes date,
  add column if not exists reabierto_por text;
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.funnel_contrato_verificar(bigint,text,text)'::regprocedure);
  if position('kux.b6' in d) = 0 then
    d := replace(d, $a$      update public.socios set contrato_cancelado_en = now(), vencimiento = least(vencimiento, current_date) where id = c.socio_id;$a$,
                    $a$      -- kux.b6: se guarda el vencimiento anterior para poder reabrir si fue un error.
      update public.funnel_contratos set socio_vencimiento_antes = (select vencimiento from public.socios where id = c.socio_id) where id = c.id;
      update public.socios set contrato_cancelado_en = now(), vencimiento = least(vencimiento, current_date) where id = c.socio_id;$a$);
    d := replace(d, $a$      for rg in select * from public.funnel_comision_reglas where activo and rol = 'verificador'
                    and (tipo_membresia is null or tipo_membresia = c.tipo_membresia) loop$a$,
                    $a$      for rg in select * from public.funnel_comision_reglas g where g.activo and g.rol = 'verificador'
                    and (g.tipo_membresia = c.tipo_membresia
                         or (g.tipo_membresia is null and not exists (select 1 from public.funnel_comision_reglas e   -- kux.b6
                              where e.activo and e.rol = g.rol and e.tipo_membresia = c.tipo_membresia))) loop$a$);
    d := replace(d, $a$    raise exception 'no podés verificar una venta en la que participaste';
  end if;$a$, $a$    raise exception 'no podés verificar una venta en la que participaste';
  end if;
  -- kux.b6: tampoco quien COBRA por la venta sin haberla hecho (gerente del closer, supervisor del
  -- telemarketer) ni quien reabrió el contrato.
  if exists (select 1 from public.funnel_agentes a
              where a.id in ((select gerente_id from public.funnel_agentes where id = c.cerrador_id),
                             (select supervisor_id from public.funnel_agentes where id = c.tmk_id))
                and (a.id = v_yo or a.user_id = auth.uid()))
     or lower(v_actor) = lower(coalesce(c.reabierto_por, ''))
     -- kux.b6: ni quien tenga cualquier comisión de ESTE contrato (por agente, cuenta o correo).
     or exists (select 1 from public.funnel_comisiones m join public.funnel_agentes a on a.id = m.beneficiario_id
                 where m.contrato_id = c.id
                   and (a.id = v_yo or a.user_id = auth.uid() or lower(trim(coalesce(a.email, ''))) = lower(v_actor))) then
    raise exception 'no podés verificar una venta en la que participaste';
  end if;$a$);
    if (length(d) - length(replace(d, 'kux.b6', ''))) / 6 <> 4 then raise exception 'no encontré dónde parchar funnel_contrato_verificar (bloque 6)'; end if;
    execute d;
  end if;
end $p$;

-- Cancelados (para gerencia de ventas): con reservas del cliente y enganche a devolver.
create or replace function public.funnel_contratos_cancelados()
  returns table(id bigint, cliente text, telefono text, membresia text, monto numeric, enganche numeric,
                reservas int, nota text, cancelado_por text, cancelado_en timestamptz, se_puede_reabrir boolean)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() or not public.funnel_puede('corregir_sala') then raise exception 'no autorizado'; end if;
  return query
  select c.id, p.nombre, p.telefono, c.tipo_membresia, c.monto, c.enganche,
         (select count(*)::int from public.funnel_reservas r where r.prospecto_id = p.id
            or (c.socio_id is not null and r.socio_id = c.socio_id)),
         c.verificacion_nota, c.verificado_por, c.verificado_en,
         not exists (select 1 from public.funnel_contratos x where x.prospecto_id = c.prospecto_id and x.estado <> 'cancelado')
    from public.funnel_contratos c join public.funnel_prospectos p on p.id = c.prospecto_id
   where c.estado = 'cancelado'
   order by c.verificado_en desc nulls last limit 200;
end $$;
revoke all on function public.funnel_contratos_cancelados() from public, anon;
grant execute on function public.funnel_contratos_cancelados() to authenticated;

drop function if exists public.funnel_contrato_reabrir(bigint, text);
create or replace function public.funnel_contrato_reabrir(p_id bigint, p_nota text, p_enganche_no_devuelto boolean default false)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if public.funnel_es_tmk() or not public.funnel_puede('corregir_sala') then raise exception 'no autorizado'; end if;
  p_nota := nullif(left(btrim(coalesce(p_nota, '')), 300), '');
  if p_nota is null then raise exception 'escribí por qué se reabre'; end if;
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found then raise exception 'no autorizado'; end if;
  if c.estado <> 'cancelado' then raise exception 'solo se reabre un contrato cancelado'; end if;
  -- Diseño P2-3: si hubo enganche, quien reabre confirma que NO se le devolvió al cliente.
  if coalesce(c.enganche, 0) > 0 and not coalesce(p_enganche_no_devuelto, false) then
    raise exception 'confirmá que el enganche no se le devolvió al cliente';
  end if;
  if exists (select 1 from public.funnel_contratos x where x.prospecto_id = c.prospecto_id and x.estado <> 'cancelado') then
    raise exception 'ese cliente ya tiene otro contrato vivo';
  end if;
  -- Vuelve a verificación: comisiones pendientes, cliente socio, socio con su vencimiento de antes.
  update public.funnel_contratos set estado = 'por_verificar', reabierto_por = v_actor,
         verificacion_nota = left('Reabierto: ' || p_nota, 500), verificado_por = null, verificado_en = null
   where id = c.id;
  update public.funnel_comisiones set estado = 'pendiente' where contrato_id = c.id and estado = 'anulada' and rol <> 'verificador';
  update public.funnel_prospectos set etapa = 'socio', motivo_baja = null, baja_en = null, actualizado_en = now() where id = c.prospecto_id;
  if c.socio_id is not null then
    update public.socios set contrato_cancelado_en = null, vencimiento = coalesce(c.socio_vencimiento_antes, vencimiento),
           tipo = c.tipo_membresia, tipo_norm = c.tipo_membresia, total_num = c.monto, total_texto = c.monto::text
     where id = c.socio_id;
  end if;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'contrato_reabierto', v_actor, jsonb_build_object('contrato_id', c.id, 'nota', p_nota));
  return jsonb_build_object('estado', 'por_verificar');
end $$;
revoke all on function public.funnel_contrato_reabrir(bigint, text, boolean) from public, anon;
grant execute on function public.funnel_contrato_reabrir(bigint, text, boolean) to authenticated;

-- La tarjeta de verificación muestra si el cliente tiene reservas (para avisar antes de cancelar).
drop function if exists public.funnel_contratos_por_verificar();
create or replace function public.funnel_contratos_por_verificar()
  returns table(id bigint, cliente text, telefono text, membresia text, plan_pago text, precio_lista numeric,
                descuento numeric, monto numeric, enganche numeric, estado text, verificacion_nota text,
                liner text, closer text, digitador text, creado_en timestamptz, reservas int)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() or not public.funnel_puede('verificar_contratos') then raise exception 'no autorizado'; end if;
  return query select c.id, p.nombre, p.telefono, c.tipo_membresia, c.plan_pago, c.precio_lista,
         coalesce(c.descuento_membresia, 0) + coalesce(c.descuento_monto, 0), c.monto, c.enganche, c.estado,
         c.verificacion_nota, v.nombre, k.nombre, dg.nombre, c.creado_en,
         (select count(*)::int from public.funnel_reservas r where r.prospecto_id = p.id
            or (c.socio_id is not null and r.socio_id = c.socio_id))
    from public.funnel_contratos c
    join public.funnel_prospectos p on p.id = c.prospecto_id
    left join public.funnel_agentes v on v.id = c.vendedor_id
    left join public.funnel_agentes k on k.id = c.cerrador_id
    left join public.funnel_agentes dg on dg.id = c.digitador_id
   where c.estado in ('por_verificar', 'observado')
   order by (c.estado = 'observado'), c.creado_en limit 300;
end $$;
revoke all on function public.funnel_contratos_por_verificar() from public, anon;
grant execute on function public.funnel_contratos_por_verificar() to authenticated;

-- ── 4. fuera TRUNCATE (salta las políticas) ───────────────────────────────
revoke truncate on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate on tables from anon, authenticated;

commit;
