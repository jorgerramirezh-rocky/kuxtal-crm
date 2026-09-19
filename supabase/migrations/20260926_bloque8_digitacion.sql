-- ============================================================================
-- BLOQUE 8 · digitación: el digitador completa los datos del cliente y valida ANTES de imprimir
-- (George 19-sep; diseño aprobado con botón kuxb8dis:si)
--
-- Qué cambia:
--  1. El contrato nace «por digitar» (no «por verificar») y no se imprime al cerrar.
--  2. La gerencia de ventas asigna el digitador de cada contrato (como el verificador); solo ese
--     digitador lo ve y lo digita. Permiso nuevo «digitar_contratos».
--  3. Datos del cliente en una tabla aparte (DPI, nacimiento, dirección, correo, ocupación, cónyuge,
--     beneficiarios). Nada de números de tarjeta. Solo se lee y escribe por funciones.
--  4. «Validado · imprimir»: exige los datos mínimos, pasa a «por verificar» y crea la comisión del
--     digitador (pendiente). «Devolver» deja una nota para el closer y la gerencia.
--
-- Todo en una transacción. Re-ejecutable. Ensayado primero en una copia local (qa/rls).
-- ============================================================================
begin;

insert into public.funnel_permisos(rol_clave, permiso, permitido)
select r.clave, 'digitar_contratos', r.clave in ('admin', 'gerente_general', 'gerente_ventas', 'digitador')
  from public.funnel_roles r
on conflict do nothing;

alter table public.funnel_contratos drop constraint if exists funnel_contratos_estado_ck;
alter table public.funnel_contratos add constraint funnel_contratos_estado_ck
  check (estado in ('firmado', 'por_digitar', 'por_verificar', 'observado', 'verificado', 'cancelado'));
alter table public.funnel_contratos
  add column if not exists digitado_por text,
  add column if not exists digitado_en timestamptz,
  add column if not exists devolucion_nota text;

create table if not exists public.funnel_contrato_datos (
  contrato_id bigint primary key references public.funnel_contratos(id),
  dpi text check (dpi is null or dpi ~ '^[0-9]{13}$'),
  fecha_nacimiento date,
  direccion text check (char_length(coalesce(direccion, '')) <= 300),
  correo text check (correo is null or (correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(correo) <= 120)),
  ocupacion text check (char_length(coalesce(ocupacion, '')) <= 120),
  conyuge_nombre text check (char_length(coalesce(conyuge_nombre, '')) <= 120),
  beneficiarios jsonb not null default '[]'::jsonb check (jsonb_typeof(beneficiarios) = 'array' and jsonb_array_length(beneficiarios) <= 5),
  actualizado_por text,
  actualizado_en timestamptz not null default now()
);
comment on table public.funnel_contrato_datos is
  'Bloque 8: datos del cliente que completa el digitador antes de imprimir. Solo por funciones (sin tarjetas).';
alter table public.funnel_contrato_datos enable row level security;
revoke all on public.funnel_contrato_datos from public, anon, authenticated;

-- ¿Puede quien llama digitar ESTE contrato? (gerencia de ventas, o el digitador asignado)
create or replace function public.funnel_puede_digitar(c public.funnel_contratos) returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select not public.funnel_es_tmk() and public.funnel_puede('digitar_contratos')
     and (public.funnel_puede('corregir_sala')
          or (public.funnel_mi_agente() is not null and c.digitador_id is not distinct from public.funnel_mi_agente()))
$$;
revoke all on function public.funnel_puede_digitar(public.funnel_contratos) from public, anon, authenticated;

-- ── 0b. el enganche se anota DESPUÉS de cerrar: la política de edición tiene que aceptar «por digitar»
--      (sin esto el PATCH no tocaba ninguna fila y el enganche se perdía en silencio).
--      Lente r2: de las jefaturas, solo quien corrige la sala (no las de TMK) toca el enganche de un contrato ajeno.
drop policy if exists fcon_upd on public.funnel_contratos;
create policy fcon_upd on public.funnel_contratos for update to authenticated
  using (estado in ('firmado', 'por_digitar', 'por_verificar', 'observado')
         and (public.funnel_puede('corregir_sala') or public.funnel_mi_agente() in (vendedor_id, cerrador_id, digitador_id, verificador_id)))
  with check (estado in ('firmado', 'por_digitar', 'por_verificar', 'observado')
         and (public.funnel_puede('corregir_sala') or public.funnel_mi_agente() in (vendedor_id, cerrador_id, digitador_id, verificador_id)));

-- ── 1. el cierre: nace «por digitar»; la comisión del digitador nace al validar ──
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.funnel_cerrar_contrato(bigint,text,text,bigint,bigint,bigint,integer,bigint)'::regprocedure);
  if position('kux.b8' in d) = 0 then
    d := replace(d, $a$            'por_verificar', v_p, v_dm, s.id, v_ds,$a$,
                    $a$            /* kux.b8: primero lo digita el digitador */ 'por_digitar', v_p, v_dm, s.id, v_ds,$a$);
    d := replace(d, $a$  for rg in select * from funnel_comision_reglas g where g.activo and g.rol <> 'verificador'$a$,
                    $a$  for rg in select * from funnel_comision_reglas g where g.activo and g.rol not in ('verificador', 'digitador')   -- kux.b8$a$);
    d := replace(d, $a$  if p_digitador is not null and not exists$a$,
                    $a$  p_digitador := null;   /* kux.b8: el digitador lo asigna la gerencia, nunca quien cierra */
  if p_digitador is not null and not exists$a$);
    if (length(d) - length(replace(d, 'kux.b8', ''))) / 6 <> 3 then raise exception 'no encontré dónde parchar funnel_cerrar_contrato (bloque 8)'; end if;
    execute d;
  end if;
end $p$;

-- ── 2. asignar digitador ──────────────────────────────────────────────────
create or replace function public.funnel_contrato_asignar_digitador(p_id bigint, p_agente bigint)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  if public.funnel_es_tmk() or not public.funnel_puede('corregir_sala') then raise exception 'no autorizado'; end if;
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found then raise exception 'no autorizado'; end if;
  if c.estado <> 'por_digitar' then raise exception 'ese contrato ya no está por digitar'; end if;
  if not exists (select 1 from public.funnel_agentes a where a.id = p_agente and a.activo and a.rol = 'digitador') then
    raise exception 'esa persona no es un digitador activo';
  end if;
  if p_agente in (c.vendedor_id, c.cerrador_id, c.tmk_id) or p_agente is not distinct from c.verificador_id then
    raise exception 'ese digitador participa en la venta';
  end if;
  update public.funnel_contratos set digitador_id = p_agente where id = c.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'digitador_asignado', v_actor, jsonb_build_object('contrato_id', c.id, 'digitador_id', p_agente));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_contrato_asignar_digitador(bigint, bigint) from public, anon;
grant execute on function public.funnel_contrato_asignar_digitador(bigint, bigint) to authenticated;

-- ── 3. la cola de digitación ──────────────────────────────────────────────
drop function if exists public.funnel_contratos_por_digitar();
create or replace function public.funnel_contratos_por_digitar()
  returns table(id bigint, cliente text, telefono text, membresia text, plan_pago text, monto numeric, enganche numeric,
                liner text, closer text, digitador_id bigint, digitador text, devolucion_nota text, creado_en timestamptz,
                dpi text, fecha_nacimiento date, direccion text, correo text, ocupacion text, conyuge_nombre text, beneficiarios jsonb,
                no_socio text, anios int, precio_lista numeric, descuento numeric)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_todo boolean := public.funnel_puede('corregir_sala'); v_yo bigint := public.funnel_mi_agente();
begin
  if public.funnel_es_tmk() or not public.funnel_puede('digitar_contratos') then raise exception 'no autorizado'; end if;
  return query select c.id, p.nombre, p.telefono, c.tipo_membresia, c.plan_pago, c.monto, c.enganche,
         v.nombre, k.nombre, c.digitador_id, dg.nombre, c.devolucion_nota, c.creado_en,
         d.dpi, d.fecha_nacimiento, d.direccion, coalesce(d.correo, p.email), d.ocupacion, d.conyuge_nombre, coalesce(d.beneficiarios, '[]'::jsonb),
         so.no_socio, so.anios_servicio::int, c.precio_lista, coalesce(c.descuento_membresia, 0) + coalesce(c.descuento_monto, 0)
    from public.funnel_contratos c
    left join public.socios so on so.id = c.socio_id
    join public.funnel_prospectos p on p.id = c.prospecto_id
    left join public.funnel_contrato_datos d on d.contrato_id = c.id
    left join public.funnel_agentes v on v.id = c.vendedor_id
    left join public.funnel_agentes k on k.id = c.cerrador_id
    left join public.funnel_agentes dg on dg.id = c.digitador_id
   where c.estado = 'por_digitar' and (v_todo or (v_yo is not null and c.digitador_id = v_yo))
   order by (c.digitador_id is not null), c.creado_en limit 300;
end $$;
revoke all on function public.funnel_contratos_por_digitar() from public, anon;
grant execute on function public.funnel_contratos_por_digitar() to authenticated;

-- ── 4. digitar (guardar datos) ────────────────────────────────────────────
create or replace function public.funnel_contrato_digitar(p_id bigint, p_datos jsonb)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
  v_fn date; v_b jsonb := coalesce(p_datos->'beneficiarios', '[]'::jsonb); e jsonb;
begin
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found or not public.funnel_puede_digitar(c) then raise exception 'no autorizado'; end if;
  if c.estado <> 'por_digitar' then raise exception 'ese contrato ya no está por digitar'; end if;
  if jsonb_typeof(v_b) <> 'array' or jsonb_array_length(v_b) > 5 then raise exception 'hasta 5 beneficiarios'; end if;
  for e in select * from jsonb_array_elements(v_b) loop
    if jsonb_typeof(e) <> 'object' or char_length(coalesce(e->>'nombre', '')) not between 1 and 120
       or char_length(coalesce(e->>'parentesco', '')) > 60 then
      raise exception 'cada beneficiario necesita nombre (y parentesco corto)';
    end if;
  end loop;
  v_fn := nullif(p_datos->>'fecha_nacimiento', '')::date;
  if v_fn is not null and (v_fn > current_date - interval '18 years' or v_fn < current_date - interval '110 years') then
    raise exception 'la fecha de nacimiento no cuadra (18 a 110 años)';
  end if;
  insert into public.funnel_contrato_datos(contrato_id, dpi, fecha_nacimiento, direccion, correo, ocupacion, conyuge_nombre, beneficiarios, actualizado_por, actualizado_en)
  values (c.id, nullif(regexp_replace(coalesce(p_datos->>'dpi', ''), '[^0-9]', '', 'g'), ''), v_fn,
          nullif(btrim(coalesce(p_datos->>'direccion', '')), ''), nullif(lower(btrim(coalesce(p_datos->>'correo', ''))), ''),
          nullif(btrim(coalesce(p_datos->>'ocupacion', '')), ''), nullif(btrim(coalesce(p_datos->>'conyuge_nombre', '')), ''),
          coalesce((select jsonb_agg(jsonb_build_object('nombre', btrim(x->>'nombre'),
                                                  'parentesco', btrim(coalesce(x->>'parentesco', ''))))
                      from jsonb_array_elements(v_b) x), '[]'::jsonb),
          v_actor, now())
  on conflict (contrato_id) do update set dpi = excluded.dpi, fecha_nacimiento = excluded.fecha_nacimiento,
     direccion = excluded.direccion, correo = excluded.correo, ocupacion = excluded.ocupacion,
     conyuge_nombre = excluded.conyuge_nombre, beneficiarios = excluded.beneficiarios,
     actualizado_por = excluded.actualizado_por, actualizado_en = now();
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_contrato_digitar(bigint, jsonb) from public, anon;
grant execute on function public.funnel_contrato_digitar(bigint, jsonb) to authenticated;

-- ── 5. validar (pasa a verificación) o devolver ───────────────────────────
create or replace function public.funnel_contrato_validar(p_id bigint)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; d public.funnel_contrato_datos%rowtype; rg record; base numeric;
  v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found or not public.funnel_puede_digitar(c) then raise exception 'no autorizado'; end if;
  if c.estado <> 'por_digitar' then raise exception 'ese contrato ya no está por digitar'; end if;
  if c.digitador_id is null then raise exception 'primero la gerencia asigna el digitador'; end if;
  -- Lente r2: como en verificación, quien cerró o participa en la venta no valida su propio contrato.
  if lower(v_actor) = lower(coalesce(c.cerrado_por, ''))
     or coalesce(public.funnel_mi_agente() in (c.tmk_id, c.vendedor_id, c.cerrador_id), false) then
    raise exception 'quien cerró o vendió este contrato no lo valida';
  end if;
  select * into d from public.funnel_contrato_datos where contrato_id = c.id;
  if not found or d.dpi is null or d.fecha_nacimiento is null or d.direccion is null then
    raise exception 'faltan datos: DPI, fecha de nacimiento y dirección son obligatorios';
  end if;
  update public.funnel_contratos set estado = 'por_verificar', digitado_por = v_actor, digitado_en = now(), devolucion_nota = null
   where id = c.id;
  -- La comisión del digitador nace ahora, pendiente (se libera al verificar), a nombre del asignado —
  -- y SOLO si validó él (si valida la gerencia en su lugar, nadie cobra un trabajo que no hizo).
  if coalesce(public.funnel_mi_agente() = c.digitador_id, false) then
  for rg in select * from public.funnel_comision_reglas g where g.activo and g.rol = 'digitador'
                and (g.tipo_membresia = c.tipo_membresia
                     or (g.tipo_membresia is null and not exists (select 1 from public.funnel_comision_reglas e
                          where e.activo and e.rol = g.rol and e.tipo_membresia = c.tipo_membresia))) loop
    base := coalesce(rg.monto_fijo, 0) + coalesce(rg.tasa, 0) / 100.0 * coalesce(c.monto, 0);
    if base > 0 and not exists (select 1 from public.funnel_comisiones m where m.contrato_id = c.id and m.rol = 'digitador') then
      insert into public.funnel_comisiones(contrato_id, rol, beneficiario_id, regla_id, monto, estado)
      values (c.id, 'digitador', c.digitador_id, rg.id, round(base, 2), 'pendiente');
    end if;
  end loop;
  end if;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'digitado', v_actor, jsonb_build_object('contrato_id', c.id));
  return jsonb_build_object('estado', 'por_verificar');
end $$;
revoke all on function public.funnel_contrato_validar(bigint) from public, anon;
grant execute on function public.funnel_contrato_validar(bigint) to authenticated;

create or replace function public.funnel_contrato_devolver(p_id bigint, p_nota text)
  returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_actor text := left(coalesce(auth.jwt()->>'email', 'crm'), 120);
begin
  p_nota := nullif(left(btrim(coalesce(p_nota, '')), 300), '');
  if p_nota is null then raise exception 'escribí qué no cuadra'; end if;
  select * into c from public.funnel_contratos where id = p_id for update;
  if not found or not public.funnel_puede_digitar(c) then raise exception 'no autorizado'; end if;
  if c.estado <> 'por_digitar' then raise exception 'ese contrato ya no está por digitar'; end if;
  update public.funnel_contratos set devolucion_nota = p_nota where id = c.id;
  insert into public.funnel_eventos(prospecto_id, tipo, actor, payload)
  values (c.prospecto_id, 'digitacion_devuelta', v_actor, jsonb_build_object('contrato_id', c.id, 'nota', p_nota));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.funnel_contrato_devolver(bigint, text) from public, anon;
grant execute on function public.funnel_contrato_devolver(bigint, text) to authenticated;

-- Reimprimir (lente de diseño P0-2): los datos del contrato para imprimirlo otra vez. Gerencia de ventas,
-- el digitador y el verificador asignados. Con la fecha del CIERRE (no la del día en que se imprime).
create or replace function public.funnel_contrato_impresion(p_id bigint)
  returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare c public.funnel_contratos%rowtype; v_yo bigint := public.funnel_mi_agente(); r jsonb;
begin
  select * into c from public.funnel_contratos where id = p_id;
  if not found or public.funnel_es_tmk() or not (public.funnel_puede('corregir_sala')
       or coalesce(v_yo in (c.digitador_id, c.verificador_id), false)) then   -- coalesce: con un vacío, «no» (no «desconocido»)
    raise exception 'no autorizado';
  end if;
  if c.estado in ('por_digitar', 'cancelado') then raise exception 'ese contrato todavía no se puede imprimir'; end if;
  select jsonb_build_object('no_socio', so.no_socio, 'nombre', p.nombre, 'telefono', p.telefono, 'membresia', c.tipo_membresia,
         'plan', c.plan_pago, 'monto', c.monto, 'enganche', c.enganche, 'anios', so.anios_servicio, 'fecha', (c.creado_en at time zone 'America/Guatemala')::date,
         'vendedor', v.nombre, 'cerrador', k.nombre, 'digitador', dg.nombre, 'verificador', vf.nombre,
         'dpi', d.dpi, 'fecha_nacimiento', d.fecha_nacimiento, 'direccion', d.direccion, 'correo', d.correo,
         'ocupacion', d.ocupacion, 'conyuge', d.conyuge_nombre, 'beneficiarios', coalesce(d.beneficiarios, '[]'::jsonb))
    into r
    from public.funnel_prospectos p
    left join public.socios so on so.id = c.socio_id
    left join public.funnel_contrato_datos d on d.contrato_id = c.id
    left join public.funnel_agentes v on v.id = c.vendedor_id
    left join public.funnel_agentes k on k.id = c.cerrador_id
    left join public.funnel_agentes dg on dg.id = c.digitador_id
    left join public.funnel_agentes vf on vf.id = c.verificador_id
   where p.id = c.prospecto_id;
  return r;
end $$;
revoke all on function public.funnel_contrato_impresion(bigint) from public, anon;
grant execute on function public.funnel_contrato_impresion(bigint) to authenticated;

-- «Mis clientes»: el closer ve si el digitador le devolvió algo (nota incluida en el paso).
drop function if exists public.funnel_mis_clientes();
create or replace function public.funnel_mis_clientes()
  returns table(id bigint, nombre text, telefono text, restaurante_id bigint, presenta_en timestamptz,
                recepcion_en timestamptz, etapa text, mi_papel text, liner text, closer text,
                descuento text, contrato text, devolucion_nota text)
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_yo bigint := public.funnel_mi_agente();
begin
  if v_yo is null or public.funnel_rol() not in ('vendedor', 'cerrador') then raise exception 'no autorizado'; end if;
  return query select p.id, p.nombre, p.telefono, p.restaurante_id, p.presenta_en, p.recepcion_en, p.etapa,
         case when p.vendedor_id = v_yo then 'liner' else 'closer' end, v.nombre, k.nombre,
         (select s.estado from public.funnel_descuento_solicitudes s where s.prospecto_id = p.id order by s.id desc limit 1),
         (select c.estado from public.funnel_contratos c where c.prospecto_id = p.id order by c.id desc limit 1),
         (select c.devolucion_nota from public.funnel_contratos c where c.prospecto_id = p.id order by c.id desc limit 1)
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
