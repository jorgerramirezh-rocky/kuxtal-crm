-- ============================================================================
-- BLOQUE 7 · «mis clientes»: cada quien ve lo suyo (19-sep-2026)
-- Diseño con George (19-sep): 1 ok · 2 el gerente asigna liner, closer y VERIFICADOR · 4 reservas solo
-- quien las gestiona (reservaciones y la gerencia que George habilite en Roles), no ventas.
--
-- Qué cambia:
--  1. Liner y closer salen de «ve todo»: ven SOLO sus clientes (tabla y pestaña «Mis clientes»).
--     Digitador y verificador tampoco ven toda la base: el digitador ve los clientes de sus contratos;
--     el verificador, solo los contratos que la gerencia le asignó.
--  2. El liner ya no se pide closer solo: liner y closer los asigna la sala (rueda de la hostess) o la
--     gerencia; el VERIFICADOR de cada contrato lo asigna la gerencia de ventas.
--  3. Reservas: permiso nuevo «gestionar_reservas» (admin, gerente general, reservaciones; George lo
--     prende para la gerencia de marketing en Roles).
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. quién «ve todo» ────────────────────────────────────────────────────
create or replace function public.funnel_ve_todo() returns boolean
  language sql stable as $$
  select funnel_es_gerente() or funnel_rol() = any(array['reservaciones','servicio'])
$$;

drop policy if exists fp_sel on public.funnel_prospectos;
create policy fp_sel on public.funnel_prospectos for select to authenticated
  using (funnel_ve_todo()
         or (not funnel_es_tmk() and funnel_rol() not in ('recepcion', 'vendedor', 'cerrador', 'digitador', 'verificador')
             and tmk_id in (select funnel_ve_equipo()))
         -- liner y closer: solo SUS clientes
         or (funnel_rol() in ('vendedor', 'cerrador') and funnel_mi_agente() in (vendedor_id, cerrador_id))
         -- digitador: los clientes de SUS contratos
         or (funnel_rol() = 'digitador' and id in (select c.prospecto_id from funnel_contratos c where c.digitador_id = funnel_mi_agente())));
drop policy if exists fp_upd on public.funnel_prospectos;
create policy fp_upd on public.funnel_prospectos for update to authenticated
  using (funnel_ve_todo() or (not funnel_es_tmk() and funnel_rol() not in ('recepcion', 'vendedor', 'cerrador', 'digitador', 'verificador')
                              and tmk_id in (select funnel_ve_equipo())))
  with check (funnel_ve_todo() or (not funnel_es_tmk() and funnel_rol() not in ('recepcion', 'vendedor', 'cerrador', 'digitador', 'verificador')
                              and tmk_id in (select funnel_ve_equipo())));

drop policy if exists fcon_sel on public.funnel_contratos;
create policy fcon_sel on public.funnel_contratos for select to authenticated
  using (funnel_ve_todo() or funnel_mi_agente() in (vendedor_id, cerrador_id, digitador_id, verificador_id));

-- ── 3. reservas ───────────────────────────────────────────────────────────
insert into public.funnel_permisos(rol_clave, permiso, permitido)
select r.clave, 'gestionar_reservas', r.clave in ('admin', 'gerente_general', 'reservaciones')
  from public.funnel_roles r
on conflict do nothing;
drop policy if exists fres_sel on public.funnel_reservas;
create policy fres_sel on public.funnel_reservas for select to authenticated using (public.funnel_puede('gestionar_reservas'));
drop policy if exists fres_wr on public.funnel_reservas;
create policy fres_wr on public.funnel_reservas to authenticated
  using (public.funnel_puede('gestionar_reservas')) with check (public.funnel_puede('gestionar_reservas'));

-- ── 2a. el liner ya no se pide closer solo ────────────────────────────────
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.funnel_sala_asignar(bigint,text,bigint,bigint)'::regprocedure);
  if position('kux.b7' in d) = 0 then
    d := replace(d, $a$  if found and p_rol = 'cerrador' and p_agente is null and p.vendedor_id is not null$a$,
                    $a$  -- kux.b7: el liner ya NO se pide closer (George 19-sep: lo asignan la sala o la gerencia).
  if false and found and p_rol = 'cerrador' and p_agente is null and p.vendedor_id is not null$a$);
    if position('kux.b7' in d) = 0 then raise exception 'no encontré dónde parchar funnel_sala_asignar (bloque 7)'; end if;
    execute d;
  end if;
end $p$;

-- ── 2b. verificador asignado por la gerencia ──────────────────────────────
create or replace function public.funnel_contrato_asignar_verificador(p_id bigint, p_agente bigint)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if public.funnel_es_tmk() or not public.funnel_puede('corregir_sala') then raise exception 'no autorizado'; end if;
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found then raise exception 'no autorizado'; end if;
  if c.estado not in ('por_verificar', 'observado') then raise exception 'ese contrato ya no está por verificar'; end if;
  if not exists (select 1 from public.funnel_agentes a where a.id = p_agente and a.activo and a.rol = 'verificador') then
    raise exception 'esa persona no es un verificador activo';
  end if;
  -- Nadie verifica una venta en la que participa o cobra.
  if p_agente in (c.vendedor_id, c.cerrador_id, c.digitador_id, c.tmk_id)
     or exists (select 1 from public.funnel_comisiones m where m.contrato_id = c.id and m.beneficiario_id = p_agente and m.rol <> 'verificador') then
    raise exception 'ese verificador participa en la venta';
  end if;
  update public.funnel_contratos set verificador_id = p_agente where id = c.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'verificador_asignado', v_actor, jsonb_build_object('contrato_id', c.id, 'verificador_id', p_agente));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_contrato_asignar_verificador(bigint, bigint) from public, anon;
grant execute on function public.funnel_contrato_asignar_verificador(bigint, bigint) to authenticated;

-- Solo el verificador asignado verifica (o la gerencia de ventas).
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.funnel_contrato_verificar(bigint,text,text)'::regprocedure);
  if position('kux.b7' in d) = 0 then
    d := replace(d, $a$  if c.estado not in ('por_verificar', 'observado') then raise exception 'ese contrato ya no está por verificar'; end if;$a$,
                    $a$  if c.estado not in ('por_verificar', 'observado') then raise exception 'ese contrato ya no está por verificar'; end if;
  -- kux.b7: lo verifica el verificador que asignó la gerencia de ventas (o la gerencia misma).
  if not public.funnel_puede('corregir_sala') and (v_yo is null or c.verificador_id is distinct from v_yo) then
    raise exception 'ese contrato no te lo asignaron';
  end if;$a$);
    if position('kux.b7' in d) = 0 then raise exception 'no encontré dónde parchar funnel_contrato_verificar (bloque 7)'; end if;
    execute d;
  end if;
end $p$;

drop function if exists public.funnel_contratos_por_verificar();
create or replace function public.funnel_contratos_por_verificar()
  returns table(id bigint, cliente text, telefono text, membresia text, plan_pago text, precio_lista numeric,
                descuento numeric, monto numeric, enganche numeric, estado text, verificacion_nota text,
                liner text, closer text, digitador text, creado_en timestamptz, reservas int,
                verificador_id bigint, verificador text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_todo boolean := public.funnel_puede('corregir_sala'); v_yo bigint := public.funnel_mi_agente();
begin
  if public.funnel_es_tmk() or not public.funnel_puede('verificar_contratos') then raise exception 'no autorizado'; end if;
  return query select c.id, p.nombre, p.telefono, c.tipo_membresia, c.plan_pago, c.precio_lista,
         coalesce(c.descuento_membresia, 0) + coalesce(c.descuento_monto, 0), c.monto, c.enganche, c.estado,
         c.verificacion_nota, v.nombre, k.nombre, dg.nombre, c.creado_en,
         (select count(*)::int from public.funnel_reservas r where r.prospecto_id = p.id
            or (c.socio_id is not null and r.socio_id = c.socio_id)),
         c.verificador_id, vf.nombre
    from public.funnel_contratos c
    join public.funnel_prospectos p on p.id = c.prospecto_id
    left join public.funnel_agentes v on v.id = c.vendedor_id
    left join public.funnel_agentes k on k.id = c.cerrador_id
    left join public.funnel_agentes dg on dg.id = c.digitador_id
    left join public.funnel_agentes vf on vf.id = c.verificador_id
   where c.estado in ('por_verificar', 'observado')
     and (v_todo or (v_yo is not null and c.verificador_id = v_yo))
   order by (c.estado = 'observado'), c.creado_en limit 300;
end $$;
revoke all on function public.funnel_contratos_por_verificar() from public, anon;
grant execute on function public.funnel_contratos_por_verificar() to authenticated;

-- ── 1b. «Mis clientes» (liner y closer) ───────────────────────────────────
create or replace function public.funnel_mis_clientes()
  returns table(id bigint, nombre text, telefono text, restaurante_id bigint, presenta_en timestamptz,
                recepcion_en timestamptz, etapa text, mi_papel text, liner text, closer text,
                descuento text, contrato text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_yo bigint := public.funnel_mi_agente();
begin
  if v_yo is null or public.funnel_rol() not in ('vendedor', 'cerrador') then raise exception 'no autorizado'; end if;
  return query select p.id, p.nombre, p.telefono, p.restaurante_id, p.presenta_en, p.recepcion_en, p.etapa,
         case when p.vendedor_id = v_yo then 'liner' else 'closer' end, v.nombre, k.nombre,
         (select s.estado from public.funnel_descuento_solicitudes s where s.prospecto_id = p.id order by s.id desc limit 1),
         (select c.estado from public.funnel_contratos c where c.prospecto_id = p.id order by c.id desc limit 1)
    from public.funnel_prospectos p
    left join public.funnel_agentes v on v.id = p.vendedor_id
    left join public.funnel_agentes k on k.id = p.cerrador_id
   where v_yo in (p.vendedor_id, p.cerrador_id)
     and (p.etapa = 'sala' or p.recepcion_en >= now() - interval '30 days')
   order by p.recepcion_en desc nulls last, p.id desc limit 200;
end $$;
revoke all on function public.funnel_mis_clientes() from public, anon;
grant execute on function public.funnel_mis_clientes() to authenticated;

commit;
