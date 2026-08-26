-- ═══════════════════════════════════════════════════════════════════════════════
-- KUXTAL · MAESTRO DE DATOS — el CRM aprende de dónde viene cada persona
-- (George, 25-ago-2026: "decisión 2: sí, de clase mundial")
--
-- NO APLICADA. La aplica George (Nivel 2: estructura + RLS). Comando exacto al pie.
--
-- Qué hace, y por qué EXTIENDE en vez de crear tablas nuevas:
--   El CRM ya tiene funnel_bases, funnel_prospectos, funnel_estados, roles y reparto,
--   todos vacíos y esperando datos. Crear "prospectos" al lado sería tener dos verdades.
--   Esta migración les agrega lo que el maestro necesita y nada más.
--
--   1. funnel_bases        + cédula de la base (dueño, proveedor, costo, consentimiento…)
--   2. funnel_prospectos   + identidad (DPI, alternos), perfil (segmento, ingreso),
--                            linaje (de qué bases vino), legal (no_llamar, consentimiento)
--                          + UNICIDAD por teléfono (una persona = una fila)
--   3. funnel_no_llamar    NUEVA. Lista permanente. Trigger que bloquea al prospecto.
--                            Candado: nadie la revierte, nadie la borra.
--   4. funnel_gestiones    NUEVA. Cada llamada con su código: es lo que mide a la base.
--   5. funnel_estados      + los códigos de resultado que faltaban (aditivo).
--   6. funnel_desempeno_bases  VISTA. El ROI por base, calculado solo.
--   7. RLS con las funciones que YA existen (funnel_es_staff / funnel_es_gerente).
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── 1. funnel_bases: la cédula ────────────────────────────────────────────────
alter table public.funnel_bases
  add column if not exists codigo            text,           -- KX-0001 (id del catálogo maestro)
  add column if not exists archivo_origen    text,
  add column if not exists origen            text,           -- de quién es: PROMERICA, BAC, CENSO…
  add column if not exists dueno             text,           -- persona responsable (Data Steward la llena)
  add column if not exists proveedor         text,
  add column if not exists costo             numeric,
  add column if not exists fecha_adquisicion date,
  add column if not exists consentimiento    text not null default 'DESCONOCIDO'
                                             check (consentimiento in ('SI','NO','DESCONOCIDO')),
  add column if not exists uso_permitido     text default 'TMK',
  add column if not exists telefonos_unicos  integer,
  add column if not exists personas_nuevas   integer,        -- las que no estaban en ninguna otra base
  add column if not exists calidad           integer check (calidad between 0 and 100),
  add column if not exists estado_catalogo   text default 'CANDIDATO-INGESTA';
create unique index if not exists uq_funnel_bases_codigo on public.funnel_bases (codigo) where codigo is not null;
comment on column public.funnel_bases.consentimiento is
  'Política P1/P3: una base con consentimiento=NO no se asigna. DESCONOCIDO se trata como pendiente, nunca como SÍ.';

-- ── 2. funnel_prospectos: identidad, perfil, linaje, legal ───────────────────
alter table public.funnel_prospectos
  add column if not exists dpi               text,
  add column if not exists telefonos_alt     text[] not null default '{}',
  add column if not exists tipo_linea        text check (tipo_linea in ('MOVIL','FIJO')),
  add column if not exists direccion         text,
  add column if not exists municipio         text,
  add column if not exists departamento      text,
  add column if not exists genero            text check (genero in ('M','F','X')),
  add column if not exists ocupacion         text,
  add column if not exists ingreso_estimado  numeric,
  add column if not exists banco             text,
  add column if not exists segmento          text check (segmento in ('A','B','C','D')),
  add column if not exists calidad_registro  integer check (calidad_registro between 0 and 100),
  add column if not exists fuentes_todas     text[] not null default '{}',   -- códigos KX- de TODAS las bases donde apareció
  add column if not exists n_fuentes         integer not null default 1,
  add column if not exists disposicion_previa text,                          -- lo que dijo en bases viejas, ya traducido
  add column if not exists consentimiento    text not null default 'DESCONOCIDO'
                                             check (consentimiento in ('SI','NO','DESCONOCIDO')),
  add column if not exists no_llamar         boolean not null default false,
  add column if not exists intentos          integer not null default 0;

-- Teléfono canónico: 8 dígitos GT, sin +502 ni separadores. Se valida al entrar.
alter table public.funnel_prospectos drop constraint if exists fp_tel_gt;
alter table public.funnel_prospectos
  add constraint fp_tel_gt check (telefono ~ '^[2-7][0-9]{7}$') not valid;   -- not valid: no rompe filas viejas si las hubiera
-- UNA PERSONA = UNA FILA (Política P2). Es la llave natural del registro dorado.
create unique index if not exists uq_fp_telefono on public.funnel_prospectos (telefono);
create index if not exists ix_fp_dpi       on public.funnel_prospectos (dpi) where dpi is not null;
create index if not exists ix_fp_segmento  on public.funnel_prospectos (segmento, calidad_registro desc);
create index if not exists ix_fp_cola      on public.funnel_prospectos (estado, recontacto_en) where no_llamar = false;
create index if not exists ix_fp_alt       on public.funnel_prospectos using gin (telefonos_alt);
comment on column public.funnel_prospectos.fuentes_todas is
  'Linaje. fuentes_todas[1] es la PRIMERA base que trajo a esta persona = a quién se le atribuye (Decisión 4, George 25-ago). base_id apunta a esa misma.';

-- ── 3. funnel_no_llamar: la lista sagrada ────────────────────────────────────
create table if not exists public.funnel_no_llamar (
  telefono       text primary key check (telefono ~ '^[2-7][0-9]{7}$'),
  motivo         text not null,          -- 'pidio_no_ser_contactado' | 'menor_edad' | 'fallecido' | 'legal'
  origen         text,                   -- quién lo pidió / por qué canal
  registrado_por text default coalesce(auth.jwt() ->> 'email', 'sistema'),
  registrado_en  timestamptz not null default now()
);
comment on table public.funnel_no_llamar is
  'Política P3. Permanente e irreversible: no hay UPDATE ni DELETE posibles (candado por trigger). Si alguien entra por error, se corrige en la conversación con la persona, no borrando la fila.';

-- 3a. Al entrar a la lista: el prospecto queda bloqueado, sin TMK, fuera de toda cola.
create or replace function public.funnel_nl_aplicar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.funnel_prospectos
     set no_llamar = true, estado = 'no_llamar', tmk_id = null, recontacto_en = null,
         actualizado_en = now()
   where telefono = new.telefono or new.telefono = any(telefonos_alt);
  return new;
end $$;
drop trigger if exists trg_nl_aplicar on public.funnel_no_llamar;
create trigger trg_nl_aplicar after insert on public.funnel_no_llamar
  for each row execute function public.funnel_nl_aplicar();

-- 3b. Candado 1: la lista no se edita ni se borra. Para nadie.
create or replace function public.funnel_nl_candado() returns trigger
language plpgsql as $$
begin
  raise exception 'NO LLAMAR es permanente (Política P3): no se puede % la fila de %', tg_op, coalesce(old.telefono, '?')
    using errcode = 'check_violation';
end $$;
drop trigger if exists trg_nl_candado on public.funnel_no_llamar;
create trigger trg_nl_candado before update or delete on public.funnel_no_llamar
  for each row execute function public.funnel_nl_candado();

-- 3c. Candado 2: a un prospecto bloqueado nadie le quita el bloqueo ni le asigna TMK.
create or replace function public.funnel_fp_candado_nl() returns trigger
language plpgsql as $$
begin
  if old.no_llamar and not new.no_llamar then
    raise exception 'NO LLAMAR es irreversible (Política P3). Teléfono %', old.telefono using errcode = 'check_violation';
  end if;
  if new.no_llamar and new.tmk_id is not null then
    raise exception 'Prospecto en NO LLAMAR no se puede asignar a un TMK. Teléfono %', new.telefono using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists trg_fp_candado_nl on public.funnel_prospectos;
create trigger trg_fp_candado_nl before update on public.funnel_prospectos
  for each row execute function public.funnel_fp_candado_nl();

-- 3d. Al INSERTAR un prospecto: si ya está en la lista, nace bloqueado. Y normaliza el teléfono.
create or replace function public.funnel_fp_antes_insertar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text;
begin
  t := regexp_replace(coalesce(new.telefono,''), '\D', '', 'g');
  t := ltrim(t, '0');
  if length(t) = 11 and left(t,3) = '502' then t := substr(t, 4); end if;
  new.telefono := t;
  if exists (select 1 from public.funnel_no_llamar n where n.telefono = new.telefono or n.telefono = any(new.telefonos_alt)) then
    new.no_llamar := true; new.estado := 'no_llamar'; new.tmk_id := null;
  end if;
  return new;
end $$;
drop trigger if exists trg_fp_antes_insertar on public.funnel_prospectos;
create trigger trg_fp_antes_insertar before insert on public.funnel_prospectos
  for each row execute function public.funnel_fp_antes_insertar();

-- ── 4. funnel_gestiones: cada llamada, con su código ─────────────────────────
create table if not exists public.funnel_gestiones (
  id             bigserial primary key,
  prospecto_id   bigint not null references public.funnel_prospectos(id) on delete cascade,
  base_id        bigint references public.funnel_bases(id),      -- copia de la base atribuida: mide a la base
  tmk_id         bigint references public.funnel_agentes(id),
  telefono_marcado text,                                        -- por cuál de sus números se llamó
  canal          text not null default 'llamada' check (canal in ('llamada','whatsapp','sms','presencial')),
  disposicion    text not null references public.funnel_estados(clave),
  cita_en        timestamptz,
  asistio        boolean,
  notas          text,
  duracion_seg   integer,
  creado_por     text default coalesce(auth.jwt() ->> 'email', 'sistema'),
  creado_en      timestamptz not null default now()
);
create index if not exists ix_fg_base  on public.funnel_gestiones (base_id, disposicion);
create index if not exists ix_fg_prosp on public.funnel_gestiones (prospecto_id, creado_en desc);
create index if not exists ix_fg_tmk   on public.funnel_gestiones (tmk_id, creado_en desc);

-- 4a. Cada gestión actualiza al prospecto: estado, intentos, próxima acción. Y si dice NO LLAMAR, lo mete a la lista.
create or replace function public.funnel_fg_aplicar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare e record; p record;
begin
  select * into e from public.funnel_estados where clave = new.disposicion;
  select * into p from public.funnel_prospectos where id = new.prospecto_id;
  if new.base_id is null then new.base_id := p.base_id; end if;
  if new.disposicion = 'no_llamar' then
    insert into public.funnel_no_llamar (telefono, motivo, origen)
      values (p.telefono, 'pidio_no_ser_contactado', 'gestion #' || new.id || ' por ' || coalesce(new.creado_por,'?'))
      on conflict do nothing;
    return new;   -- el trigger de la lista ya bloqueó al prospecto
  end if;
  update public.funnel_prospectos
     set estado        = new.disposicion,
         intentos      = intentos + 1,
         recontacto_en = case
             when new.disposicion in ('no_contesta','buzon','ocupado') then now() + interval '4 hours'
             when new.disposicion = 'colgo'                              then now() + interval '1 day'
             when new.disposicion = 'no_interesado'                      then now() + interval '90 days'
             when new.disposicion = 'recontactar'                        then coalesce(new.cita_en, now() + interval '1 day')
             when new.disposicion = 'interesado'                         then now() + interval '7 days'
             when new.disposicion = 'no_asistio'                         then now() + interval '2 days'
             else null end,
         presenta_en   = coalesce(new.cita_en, presenta_en),
         etapa         = coalesce(e.sig_etapa, etapa),
         actualizado_en = now()
   where id = new.prospecto_id;
  return new;
end $$;
drop trigger if exists trg_fg_aplicar on public.funnel_gestiones;
create trigger trg_fg_aplicar before insert on public.funnel_gestiones
  for each row execute function public.funnel_fg_aplicar();

-- ── 5. funnel_estados: los códigos que faltaban (aditivo, no toca los 7 vivos) ──
insert into public.funnel_estados (clave, etiqueta, color, orden, cuenta_como, dispara_recontacto, sig_etapa, activo) values
  ('buzon',            'Buzón de voz',        '#9E9E9E', 31, 'contactado', false, null, true),
  ('ocupado',          'Ocupado',             '#9E9E9E', 32, null,         false, null, true),
  ('colgo',            'Colgó',               '#9E9E9E', 33, 'contactado', false, null, true),
  ('no_asistio',       'No asistió',          '#FF9800', 61, 'asiste',     true,  null, true),
  ('asistio',          'Asistió',             '#4CAF50', 62, 'asiste',     false, 'sala', true),
  ('no_califica',      'No califica',         '#795548', 71, 'descartado', false, null, true),
  ('numero_errado',    'Número errado',       '#B71C1C', 80, 'dato_malo',  false, null, true),
  ('fuera_de_servicio','Fuera de servicio',   '#B71C1C', 81, 'dato_malo',  false, null, true),
  ('fax_datos',        'Fax / datos',         '#B71C1C', 82, 'dato_malo',  false, null, true),
  ('menor_edad',       'Menor de edad',       '#B71C1C', 83, 'descartado', false, null, true),
  ('fallecido',        'Fallecido',           '#000000', 84, 'descartado', false, null, true),
  ('no_llamar',        'NO LLAMAR (permanente)', '#000000', 99, 'descartado', false, null, true)
on conflict (clave) do nothing;

-- ── 6. La vista que mide cada base ───────────────────────────────────────────
create or replace view public.funnel_desempeno_bases as
select
  b.id, b.codigo, b.nombre, b.origen, b.dueno, b.proveedor, b.costo, b.consentimiento,
  b.telefonos_unicos                                             as entregados,
  b.personas_nuevas,
  count(distinct g.prospecto_id)                                 as marcados,
  count(g.id)                                                    as llamadas,
  count(g.id) filter (where e.cuenta_como in ('contactado','interesado','asiste','descartado')
                        and g.disposicion not in ('no_contesta','buzon','ocupado','colgo')) as contacto_efectivo,
  count(g.id) filter (where e.cuenta_como = 'dato_malo')         as dato_malo,
  count(g.id) filter (where g.disposicion = 'asistira')          as citas,
  count(g.id) filter (where g.disposicion = 'asistio' or g.asistio) as asistieron,
  (select count(*) from public.funnel_contratos c join public.funnel_prospectos p2 on p2.id = c.prospecto_id
     where p2.base_id = b.id and c.estado <> 'anulado')          as ventas,
  round(100.0 * count(distinct g.prospecto_id) / nullif(b.telefonos_unicos,0), 1)            as pct_penetracion,
  round(100.0 * count(g.id) filter (where e.cuenta_como = 'dato_malo') / nullif(count(g.id),0), 1) as pct_dato_malo,
  round(b.costo / nullif(b.personas_nuevas,0), 2)                as costo_por_persona_nueva,
  case when count(g.id) filter (where e.cuenta_como = 'dato_malo') > 0.15 * nullif(count(g.id),0)
       then 'QUEMADA' else 'OK' end                              as veredicto_p6
from public.funnel_bases b
left join public.funnel_gestiones g on g.base_id = b.id
left join public.funnel_estados   e on e.clave = g.disposicion
group by b.id;
comment on view public.funnel_desempeno_bases is
  'Hoja 05 del catálogo maestro, calculada sola. P6: >15% dato malo = QUEMADA, se retira y se reclama al proveedor.';

-- ── 7. RLS: mismas funciones que ya gobiernan el CRM ─────────────────────────
alter table public.funnel_no_llamar enable row level security;
alter table public.funnel_gestiones enable row level security;
-- Lista NO LLAMAR: todo el staff la ve (para no marcar), todo el staff puede AGREGAR. Nadie edita ni borra (trigger).
drop policy if exists fnl_sel on public.funnel_no_llamar;
create policy fnl_sel on public.funnel_no_llamar for select using (funnel_es_staff());
drop policy if exists fnl_ins on public.funnel_no_llamar;
create policy fnl_ins on public.funnel_no_llamar for insert with check (funnel_es_staff());
-- Gestiones: el TMK ve y registra las de SUS prospectos; gerencia y los roles de funnel_ve_todo(), todas.
drop policy if exists fg_sel on public.funnel_gestiones;
create policy fg_sel on public.funnel_gestiones for select using (
  funnel_ve_todo() or exists (select 1 from public.funnel_prospectos p join public.funnel_agentes a on a.id = p.tmk_id
                               where p.id = funnel_gestiones.prospecto_id and lower(a.email) = lower(auth.jwt() ->> 'email')));
drop policy if exists fg_ins on public.funnel_gestiones;
create policy fg_ins on public.funnel_gestiones for insert with check (
  funnel_ve_todo() or exists (select 1 from public.funnel_prospectos p join public.funnel_agentes a on a.id = p.tmk_id
                               where p.id = funnel_gestiones.prospecto_id and lower(a.email) = lower(auth.jwt() ->> 'email')));
-- Gestiones no se editan ni se borran: son bitácora.
grant select, insert on public.funnel_gestiones to authenticated;
grant select, insert on public.funnel_no_llamar to authenticated;
grant usage, select on sequence public.funnel_gestiones_id_seq to authenticated;
grant select on public.funnel_desempeno_bases to authenticated;
-- La vista respeta RLS de las tablas base (security_invoker) — nadie ve por la vista lo que no ve por la tabla.
alter view public.funnel_desempeno_bases set (security_invoker = on);

-- ═══════════════════════════════════════════════════════════════════════════════
-- CÓMO SE APLICA (George):
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260825_maestro_de_datos.sql').read()}))")
-- Después, la prueba del candado: supabase/qa/probar_maestro_de_datos.sql (corre en transacción y hace ROLLBACK).
-- ═══════════════════════════════════════════════════════════════════════════════
