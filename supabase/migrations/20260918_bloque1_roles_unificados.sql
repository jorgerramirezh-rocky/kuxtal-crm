-- ============================================================================
-- BLOQUE 1 · roles unificados — la base obedece la pestaña Roles (18-sep-2026)
--
-- Qué arregla (hallazgos 9f24e1cd, 577a7d99, 95ca79a8 del cerebro):
--  1. La persona se ata a su CUENTA (auth.uid), no a su correo. Antes, una fila de
--     agente con el mismo correo (aunque en otra mayúscula) le regalaba a esa cuenta
--     los prospectos de otro.
--  2. Un solo sistema de roles: el rol de la cuenta (app_metadata.role) manda y
--     funnel_roles.rol_operativo dice qué rol de agente le corresponde. Un agente
--     atado a una cuenta con otro rol no se puede guardar.
--  3. La matriz de permisos DEJA DE SER DECORATIVA: socios, comisiones, reglas de
--     comisión y el cierre de contratos preguntan funnel_puede(). Para que nadie gane
--     ni pierda nada el día de la migración, la matriz se alinea primero a lo que la
--     base ya dejaba hacer. Desde ahí, lo que George marque en la pestaña es la ley.
--  4. Quien no es gerente ve los prospectos de SU equipo (él + los que le reportan).
--  5. Nombres de George como etiqueta: Hostess, Liner, Closer (claves internas iguales).
--
-- Única ampliación a propósito: cada agente ve SUS PROPIAS comisiones.
-- Todo en una transacción. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

-- ── 1. identidad por cuenta ────────────────────────────────────────────────
-- Un agente ACTIVO por cuenta ya lo garantiza funnel_agentes_user_id_activo_unico (vivo).
-- A propósito no se exige uno por cuenta contando inactivos: cambiar a alguien de rol es
-- dar de baja su agente viejo y crear otro con la misma cuenta. Acá: la cuenta tiene que existir.
alter table public.funnel_agentes drop constraint if exists funnel_agentes_user_id_fkey;
alter table public.funnel_agentes add constraint funnel_agentes_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- Relleno: solo cuando el correo apunta a UNA cuenta y a UN agente sin cuenta.
-- Lo ambiguo NO se adivina: queda sin cuenta y aparece en funnel_equipo_descalces.
update public.funnel_agentes a
   set user_id = u.id
  from auth.users u
 where a.user_id is null
   and lower(a.email) = lower(u.email)
   and (select count(*) from auth.users u2 where lower(u2.email) = lower(a.email)) = 1
   and (select count(*) from public.funnel_agentes a2 where lower(a2.email) = lower(a.email)) = 1;

create or replace function public.funnel_mi_agente() returns bigint
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select a.id from public.funnel_agentes a where a.user_id = auth.uid() and a.activo limit 1
$$;
revoke all on function public.funnel_mi_agente() from public, anon;
grant execute on function public.funnel_mi_agente() to authenticated, service_role;

-- El árbol arranca en MI agente (por cuenta). Con id ajeno solo responde a gerentes:
-- antes cualquiera podía pedir el organigrama de otro.
create or replace function public.funnel_ve_equipo(p_agente_id bigint default null) returns setof bigint
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  with recursive raiz as (
    select case
      when p_agente_id is null then public.funnel_mi_agente()
      when public.funnel_es_gerente() then p_agente_id
      when p_agente_id = public.funnel_mi_agente() then p_agente_id
      else null end as id
  ),
  arbol as (
    select a.id, a.supervisor_id, array[a.id] as ruta
      from public.funnel_agentes a
     where a.id = (select id from raiz)
    union all
    select h.id, h.supervisor_id, t.ruta || h.id
      from public.funnel_agentes h
      join arbol t on h.supervisor_id = t.id
     where not (h.id = any(t.ruta))
  )
  select id from arbol
$$;
comment on function public.funnel_ve_equipo(bigint) is
  'Ids de funnel_agentes del subárbol (yo + los que me reportan). Sin id: arranca en funnel_mi_agente() (por cuenta, no por correo). Con id ajeno: solo gerentes. Cycle-safe.';

-- ── 2. un solo sistema de roles ────────────────────────────────────────────
alter table public.funnel_roles add column if not exists rol_operativo text;
comment on column public.funnel_roles.rol_operativo is
  'Rol de funnel_agentes que corresponde a este rol de cuenta (null = no trabaja como agente).';
update public.funnel_roles set rol_operativo = v.op
  from (values ('telemarketing','tmk'), ('supervisor_tmk','supervisor_tmk'), ('gerente_tmk','gerente_tmk'),
               ('vendedor','vendedor'), ('cerrador','cerrador'), ('digitador','digitador'),
               ('verificador','verificador')) as v(clave, op)
 where funnel_roles.clave = v.clave and funnel_roles.rol_operativo is null;

update public.funnel_roles set nombre = v.nom
  from (values ('recepcion','Hostess (recepción)'), ('vendedor','Liner (vendedor)'),
               ('cerrador','Closer (cerrador)'), ('verificador','Verificador de contratos')) as v(clave, nom)
 where funnel_roles.clave = v.clave;

-- Un agente atado a una cuenta tiene que tener el rol operativo de esa cuenta.
create or replace function public.funnel_agente_calza() returns trigger
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_rol_cuenta text; v_op text;
begin
  if new.user_id is null then return new; end if;
  select u.raw_app_meta_data->>'role' into v_rol_cuenta from auth.users u where u.id = new.user_id;
  select r.rol_operativo into v_op from public.funnel_roles r where r.clave = v_rol_cuenta;
  if v_op is null or v_op <> new.rol then
    raise exception 'el agente % tiene rol «%» pero su cuenta es «%» (le corresponde «%»)',
      new.id, new.rol, coalesce(v_rol_cuenta,'sin rol'), coalesce(v_op,'ninguno');
  end if;
  return new;
end $$;
drop trigger if exists trg_funnel_agente_calza on public.funnel_agentes;
create trigger trg_funnel_agente_calza before insert or update of user_id, rol on public.funnel_agentes
  for each row execute function public.funnel_agente_calza();

-- Lo que no calza se AVISA, no se borra: agentes sin cuenta, cuentas de equipo sin agente
-- y agentes cuyo rol ya no corresponde (p. ej. si a la cuenta le cambiaron el rol).
create or replace view public.funnel_equipo_descalces with (security_invoker = true) as
  select 'agente sin cuenta'::text as problema, a.id as agente_id, a.nombre, a.rol as rol_agente,
         null::text as rol_cuenta
    from public.funnel_agentes a where a.activo and a.user_id is null
  union all
  select 'rol de agente no calza con la cuenta', a.id, a.nombre, a.rol, u.raw_app_meta_data->>'role'
    from public.funnel_agentes a join auth.users u on u.id = a.user_id
    left join public.funnel_roles r on r.clave = u.raw_app_meta_data->>'role'
   where a.activo and r.rol_operativo is distinct from a.rol
  union all
  select 'cuenta de equipo sin agente', null, u.email, null, r.clave
    from auth.users u join public.funnel_roles r on r.clave = u.raw_app_meta_data->>'role'
   where r.rol_operativo is not null
     and not exists (select 1 from public.funnel_agentes a where a.user_id = u.id and a.activo);
-- security_invoker + solo gerentes: la vista lee auth.users, así que no se abre a nadie más.
revoke all on public.funnel_equipo_descalces from public, anon, authenticated;
create or replace function public.funnel_descalces() returns setof public.funnel_equipo_descalces
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select * from public.funnel_equipo_descalces where public.funnel_es_gerente()
$$;
revoke all on function public.funnel_descalces() from public, anon;
grant execute on function public.funnel_descalces() to authenticated;

-- ── 3. la matriz manda ──────────────────────────────────────────────────────
-- Un rol apagado no puede nada (antes funnel_puede ignoraba «activo»).
create or replace function public.funnel_puede(p text) returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select coalesce(
    (select pm.permitido from public.funnel_permisos pm
       join public.funnel_roles r on r.clave = pm.rol_clave and r.activo
      where pm.rol_clave = public.funnel_rol() and pm.permiso = p),
    false)
$$;

-- 3a. Alinear la matriz a lo que la base YA dejaba hacer (nadie gana ni pierde hoy).
create temp table _alineo(permiso text, rol text, permitido boolean) on commit drop;
insert into _alineo
  select 'ver_socios', r.clave, r.es_staff from public.funnel_roles r
  union all
  select 'editar_socios', r.clave, r.clave in ('admin','gerente_general','gerente_ventas') from public.funnel_roles r
  union all
  select 'crear_socios', r.clave, r.clave = 'admin' from public.funnel_roles r
  union all
  select 'borrar_socios', r.clave, r.clave = 'admin' from public.funnel_roles r
  union all
  select 'ver_comisiones', r.clave, r.es_gerente from public.funnel_roles r
  union all
  select 'gestionar_comisiones', r.clave, r.es_gerente from public.funnel_roles r
  union all
  select 'cerrar_contrato', r.clave,
         r.es_gerente or r.clave in ('vendedor','cerrador','digitador','verificador') from public.funnel_roles r;
insert into public.funnel_permisos(rol_clave, permiso, permitido)
  select rol, permiso, permitido from _alineo
  on conflict (rol_clave, permiso) do update set permitido = excluded.permitido;

-- 3b. socios
drop policy if exists socios_auth_select on public.socios;
create policy socios_auth_select on public.socios for select to authenticated
  using (public.funnel_puede('ver_socios')
         or id = nullif((auth.jwt() -> 'app_metadata') ->> 'socio_id', '')::bigint);
drop policy if exists socios_auth_update on public.socios;
create policy socios_auth_update on public.socios for update to authenticated
  using (public.funnel_puede('editar_socios')) with check (public.funnel_puede('editar_socios'));
drop policy if exists socios_admin_ins on public.socios;
create policy socios_admin_ins on public.socios for insert to authenticated
  with check (public.funnel_puede('crear_socios'));
drop policy if exists socios_admin_del on public.socios;
create policy socios_admin_del on public.socios for delete to authenticated
  using (public.funnel_puede('borrar_socios'));

-- 3c. comisiones: con el permiso se ven todas; sin él, cada agente ve LAS SUYAS.
drop policy if exists fcom_sel on public.funnel_comisiones;
create policy fcom_sel on public.funnel_comisiones for select to authenticated
  using (public.funnel_puede('ver_comisiones')
         or (public.funnel_es_staff() and beneficiario_id = public.funnel_mi_agente()));
drop policy if exists funnel_comision_reglas_wr on public.funnel_comision_reglas;
create policy funnel_comision_reglas_wr on public.funnel_comision_reglas for all to authenticated
  using (public.funnel_puede('gestionar_comisiones')) with check (public.funnel_puede('gestionar_comisiones'));

-- ── 4. prospectos y eventos: lo mío y lo de mi equipo, por cuenta ────────────
drop policy if exists fp_sel on public.funnel_prospectos;
create policy fp_sel on public.funnel_prospectos for select to authenticated
  using (public.funnel_ve_todo() or tmk_id in (select public.funnel_ve_equipo()));
drop policy if exists fp_upd on public.funnel_prospectos;
create policy fp_upd on public.funnel_prospectos for update to authenticated
  using (public.funnel_ve_todo() or tmk_id in (select public.funnel_ve_equipo()))
  with check (public.funnel_ve_todo() or tmk_id in (select public.funnel_ve_equipo()));
drop policy if exists fev_sel on public.funnel_eventos;
create policy fev_sel on public.funnel_eventos for select to authenticated
  using (exists (select 1 from public.funnel_prospectos p
                  where p.id = funnel_eventos.prospecto_id
                    and (public.funnel_es_gerente() or p.tmk_id in (select public.funnel_ve_equipo()))));

-- ── 5. cerrar contrato pregunta a la matriz (resto de la función, idéntico al vivo) ──
create or replace function public.funnel_cerrar_contrato(p_prospecto bigint, p_membresia text, p_plan text, p_monto numeric, p_vendedor bigint DEFAULT NULL::bigint, p_cerrador bigint DEFAULT NULL::bigint, p_digitador bigint DEFAULT NULL::bigint, p_verificador bigint DEFAULT NULL::bigint, p_anios integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cid bigint; pr record; rg record; benef bigint; base numeric;
  v_socio bigint; v_no text; v_liner text; v_closer text; v_yo bigint;
begin
  -- Antes: funnel_ve_todo() (incluía recepcion/reservaciones/servicio, sin ningún
  -- motivo de negocio para cerrar contratos). Ahora: solo gerentes o quien realmente
  -- participa del cierre.
  if not funnel_puede('cerrar_contrato') then
    raise exception 'no autorizado';
  end if;

  select * into pr from funnel_prospectos where id=p_prospecto for update;
  if pr.id is null then raise exception 'prospecto no existe'; end if;

  -- Idempotencia (nuevo, hallazgo de la revisión): cerrar el MISMO prospecto dos veces
  -- generaba un 2do contrato y un 2do juego de comisiones (doble pago). Se bloquea si
  -- ya está en etapa socio o ya tiene contrato firmado (un contrato anulado sí permite
  -- volver a cerrar).
  if pr.etapa = 'socio' or exists (select 1 from funnel_contratos where prospecto_id = p_prospecto and estado = 'firmado') then
    raise exception 'prospecto ya cerrado';
  end if;

  -- Anti-fraude (nuevo): cada beneficiario debe ser un agente REAL, activo, con el rol
  -- que corresponde a ese puesto — el mismo filtro que ya aplica el combo del CRM
  -- (opAgentes(rol) en embudo.html), pero hecho cumplir server-side: un RPC directo
  -- con una sesión válida puede saltarse el combo del navegador.
  if p_vendedor is not null and not exists (select 1 from funnel_agentes where id=p_vendedor and activo and rol='vendedor') then
    raise exception 'vendedor invalido';
  end if;
  if p_cerrador is not null and not exists (select 1 from funnel_agentes where id=p_cerrador and activo and rol='cerrador') then
    raise exception 'cerrador invalido';
  end if;
  if p_digitador is not null and not exists (select 1 from funnel_agentes where id=p_digitador and activo and rol='digitador') then
    raise exception 'digitador invalido';
  end if;
  if p_verificador is not null and not exists (select 1 from funnel_agentes where id=p_verificador and activo and rol='verificador') then
    raise exception 'verificador invalido';
  end if;

  -- Anti-autoasignación (nuevo): si no sos gerente, tenés que aparecer VOS MISMO en
  -- al menos uno de los 4 roles del contrato que estás cerrando — no podés rutear el
  -- 100% de las comisiones a otras personas sin aparecer en ningún lado.
  if not funnel_es_gerente() then
    select id into v_yo from funnel_agentes where user_id = auth.uid() and activo limit 1;
    if v_yo is null or v_yo not in (coalesce(p_vendedor,-1), coalesce(p_cerrador,-1), coalesce(p_digitador,-1), coalesce(p_verificador,-1)) then
      raise exception 'debes aparecer como uno de los roles del contrato que cerras';
    end if;
  end if;

  insert into funnel_contratos(prospecto_id,tipo_membresia,plan_pago,monto,tmk_id,vendedor_id,cerrador_id,digitador_id,verificador_id,estado)
    values(p_prospecto,p_membresia,p_plan,p_monto,pr.tmk_id,p_vendedor,p_cerrador,p_digitador,p_verificador,'firmado') returning id into cid;
  update funnel_prospectos set etapa='socio', vendedor_id=p_vendedor, cerrador_id=p_cerrador, actualizado_en=now() where id=p_prospecto;
  -- Auditoría (nuevo): quién lo cerró REALMENTE, más allá de los params — cierra
  -- el pedido de la auditoría ("loggear el caller, actor=email").
  insert into funnel_eventos(prospecto_id,tipo,actor,payload)
    values(p_prospecto,'contrato', coalesce(nullif(auth.jwt()->>'email',''),'sistema'),
           jsonb_build_object('contrato_id',cid,'membresia',p_membresia,'monto',p_monto));

  if pr.socio_id is null then
    perform pg_advisory_xact_lock(hashtext('socios_no_socio'));
    select nombre into v_liner  from funnel_agentes where id=p_vendedor;
    select nombre into v_closer from funnel_agentes where id=p_cerrador;
    v_no := (coalesce((select max((no_socio)::int) from socios where no_socio ~ '^[0-9]{3,5}$'),3906) + 1)::text;
    insert into socios(no_socio,nombre,celular,tipo,tipo_norm,total_texto,total_num,fecha_ingreso,vencimiento,anios_servicio,liner,closer,closer_norm)
      values(v_no, pr.nombre, nullif(regexp_replace(coalesce(pr.telefono,''),'[^0-9]','','g'),''),
             p_membresia, p_membresia, p_monto::text, p_monto, current_date,
             (current_date + (coalesce(p_anios,4)::text || ' years')::interval)::date,
             coalesce(p_anios,4), v_liner, v_closer, v_closer) returning id into v_socio;
    update funnel_prospectos set socio_id=v_socio where id=p_prospecto;
  else
    v_socio := pr.socio_id; select no_socio into v_no from socios where id=v_socio;
  end if;
  update funnel_contratos set socio_id=v_socio where id=cid;

  for rg in select * from funnel_comision_reglas where activo and (tipo_membresia is null or tipo_membresia=p_membresia) loop
    benef := case rg.rol
      when 'tmk' then pr.tmk_id when 'vendedor' then p_vendedor when 'cerrador' then p_cerrador
      when 'digitador' then p_digitador when 'verificador' then p_verificador
      when 'supervisor_tmk' then (select supervisor_id from funnel_agentes where id=pr.tmk_id) else null end;
    base := coalesce(rg.monto_fijo,0) + coalesce(rg.tasa,0)/100.0 * coalesce(p_monto,0);
    if base > 0 then insert into funnel_comisiones(contrato_id,rol,beneficiario_id,regla_id,monto) values(cid,rg.rol,benef,rg.id,round(base,2)); end if;
  end loop;

  return jsonb_build_object('contrato_id',cid,'socio_id',v_socio,'no_socio',v_no);
end
$function$

;

commit;
