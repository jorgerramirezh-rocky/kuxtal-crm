-- ============================================================================
-- BLOQUE 1 · PASO 3 · dar de alta personas desde el panel (18/19-sep-2026)
--
-- La función `kuxtal-personas` (supabase/functions/kuxtal-personas) crea la cuenta en
-- Auth y le manda a la persona un enlace para crear SU clave. Esta migración pone la
-- parte de la base:
--   · el permiso «gestionar_personas» (hoy solo admin; George lo reparte en la matriz);
--   · la bitácora: quién hizo qué a quién, y cuándo (nadie la escribe desde afuera);
--   · funnel_personas_puedo()  → lo que el panel necesita saber de quien llama;
--   · funnel_personas_listar() → las cuentas del equipo, solo con el permiso;
--   · funnel_personas_registrar() → SOLO la función (rol de servicio): ata o suelta el
--     agente, cierra sesiones y anota en la bitácora, todo en la misma transacción.
-- Re-ejecutable. Nada de esto cambia lo que hoy ve cada rol.
-- ============================================================================
begin;

-- ── permiso nuevo: solo admin ──────────────────────────────────────────────
insert into public.funnel_permisos(rol_clave, permiso, permitido)
  select r.clave, 'gestionar_personas', r.clave = 'admin' from public.funnel_roles r
  on conflict (rol_clave, permiso) do nothing;

-- ── bitácora ───────────────────────────────────────────────────────────────
create table if not exists public.funnel_personas_bitacora (
  id bigint generated always as identity primary key,
  actor uuid not null,
  persona uuid not null,
  accion text not null check (accion in ('alta','restablecer','cambiar_rol','desactivar','activar')),
  detalle jsonb not null default '{}'::jsonb,
  creado_en timestamptz not null default now()
);
comment on table public.funnel_personas_bitacora is
  'Quién dio de alta, cambió de rol, desactivó o reenvió el enlace a quién. Solo la escribe funnel_personas_registrar (función kuxtal-personas).';
alter table public.funnel_personas_bitacora enable row level security;
drop policy if exists fpb_sel on public.funnel_personas_bitacora;
create policy fpb_sel on public.funnel_personas_bitacora for select to authenticated
  using (public.funnel_puede('gestionar_personas'));
revoke insert, update, delete, truncate on public.funnel_personas_bitacora from public, anon, authenticated;
grant select on public.funnel_personas_bitacora to authenticated;

-- ── lo que el panel necesita saber de quien llama ─────────────────────────
create or replace function public.funnel_personas_puedo() returns jsonb
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select jsonb_build_object(
    'puede', public.funnel_puede('gestionar_personas'),
    'nivel', public.funnel_nivel(),
    'rol',   public.funnel_rol(),
    'uid',   auth.uid())
$$;
revoke all on function public.funnel_personas_puedo() from public, anon;
grant execute on function public.funnel_personas_puedo() to authenticated, service_role;

-- ── la lista: cuentas del equipo (staff o sin rol), nunca las de socios ───
drop function if exists public.funnel_personas_listar();
create function public.funnel_personas_listar()
  returns table(user_id uuid, correo text, nombre text, rol text, rol_nombre text, nivel int,
                activo boolean, agente_id bigint, jefe_id bigint, creado_en timestamptz, ultimo_ingreso timestamptz)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not (public.funnel_puede('gestionar_personas') or auth.role() = 'service_role') then
    raise exception 'no autorizado' using errcode = 'KXP01';
  end if;
  return query
    select u.id, u.email::text,
           coalesce(ag.nombre, nullif(u.raw_user_meta_data->>'nombre',''), split_part(u.email::text,'@',1)),
           r.clave, r.nombre, r.nivel,
           (u.banned_until is null or u.banned_until < now()),
           ag.id, ag.supervisor_id, u.created_at, u.last_sign_in_at
      from auth.users u
      left join public.funnel_roles r on r.clave = u.raw_app_meta_data->>'role'
      left join lateral (select a.id, a.nombre, a.supervisor_id from public.funnel_agentes a
                          where a.user_id = u.id and a.activo order by a.id desc limit 1) ag on true
     where coalesce(r.es_staff, true)
     order by coalesce(r.nivel, -1) desc, 3;
end $$;
revoke all on function public.funnel_personas_listar() from public, anon;
grant execute on function public.funnel_personas_listar() to authenticated, service_role;

-- ── registrar: la parte de la base de cada acción (SOLO la función) ─────────
-- Antes de llamarla, la función ya dejó la cuenta como corresponde en Auth (rol,
-- clave o bloqueo). Acá se ajusta el equipo, se cierran sesiones y se anota.
-- Devuelve cuántas sesiones cerró. Frenos con código propio:
--   KXP02 la cuenta no tiene el rol que se dice · KXP03 el jefe no es un agente activo
--   KXP04 la persona no existe · 55000 sobre uno mismo
create or replace function public.funnel_personas_registrar(
  p_actor uuid, p_persona uuid, p_accion text,
  p_nombre text default null, p_rol text default null, p_jefe bigint default null)
  returns int
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_rol_cuenta text; v_correo text; v_op text; v_nombre text; v_jefe bigint; v_sesiones int := 0;
  v_ag record;
begin
  if p_actor = p_persona then raise exception 'sobre uno mismo no' using errcode = '55000'; end if;
  select u.raw_app_meta_data->>'role', u.email::text into v_rol_cuenta, v_correo
    from auth.users u where u.id = p_persona;
  if not found then raise exception 'la persona no existe' using errcode = 'KXP04'; end if;
  if p_accion in ('alta','cambiar_rol') and v_rol_cuenta is distinct from p_rol then
    raise exception 'la cuenta tiene rol %, no %', v_rol_cuenta, p_rol using errcode = 'KXP02';
  end if;
  if p_jefe is not null and not exists (select 1 from public.funnel_agentes where id = p_jefe and activo) then
    raise exception 'el jefe % no es un agente activo', p_jefe using errcode = 'KXP03';
  end if;
  select r.rol_operativo into v_op from public.funnel_roles r where r.clave = v_rol_cuenta;
  select a.* into v_ag from public.funnel_agentes a where a.user_id = p_persona and a.activo order by a.id desc limit 1;

  if p_accion in ('alta','cambiar_rol') then
    v_nombre := coalesce(nullif(trim(p_nombre),''), v_ag.nombre, split_part(v_correo,'@',1));
    v_jefe := coalesce(p_jefe, v_ag.supervisor_id);
    -- El agente que ya no corresponde se da de baja (nunca se borra).
    update public.funnel_agentes set activo = false
     where user_id = p_persona and activo and rol is distinct from v_op;
    if v_op is not null then
      if exists (select 1 from public.funnel_agentes where user_id = p_persona and activo) then
        update public.funnel_agentes set nombre = v_nombre, supervisor_id = v_jefe
         where user_id = p_persona and activo;
      else
        insert into public.funnel_agentes(nombre, rol, email, user_id, supervisor_id, activo, peso)
          values (v_nombre, v_op, v_correo, p_persona, v_jefe, true, 1);
      end if;
    end if;
  elsif p_accion = 'desactivar' then
    update public.funnel_agentes set activo = false where user_id = p_persona and activo;
  elsif p_accion = 'activar' then
    -- Vuelve el agente más nuevo cuyo rol corresponde al de la cuenta, si no hay otro activo.
    if v_op is not null and not exists (select 1 from public.funnel_agentes where user_id = p_persona and activo) then
      update public.funnel_agentes set activo = true
       where id = (select max(id) from public.funnel_agentes where user_id = p_persona and rol = v_op);
    end if;
  elsif p_accion <> 'restablecer' then
    raise exception 'acción desconocida %', p_accion using errcode = '22023';
  end if;

  -- Rol nuevo, baja o clave nueva: las sesiones abiertas se cierran (el token viejo muere al vencer, ≤1 h).
  if p_accion in ('cambiar_rol','desactivar','restablecer') then
    delete from auth.sessions where user_id = p_persona;
    get diagnostics v_sesiones = row_count;
  end if;

  insert into public.funnel_personas_bitacora(actor, persona, accion, detalle)
    values (p_actor, p_persona, p_accion, jsonb_strip_nulls(jsonb_build_object(
      'rol', case when p_accion in ('alta','cambiar_rol') then p_rol end,
      'jefe', v_jefe, 'sesiones_cerradas', nullif(v_sesiones, 0))));
  return v_sesiones;
end $$;
revoke all on function public.funnel_personas_registrar(uuid, uuid, text, text, text, bigint) from public, anon, authenticated;
grant execute on function public.funnel_personas_registrar(uuid, uuid, text, text, text, bigint) to service_role;

commit;
