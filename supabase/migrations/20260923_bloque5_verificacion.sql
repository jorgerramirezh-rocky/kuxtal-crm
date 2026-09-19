-- ============================================================================
-- BLOQUE 5 · descuentos por segmento, aprobación y verificación del contrato (19-sep-2026)
-- Diseño aprobado por George con botón kuxb5dis:si.
--
-- Qué cambia:
--  1. Descuentos por SEGMENTO: el gerente de ventas (permiso gestionar_descuentos) crea sus
--     segmentos (porcentaje o monto, para qué membresías). Nadie escribe el monto a mano: el
--     precio lo calcula la base (precio de lista − descuento de la membresía − segmento aprobado).
--  2. APROBACIÓN: con el cliente en sala, el closer pide un segmento; el gerente de ventas
--     (aprobar_descuentos) lo aprueba o rechaza. Solo con la aprobación se cierra con descuento.
--  3. VERIFICACIÓN: el contrato nace «por verificar». El verificador (verificar_contratos) llama
--     al cliente: verificado (comisiones liberadas) · con observaciones (nota) · se arrepintió
--     (contrato cancelado, comisiones anuladas, prospecto de baja, socio marcado; nada se borra).
--  4. Las comisiones nacen «pendientes»; la del verificador nace al verificar, a nombre de quien verificó.
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. permisos ───────────────────────────────────────────────────────────
insert into public.funnel_permisos(rol_clave, permiso, permitido)
select r.clave, p.permiso,
       case p.permiso when 'verificar_contratos'
         then r.clave in ('admin','gerente_general','gerente_ventas','verificador')
         else r.clave in ('admin','gerente_general','gerente_ventas') end
  from public.funnel_roles r
  cross join (values ('gestionar_descuentos'), ('aprobar_descuentos'), ('verificar_contratos')) p(permiso)
on conflict do nothing;

-- ── 2. segmentos de descuento ─────────────────────────────────────────────
create table if not exists public.funnel_descuentos (
  id bigint generated always as identity primary key,
  nombre text not null check (char_length(btrim(nombre)) between 1 and 80),
  tipo text not null check (tipo in ('porcentaje', 'monto')),
  valor numeric not null check (valor > 0),
  membresias text[],                 -- null = todas
  activo boolean not null default true,
  creado_por text,
  creado_en timestamptz not null default now(),
  constraint funnel_descuentos_pct_ck check (tipo <> 'porcentaje' or valor <= 100)
);
comment on table public.funnel_descuentos is
  'Bloque 5: segmentos de descuento que define el gerente de ventas (porcentaje o monto, por membresía).';
alter table public.funnel_descuentos enable row level security;
drop policy if exists fdes_sel on public.funnel_descuentos;
create policy fdes_sel on public.funnel_descuentos for select to authenticated using (public.funnel_es_staff());
drop policy if exists fdes_ins on public.funnel_descuentos;
create policy fdes_ins on public.funnel_descuentos for insert to authenticated
  with check (public.funnel_puede('gestionar_descuentos'));
drop policy if exists fdes_upd on public.funnel_descuentos;
create policy fdes_upd on public.funnel_descuentos for update to authenticated
  using (public.funnel_puede('gestionar_descuentos')) with check (public.funnel_puede('gestionar_descuentos'));
revoke all on public.funnel_descuentos from public, anon, authenticated;
grant select, insert (nombre, tipo, valor, membresias, creado_por), update (activo) on public.funnel_descuentos to authenticated;

-- ── 3. pedidos de descuento (se escriben solo por funciones) ──────────────
create table if not exists public.funnel_descuento_solicitudes (
  id bigint generated always as identity primary key,
  prospecto_id bigint not null references public.funnel_prospectos(id) on delete cascade,
  descuento_id bigint not null references public.funnel_descuentos(id),
  membresia text not null,
  monto_descuento numeric not null check (monto_descuento >= 0),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada', 'usada', 'reemplazada')),
  pedido_por text,
  pedido_en timestamptz not null default now(),
  resuelto_por text,
  resuelto_en timestamptz,
  nota text check (char_length(coalesce(nota, '')) <= 300)
);
create index if not exists ix_fds_prosp on public.funnel_descuento_solicitudes(prospecto_id);
alter table public.funnel_descuento_solicitudes enable row level security;
revoke all on public.funnel_descuento_solicitudes from public, anon, authenticated;

-- ── 4. contrato: precio calculado, descuento y verificación ───────────────
alter table public.funnel_contratos
  add column if not exists precio_lista numeric,
  add column if not exists descuento_membresia numeric,
  add column if not exists descuento_solicitud_id bigint references public.funnel_descuento_solicitudes(id),
  add column if not exists descuento_monto numeric,
  add column if not exists verificado_por text,
  add column if not exists verificado_en timestamptz,
  add column if not exists verificacion_nota text;
alter table public.funnel_contratos drop constraint if exists funnel_contratos_estado_ck;
alter table public.funnel_contratos add constraint funnel_contratos_estado_ck
  check (estado in ('firmado', 'por_verificar', 'observado', 'verificado', 'cancelado'));

alter table public.funnel_comisiones add column if not exists estado text not null default 'pendiente';
alter table public.funnel_comisiones drop constraint if exists funnel_comisiones_estado_ck;
alter table public.funnel_comisiones add constraint funnel_comisiones_estado_ck
  check (estado in ('pendiente', 'liberada', 'anulada'));
revoke insert, update, delete, truncate on public.funnel_comisiones from anon, authenticated;

alter table public.socios add column if not exists contrato_cancelado_en timestamptz;
comment on column public.socios.contrato_cancelado_en is
  'Bloque 5: el cliente se arrepintió en la verificación; el socio no se borra, queda marcado.';

-- ── 5. precio: una sola fuente ────────────────────────────────────────────
-- Precio de lista y descuento propio de la membresía (activa). null si no existe.
create or replace function public.funnel_membresia_precio(p_tipo text, out precio numeric, out descuento numeric)
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select coalesce(m.precio, 0), coalesce(m.descuento, 0) from public.funnel_membresias m where m.tipo = p_tipo and m.activo
$$;
revoke all on function public.funnel_membresia_precio(text) from public, anon, authenticated;

-- ── 6. pedir y resolver un descuento ──────────────────────────────────────
create or replace function public.funnel_descuento_pedir(p_prospecto bigint, p_membresia text, p_descuento bigint)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare pr public.funnel_prospectos%rowtype; d public.funnel_descuentos%rowtype; v_p numeric; v_dm numeric;
  v_monto numeric; v_id bigint; v_yo bigint := public.funnel_mi_agente();
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if public.funnel_es_tmk() or not public.funnel_puede('cerrar_contrato') then raise exception 'no autorizado'; end if;
  select * into pr from public.funnel_prospectos where id = p_prospecto for update;
  if not found or not (public.funnel_puede('corregir_sala')
                       or (v_yo is not null and v_yo in (pr.vendedor_id, pr.cerrador_id))) then
    raise exception 'no autorizado';
  end if;
  if pr.etapa is distinct from 'sala' or not coalesce(pr.califica, false) then
    raise exception 'solo se pide descuento para quien está en la sala';
  end if;
  select precio, descuento into v_p, v_dm from public.funnel_membresia_precio(p_membresia);
  if v_p is null then raise exception 'elegí una membresía activa'; end if;
  select * into d from public.funnel_descuentos where id = p_descuento and activo;
  if not found then raise exception 'ese segmento de descuento no existe o está apagado'; end if;
  if d.membresias is not null and not (p_membresia = any(d.membresias)) then
    raise exception 'ese segmento no aplica a la membresía %', p_membresia;
  end if;
  v_monto := case d.tipo when 'porcentaje' then round((v_p - v_dm) * d.valor / 100.0, 2) else d.valor end;
  v_monto := least(v_monto, greatest(v_p - v_dm, 0));
  -- Un pedido vivo por cliente: el nuevo reemplaza al anterior (pendiente o aprobado sin usar).
  update public.funnel_descuento_solicitudes set estado = 'reemplazada'
   where prospecto_id = pr.id and estado in ('pendiente', 'aprobada');
  insert into public.funnel_descuento_solicitudes(prospecto_id, descuento_id, membresia, monto_descuento, pedido_por)
  values (pr.id, d.id, p_membresia, v_monto, v_actor) returning id into v_id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (pr.id, 'descuento_pedido', v_actor, jsonb_build_object('solicitud_id', v_id, 'segmento', d.nombre, 'membresia', p_membresia, 'monto', v_monto));
  return jsonb_build_object('solicitud_id', v_id, 'monto_descuento', v_monto, 'precio_final', greatest(v_p - v_dm - v_monto, 0));
end $$;
revoke all on function public.funnel_descuento_pedir(bigint, text, bigint) from public, anon;
grant execute on function public.funnel_descuento_pedir(bigint, text, bigint) to authenticated;

-- Estado del pedido vivo de un cliente (para la tarjeta de Cierre).
create or replace function public.funnel_descuento_de(p_prospecto bigint)
  returns table(id bigint, segmento text, membresia text, monto_descuento numeric, estado text, nota text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_yo bigint := public.funnel_mi_agente(); pr public.funnel_prospectos%rowtype;
begin
  select * into pr from public.funnel_prospectos where public.funnel_prospectos.id = p_prospecto;
  if not found or public.funnel_es_tmk() or not (public.funnel_puede('corregir_sala') or public.funnel_puede('aprobar_descuentos')
       or (public.funnel_puede('cerrar_contrato') and v_yo is not null and v_yo in (pr.vendedor_id, pr.cerrador_id))) then
    raise exception 'no autorizado';
  end if;
  return query select s.id, d.nombre, s.membresia, s.monto_descuento, s.estado, s.nota
    from public.funnel_descuento_solicitudes s join public.funnel_descuentos d on d.id = s.descuento_id
   where s.prospecto_id = p_prospecto and s.estado in ('pendiente', 'aprobada', 'rechazada')
   order by s.id desc limit 1;
end $$;
revoke all on function public.funnel_descuento_de(bigint) from public, anon;
grant execute on function public.funnel_descuento_de(bigint) to authenticated;

create or replace function public.funnel_descuentos_por_aprobar()
  returns table(id bigint, prospecto_id bigint, cliente text, segmento text, membresia text, precio_lista numeric,
                monto_descuento numeric, pedido_por text, pedido_en timestamptz, closer text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() or not public.funnel_puede('aprobar_descuentos') then raise exception 'no autorizado'; end if;
  return query select s.id, s.prospecto_id, p.nombre, d.nombre, s.membresia,
         (select m.precio from public.funnel_membresias m where m.tipo = s.membresia), s.monto_descuento,
         s.pedido_por, s.pedido_en, c.nombre
    from public.funnel_descuento_solicitudes s
    join public.funnel_descuentos d on d.id = s.descuento_id
    join public.funnel_prospectos p on p.id = s.prospecto_id
    left join public.funnel_agentes c on c.id = p.cerrador_id
   where s.estado = 'pendiente' order by s.pedido_en limit 200;
end $$;
revoke all on function public.funnel_descuentos_por_aprobar() from public, anon;
grant execute on function public.funnel_descuentos_por_aprobar() to authenticated;

create or replace function public.funnel_descuento_resolver(p_id bigint, p_aprobar boolean, p_nota text default null)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare s public.funnel_descuento_solicitudes%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if public.funnel_es_tmk() or not public.funnel_puede('aprobar_descuentos') then raise exception 'no autorizado'; end if;
  if p_aprobar is null then raise exception 'decí si lo aprobás o no'; end if;
  p_nota := nullif(left(btrim(coalesce(p_nota, '')), 300), '');
  if not p_aprobar and p_nota is null then raise exception 'escribí por qué lo rechazás'; end if;
  select * into s from public.funnel_descuento_solicitudes where id = p_id for update;
  if not found then raise exception 'no autorizado'; end if;
  if s.estado <> 'pendiente' then raise exception 'ese pedido ya se resolvió'; end if;
  update public.funnel_descuento_solicitudes
     set estado = case when p_aprobar then 'aprobada' else 'rechazada' end, resuelto_por = v_actor,
         resuelto_en = now(), nota = p_nota
   where id = p_id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (s.prospecto_id, case when p_aprobar then 'descuento_aprobado' else 'descuento_rechazado' end, v_actor,
          jsonb_strip_nulls(jsonb_build_object('solicitud_id', p_id, 'nota', p_nota)));
  return jsonb_build_object('estado', case when p_aprobar then 'aprobada' else 'rechazada' end);
end $$;
revoke all on function public.funnel_descuento_resolver(bigint, boolean, text) from public, anon;
grant execute on function public.funnel_descuento_resolver(bigint, boolean, text) to authenticated;

-- ── 7. cerrar el contrato: precio calculado, nace «por verificar» ─────────
drop function if exists public.funnel_cerrar_contrato(bigint, text, text, numeric, bigint, bigint, bigint, bigint, integer);
create or replace function public.funnel_cerrar_contrato(
  p_prospecto bigint, p_membresia text, p_plan text,
  p_vendedor bigint default null, p_cerrador bigint default null, p_digitador bigint default null,
  p_anios integer default 4, p_solicitud bigint default null)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  cid bigint; pr record; rg record; benef bigint; base numeric; s public.funnel_descuento_solicitudes%rowtype;
  v_socio bigint; v_no text; v_liner text; v_closer text; v_yo bigint;
  v_p numeric; v_dm numeric; v_ds numeric := 0; v_monto numeric;
begin
  if not funnel_puede('cerrar_contrato') or funnel_es_tmk() then raise exception 'no autorizado'; end if;
  select * into pr from funnel_prospectos where id = p_prospecto for update;
  if pr.id is null then raise exception 'prospecto no existe'; end if;
  -- Un contrato vivo por cliente (uno cancelado sí deja volver a cerrar).
  if pr.etapa = 'socio' or exists (select 1 from funnel_contratos where prospecto_id = p_prospecto and estado <> 'cancelado') then
    raise exception 'prospecto ya cerrado';
  end if;
  -- Bloque 4: sin corregir_sala (solo gerencia de ventas) se cierra SOLO lo que dejó la sala.
  if not funnel_puede('corregir_sala') then
    if pr.etapa is distinct from 'sala' or not coalesce(pr.califica, false) then
      raise exception 'solo se cierra a quien calificó en la sala';
    end if;
    if pr.cerrador_id is null then raise exception 'falta el closer: pasalo a closer en Recepción'; end if;
    if p_vendedor is distinct from pr.vendedor_id or p_cerrador is distinct from pr.cerrador_id then
      raise exception 'el liner y el closer del contrato son los que asignó la sala';
    end if;
  end if;
  if p_vendedor is not null and not exists (select 1 from funnel_agentes where id = p_vendedor and activo and rol = 'vendedor') then
    raise exception 'vendedor invalido';
  end if;
  if p_cerrador is not null and not exists (select 1 from funnel_agentes where id = p_cerrador and activo and rol = 'cerrador') then
    raise exception 'cerrador invalido';
  end if;
  if p_digitador is not null and not exists (select 1 from funnel_agentes where id = p_digitador and activo and rol = 'digitador') then
    raise exception 'digitador invalido';
  end if;
  if not funnel_es_gerente() then
    select id into v_yo from funnel_agentes where user_id = auth.uid() and activo limit 1;
    if v_yo is null or v_yo not in (coalesce(p_vendedor, -1), coalesce(p_cerrador, -1), coalesce(p_digitador, -1)) then
      raise exception 'debes aparecer como uno de los roles del contrato que cerras';
    end if;
  end if;
  if coalesce(p_anios, 4) not between 1 and 10 then raise exception 'la vigencia va de 1 a 10 años'; end if;

  -- Bloque 5: el precio lo pone la base. Lista − descuento de la membresía − segmento APROBADO.
  select precio, descuento into v_p, v_dm from funnel_membresia_precio(p_membresia);
  if v_p is null then raise exception 'elegí una membresía activa'; end if;
  if p_solicitud is not null then
    select * into s from funnel_descuento_solicitudes where id = p_solicitud for update;
    if not found or s.prospecto_id <> p_prospecto then raise exception 'ese descuento no es de este cliente'; end if;
    if s.estado <> 'aprobada' then raise exception 'el descuento todavía no está aprobado por el gerente de ventas'; end if;
    if s.membresia <> p_membresia then raise exception 'el descuento se aprobó para la membresía %', s.membresia; end if;
    v_ds := s.monto_descuento;
    update funnel_descuento_solicitudes set estado = 'usada' where id = s.id;
  end if;
  v_monto := greatest(v_p - v_dm - v_ds, 0);

  insert into funnel_contratos(prospecto_id, tipo_membresia, plan_pago, monto, tmk_id, vendedor_id, cerrador_id, digitador_id,
                               estado, precio_lista, descuento_membresia, descuento_solicitud_id, descuento_monto)
    values (p_prospecto, p_membresia, p_plan, v_monto, pr.tmk_id, p_vendedor, p_cerrador, p_digitador,
            'por_verificar', v_p, v_dm, s.id, v_ds) returning id into cid;
  update funnel_prospectos set etapa = 'socio', vendedor_id = p_vendedor, cerrador_id = p_cerrador, actualizado_en = now() where id = p_prospecto;
  insert into funnel_eventos(prospecto_id, tipo, actor, payload)
    values (p_prospecto, 'contrato', coalesce(nullif(auth.jwt()->>'email', ''), 'sistema'),
            jsonb_strip_nulls(jsonb_build_object('contrato_id', cid, 'membresia', p_membresia, 'monto', v_monto, 'descuento', nullif(v_ds, 0))));

  if pr.socio_id is null then
    perform pg_advisory_xact_lock(hashtext('socios_no_socio'));
    select nombre into v_liner from funnel_agentes where id = p_vendedor;
    select nombre into v_closer from funnel_agentes where id = p_cerrador;
    v_no := (coalesce((select max((no_socio)::int) from socios where no_socio ~ '^[0-9]{3,5}$'), 3906) + 1)::text;
    insert into socios(no_socio, nombre, celular, tipo, tipo_norm, total_texto, total_num, fecha_ingreso, vencimiento, anios_servicio, liner, closer, closer_norm)
      values (v_no, pr.nombre, nullif(regexp_replace(coalesce(pr.telefono, ''), '[^0-9]', '', 'g'), ''),
              p_membresia, p_membresia, v_monto::text, v_monto, current_date,
              (current_date + (coalesce(p_anios, 4)::text || ' years')::interval)::date,
              coalesce(p_anios, 4), v_liner, v_closer, v_closer) returning id into v_socio;
    update funnel_prospectos set socio_id = v_socio where id = p_prospecto;
  else
    v_socio := pr.socio_id; select no_socio into v_no from socios where id = v_socio;
  end if;
  update funnel_contratos set socio_id = v_socio where id = cid;

  -- Comisiones PENDIENTES hasta verificar; la del verificador nace al verificar.
  for rg in select * from funnel_comision_reglas where activo and rol <> 'verificador'
                and (tipo_membresia is null or tipo_membresia = p_membresia) loop
    benef := case rg.rol
      when 'tmk' then pr.tmk_id when 'vendedor' then p_vendedor when 'cerrador' then p_cerrador
      when 'digitador' then p_digitador
      when 'supervisor_tmk' then (select supervisor_id from funnel_agentes where id = pr.tmk_id) else null end;
    base := coalesce(rg.monto_fijo, 0) + coalesce(rg.tasa, 0) / 100.0 * coalesce(v_monto, 0);
    if base > 0 then
      insert into funnel_comisiones(contrato_id, rol, beneficiario_id, regla_id, monto, estado)
      values (cid, rg.rol, benef, rg.id, round(base, 2), 'pendiente');
    end if;
  end loop;
  return jsonb_build_object('contrato_id', cid, 'socio_id', v_socio, 'no_socio', v_no, 'monto', v_monto,
                            'precio_lista', v_p, 'descuento', v_dm + v_ds);
end $$;
revoke all on function public.funnel_cerrar_contrato(bigint, text, text, bigint, bigint, bigint, integer, bigint) from public, anon;
grant execute on function public.funnel_cerrar_contrato(bigint, text, text, bigint, bigint, bigint, integer, bigint) to authenticated;

-- ── 8. verificación ───────────────────────────────────────────────────────
create or replace function public.funnel_contratos_por_verificar()
  returns table(id bigint, cliente text, telefono text, membresia text, plan_pago text, precio_lista numeric,
                descuento numeric, monto numeric, enganche numeric, estado text, verificacion_nota text,
                liner text, closer text, creado_en timestamptz)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if public.funnel_es_tmk() or not public.funnel_puede('verificar_contratos') then raise exception 'no autorizado'; end if;
  return query select c.id, p.nombre, p.telefono, c.tipo_membresia, c.plan_pago, c.precio_lista,
         coalesce(c.descuento_membresia, 0) + coalesce(c.descuento_monto, 0), c.monto, c.enganche, c.estado,
         c.verificacion_nota, v.nombre, k.nombre, c.creado_en
    from public.funnel_contratos c
    join public.funnel_prospectos p on p.id = c.prospecto_id
    left join public.funnel_agentes v on v.id = c.vendedor_id
    left join public.funnel_agentes k on k.id = c.cerrador_id
   where c.estado in ('por_verificar', 'observado')
   order by (c.estado = 'observado'), c.creado_en limit 300;
end $$;
revoke all on function public.funnel_contratos_por_verificar() from public, anon;
grant execute on function public.funnel_contratos_por_verificar() to authenticated;

create or replace function public.funnel_contrato_verificar(p_id bigint, p_resultado text, p_nota text default null)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
  v_yo bigint := public.funnel_mi_agente(); v_verif bigint; rg record; base numeric;
begin
  if public.funnel_es_tmk() or not public.funnel_puede('verificar_contratos') then raise exception 'no autorizado'; end if;
  if p_resultado not in ('verificado', 'observado', 'arrepentido') then raise exception 'resultado desconocido'; end if;
  p_nota := nullif(left(btrim(coalesce(p_nota, '')), 500), '');
  if p_resultado <> 'verificado' and p_nota is null then raise exception 'escribí qué pasó con el cliente'; end if;
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found then raise exception 'no autorizado'; end if;
  if c.estado not in ('por_verificar', 'observado') then raise exception 'ese contrato ya no está por verificar'; end if;
  -- Nadie verifica una venta en la que participó.
  if v_yo is not null and v_yo in (c.vendedor_id, c.cerrador_id, c.digitador_id, c.tmk_id) then
    raise exception 'no podés verificar una venta en la que participaste';
  end if;
  if p_resultado = 'verificado' then
    select a.id into v_verif from public.funnel_agentes a where a.id = v_yo and a.activo and a.rol = 'verificador';
    update public.funnel_contratos set estado = 'verificado', verificado_por = v_actor, verificado_en = now(),
           verificacion_nota = p_nota, verificador_id = coalesce(v_verif, verificador_id) where id = c.id;
    update public.funnel_comisiones set estado = 'liberada' where contrato_id = c.id and estado = 'pendiente';
    if v_verif is not null then
      for rg in select * from public.funnel_comision_reglas where activo and rol = 'verificador'
                    and (tipo_membresia is null or tipo_membresia = c.tipo_membresia) loop
        base := coalesce(rg.monto_fijo, 0) + coalesce(rg.tasa, 0) / 100.0 * coalesce(c.monto, 0);
        if base > 0 then
          insert into public.funnel_comisiones(contrato_id, rol, beneficiario_id, regla_id, monto, estado)
          values (c.id, 'verificador', v_verif, rg.id, round(base, 2), 'liberada');
        end if;
      end loop;
    end if;
  elsif p_resultado = 'observado' then
    update public.funnel_contratos set estado = 'observado', verificacion_nota = p_nota,
           verificado_por = v_actor, verificado_en = now() where id = c.id;
  else
    update public.funnel_contratos set estado = 'cancelado', verificacion_nota = p_nota,
           verificado_por = v_actor, verificado_en = now() where id = c.id;
    update public.funnel_comisiones set estado = 'anulada' where contrato_id = c.id and estado <> 'anulada';
    update public.funnel_prospectos set etapa = 'baja', motivo_baja = left('Se arrepintió en la verificación: ' || p_nota, 300),
           baja_en = now(), actualizado_en = now() where id = c.prospecto_id;
    if c.socio_id is not null then update public.socios set contrato_cancelado_en = now() where id = c.socio_id; end if;
  end if;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'verificacion', v_actor, jsonb_strip_nulls(jsonb_build_object('contrato_id', c.id, 'resultado', p_resultado, 'nota', p_nota)));
  return jsonb_build_object('estado', case p_resultado when 'verificado' then 'verificado' when 'observado' then 'observado' else 'cancelado' end);
end $$;
revoke all on function public.funnel_contrato_verificar(bigint, text, text) from public, anon;
grant execute on function public.funnel_contrato_verificar(bigint, text, text) to authenticated;

commit;
