-- ═══════════════════════════════════════════════════════════════════════════════
-- KUXTAL · MAESTRO DE DATOS — v3 (tras 2 rondas adversarias: 36 + 12 hallazgos)
-- (George, 25-ago-2026: "decisión 2: sí, de clase mundial")
--
-- NO APLICADA. La aplica George (Nivel 2: estructura + RLS). Comando exacto al pie.
-- Corre ENTERA en una transacción: si algo falla, no queda nada a medias.
--
-- Principios que salieron de la revisión:
--   · Una sola verdad: se EXTIENDE funnel_bases / funnel_prospectos / funnel_estados (ya existen).
--   · Mínimo dato (P9): lo sensible (DPI, ingreso, dirección, banco) y la cédula comercial
--     (costo, proveedor) viven en tablas hijas que SOLO gerencia lee. El TMK ve nombre y teléfono.
--   · NO LLAMAR: solo entra por una gestión del TMK dueño o por gerencia. Nadie la lee salvo
--     gerencia. No se edita ni se borra… salvo RECTIFICACIÓN auditada de gerencia (10 min).
--   · Un alterno compartido NO bloquea a terceros solo: los marca para revisar (regla: ambiguo → alertar).
--   · El TMK no manda tmk_id/base_id/creado_por: los pone el servidor desde el JWT.
--   · Los tiempos y topes viven en funnel_estados / funnel_parametros, no en el trigger.
--   · El motor de gestiones se conecta al volante: la pantalla vieja (PATCH estado) también
--     genera gestión (puente), y Recepción genera 'asistio' sola.
-- ═══════════════════════════════════════════════════════════════════════════════
begin;

-- ── 0a. normalizador ÚNICO de teléfono (A12 #6): todos los caminos usan esta función ──
create or replace function public.funnel_tel_norm(p text) returns text language sql immutable as
$$ select nullif(case when length(t) = 11 and left(t,3) = '502' then substr(t,4) else t end, '')
   from (select ltrim(regexp_replace(coalesce(p,''), '\D', '', 'g'), '0') t) s $$;
grant execute on function public.funnel_tel_norm(text) to authenticated;

-- ── 0. parámetros del negocio (editables por gerencia, no hardcode) ─────────
create table if not exists public.funnel_parametros (
  clave  text primary key,
  valor  text not null,
  nota   text
);
insert into public.funnel_parametros (clave, valor, nota) values
  ('tope_intentos_persona', '7',  'Intentos totales por persona antes de AGOTADO'),
  ('tope_intentos_numero',  '2',  'Sin-contacto seguidos por número antes de saltar al siguiente'),
  ('tope_no_llamar_hora',   '50', 'Altas a NO LLAMAR por actor y hora, por CUALQUIER camino (anti-sabotaje)'),
  ('tope_no_llamar_ingesta','5000','Altas a NO LLAMAR permitidas por lote de ingesta (bases con NO_LLAMAR previo)'),
  ('ingesta_max_lote',     '2000','Filas máximas por llamada a funnel_ingestar'),
  ('min_muestra_quemada',   '100','Llamadas mínimas para declarar una base QUEMADA'),
  ('pct_dato_malo_quemada', '15', 'Porcentaje de dato malo que quema una base (P6)')
on conflict (clave) do nothing;
alter table public.funnel_parametros enable row level security;
drop policy if exists fpar_sel on public.funnel_parametros;
create policy fpar_sel on public.funnel_parametros for select to authenticated using (funnel_es_staff());
drop policy if exists fpar_wr on public.funnel_parametros;
create policy fpar_wr on public.funnel_parametros for all to authenticated using (funnel_es_gerente()) with check (funnel_es_gerente());
grant select on public.funnel_parametros to authenticated;
grant insert, update on public.funnel_parametros to authenticated;
create or replace function public.funnel_param(p text, d integer) returns integer
language sql stable security definer set search_path = public, pg_temp as
$$ select case when funnel_es_staff() or auth.jwt() is null then coalesce((select valor::int from public.funnel_parametros where clave = p), d) else d end $$;
revoke all on function public.funnel_param(text, integer) from public, anon;
grant execute on function public.funnel_param(text, integer) to authenticated;

-- ── 1. funnel_bases: lo operativo en la base; la cédula comercial en tabla hija (gerencia) ──
alter table public.funnel_bases
  add column if not exists codigo            text,
  add column if not exists origen            text,
  add column if not exists consentimiento    text not null default 'DESCONOCIDO'
                                             check (consentimiento in ('SI','NO','DESCONOCIDO')),
  add column if not exists telefonos_unicos  integer,
  add column if not exists personas_nuevas   integer,
  add column if not exists calidad           integer check (calidad between 0 and 100),
  add column if not exists estado_catalogo   text default 'CANDIDATO-INGESTA';
create unique index if not exists uq_funnel_bases_codigo on public.funnel_bases (codigo) where codigo is not null;

create table if not exists public.funnel_bases_cedula (
  base_id           bigint primary key references public.funnel_bases(id) on delete cascade,
  archivo_origen    text,
  dueno             text,
  proveedor         text,
  costo             numeric,
  fecha_adquisicion date,
  uso_permitido     text default 'TMK',
  actualizado_en    timestamptz default now()
);
alter table public.funnel_bases_cedula enable row level security;
drop policy if exists fbc_sel on public.funnel_bases_cedula;
create policy fbc_sel on public.funnel_bases_cedula for select to authenticated using (funnel_es_gerente());
drop policy if exists fbc_wr on public.funnel_bases_cedula;
create policy fbc_wr on public.funnel_bases_cedula for all to authenticated using (funnel_es_gerente()) with check (funnel_es_gerente());
grant select, insert, update on public.funnel_bases_cedula to authenticated;
comment on table public.funnel_bases_cedula is 'Cédula comercial de la base (P1). Solo gerencia. Una base sin cédula no se asigna.';

-- ── 2. funnel_prospectos: identidad, perfil operativo, linaje, legal ─────────
alter table public.funnel_prospectos
  add column if not exists telefonos_alt      text[] not null default '{}',
  add column if not exists tipo_linea         text check (tipo_linea in ('MOVIL','FIJO')),
  add column if not exists municipio          text,
  add column if not exists departamento       text,
  add column if not exists genero             text check (genero in ('M','F','X')),
  add column if not exists ocupacion          text,
  add column if not exists segmento           text check (segmento in ('A','B','C','D')),
  add column if not exists calidad_registro   integer check (calidad_registro between 0 and 100),
  add column if not exists fuentes_todas      text[] not null default '{}',
  add column if not exists n_fuentes          integer not null default 1,
  add column if not exists disposicion_previa text check (disposicion_previa is null or disposicion_previa in
      ('VENTA','ASISTIO','CITA_AGENDADA','NO_ASISTIO','VOLVER_A_LLAMAR','INTERESADO_SIN_FECHA','NO_INTERESADO',
       'NO_CALIFICA','NO_LLAMAR','NO_CONTESTA','BUZON','OCUPADO','COLGO','NUMERO_ERRADO','FUERA_DE_SERVICIO','FAX_DATOS')),
  add column if not exists consentimiento     text not null default 'DESCONOCIDO'
                                              check (consentimiento in ('SI','NO','DESCONOCIDO')),
  add column if not exists no_llamar          boolean not null default false,
  add column if not exists revisar_no_llamar  boolean not null default false,   -- alterno coincide con la lista: gerencia decide
  add column if not exists estado_previo      text,                             -- lo que era antes de NO LLAMAR (para rectificar con fidelidad)
  add column if not exists tmk_previo         bigint,
  add column if not exists no_llamar_telefono text,                             -- por cuál número quedó bloqueado
  add column if not exists intentos           integer not null default 0;

-- Lo sensible, aparte (P9): solo gerencia.
create table if not exists public.funnel_prospectos_sensible (
  prospecto_id     bigint primary key references public.funnel_prospectos(id) on delete cascade,
  dpi              text,
  direccion        text,
  ingreso_estimado numeric,
  banco            text,
  score            integer,
  actualizado_en   timestamptz default now()
);
create index if not exists ix_fps_dpi on public.funnel_prospectos_sensible (dpi) where dpi is not null;
alter table public.funnel_prospectos_sensible enable row level security;
drop policy if exists fps_sel on public.funnel_prospectos_sensible;
create policy fps_sel on public.funnel_prospectos_sensible for select to authenticated using (funnel_es_gerente());
drop policy if exists fps_wr on public.funnel_prospectos_sensible;
create policy fps_wr on public.funnel_prospectos_sensible for all to authenticated using (funnel_es_gerente()) with check (funnel_es_gerente());
grant select, insert, update on public.funnel_prospectos_sensible to authenticated;

-- telefono2 (columna vieja) se pliega a telefonos_alt: una sola verdad.
update public.funnel_prospectos
   set telefonos_alt = array_append(telefonos_alt, regexp_replace(telefono2, '\D', '', 'g'))
 where telefono2 is not null and regexp_replace(telefono2, '\D', '', 'g') ~ '^[2-8][0-9]{7}$'
   and not (telefonos_alt @> array[regexp_replace(telefono2, '\D', '', 'g')]);

-- Normalizar teléfonos vivos ANTES del índice único (si hubiera filas viejas).
update public.funnel_prospectos
   set telefono = nullif(case when length(ltrim(regexp_replace(telefono, '\D', '', 'g'), '0')) = 11
                              and left(ltrim(regexp_replace(telefono, '\D', '', 'g'), '0'), 3) = '502'
                         then substr(ltrim(regexp_replace(telefono, '\D', '', 'g'), '0'), 4)
                         else ltrim(regexp_replace(telefono, '\D', '', 'g'), '0') end, '')
 where telefono is not null and telefono !~ '^[2-8][0-9]{7}$';
update public.funnel_prospectos
   set comentario = concat_ws(' · ', comentario, 'tel inválido al migrar: ' || telefono), telefono = null
 where telefono is not null and telefono !~ '^[2-8][0-9]{7}$';
-- Si ya hubiera duplicados vivos, PARAR con la lista: se deduplican a mano, no se pisan.
do $$
declare n int;
begin
  select count(*) into n from (select telefono from public.funnel_prospectos where telefono is not null group by 1 having count(*) > 1) d;
  if n > 0 then raise exception 'Hay % teléfonos duplicados en funnel_prospectos. Deduplicar antes de aplicar (select telefono, count(*) ... having count(*)>1).', n; end if;
end $$;
alter table public.funnel_prospectos drop constraint if exists fp_tel_gt;
alter table public.funnel_prospectos add constraint fp_tel_gt check (telefono is null or telefono ~ '^[2-8][0-9]{7}$');
-- UNA PERSONA = UNA FILA (P2). Teléfono nulo permitido (la pantalla lo declara opcional).
create unique index if not exists uq_fp_telefono on public.funnel_prospectos (telefono) where telefono is not null;
create index if not exists ix_fp_segmento on public.funnel_prospectos (segmento, calidad_registro desc);
create index if not exists ix_fp_cola     on public.funnel_prospectos (estado, recontacto_en) where no_llamar = false;
create index if not exists ix_fp_alt      on public.funnel_prospectos using gin (telefonos_alt);
create index if not exists ix_fc_prosp    on public.funnel_contratos (prospecto_id);
comment on column public.funnel_prospectos.fuentes_todas is
  'Linaje. fuentes_todas[1] = PRIMERA base que trajo a la persona = a quién se atribuye (Decisión 4, George 25-ago). base_id apunta a esa.';

-- ── 3. funnel_estados: tiempos y grupos viven acá, no en el trigger ──────────
alter table public.funnel_estados
  add column if not exists recontacto_intervalo interval,
  add column if not exists grupo text,
  add column if not exists irreversible boolean not null default false;
alter table public.funnel_estados drop constraint if exists fe_cuenta_como_chk;
alter table public.funnel_estados add constraint fe_cuenta_como_chk
  check (cuenta_como is null or cuenta_como in ('contactado','interesado','asiste','descartado','dato_malo'));
insert into public.funnel_estados (clave, etiqueta, color, orden, cuenta_como, dispara_recontacto, sig_etapa, activo) values
  ('buzon',             'Buzón de voz',       '#9E9E9E', 31, null,         true,  null,  true),
  ('ocupado',           'Ocupado',            '#9E9E9E', 32, null,         true,  null,  true),
  ('colgo',             'Colgó',              '#9E9E9E', 33, 'contactado', true,  null,  true),
  ('no_asistio',        'No asistió',         '#FF9800', 61, 'contactado', true,  null,  true),
  ('asistio',           'Asistió',            '#4CAF50', 62, 'asiste',     false, null,   false), -- la pone Recepción; NO mueve etapa (Recepción/Cierre ya la manejan)
  ('no_califica',       'No califica',        '#795548', 71, 'descartado', false, null,  true),
  ('agotado',           'Agotado (tope)',     '#607D8B', 72, 'descartado', false, null,  false), -- lo pone el sistema
  ('numero_errado',     'Número errado',      '#B71C1C', 80, 'dato_malo',  false, null,  true),
  ('fuera_de_servicio', 'Fuera de servicio',  '#B71C1C', 81, 'dato_malo',  false, null,  true),
  ('fax_datos',         'Fax / datos',        '#B71C1C', 82, 'dato_malo',  false, null,  true),
  ('menor_edad',        'Menor de edad',      '#B71C1C', 83, 'descartado', false, null,  true),
  ('fallecido',         'Fallecido',          '#000000', 84, 'descartado', false, null,  true),
  ('no_llamar',         'NO LLAMAR (permanente)', '#000000', 99, 'descartado', false, null, true)
on conflict (clave) do nothing;
update public.funnel_estados set recontacto_intervalo = v.i::interval, grupo = v.g, irreversible = v.irr
  from (values
    ('nuevo',             null,       'sin_contacto', false),
    ('no_contesta',       '4 hours',  'sin_contacto', false),
    ('buzon',             '4 hours',  'sin_contacto', false),
    ('ocupado',           '1 hour',   'sin_contacto', false),
    ('colgo',             '1 day',    'sin_contacto', false),
    ('contactado',        null,       'contacto',     false),
    ('recontactar',       '1 day',    'contacto',     false),
    ('interesado',        '2 days',   'contacto',     false),
    ('asistira',          null,       'cita',         false),
    ('no_asistio',        '2 days',   'cita',         false),
    ('asistio',           null,       'cita',         false),
    ('no_interesado',     '30 days',  'final',        false),
    ('no_califica',       null,       'final',        false),
    ('agotado',           null,       'final',        false),
    ('numero_errado',     null,       'dato_malo',    false),
    ('fuera_de_servicio', null,       'dato_malo',    false),
    ('fax_datos',         null,       'dato_malo',    false),
    ('menor_edad',        null,       'final',        true),
    ('fallecido',         null,       'final',        true),
    ('no_llamar',         null,       'final',        true)
  ) as v(c, i, g, irr)
 where funnel_estados.clave = v.c;
update public.funnel_estados set dispara_recontacto = true where clave in ('buzon','ocupado','colgo');
update public.funnel_estados set sig_etapa = null where clave = 'asistio';

-- ── 4. NO LLAMAR: la lista sagrada, con rectificación auditada ───────────────
create table if not exists public.funnel_no_llamar (
  telefono       text primary key,
  motivo         text not null check (motivo in ('pidio_no_ser_contactado','menor_edad','fallecido','legal','base_origen','otro')),
  origen         text,
  registrado_por text,
  registrado_en  timestamptz not null default now()
);
create table if not exists public.funnel_no_llamar_rectificaciones (
  id             bigserial primary key,
  telefono       text not null,
  motivo         text not null,
  autorizado_por text not null,
  en             timestamptz not null default now(),
  usada_en       timestamptz                     -- una rectificación sirve para UN borrado
);
alter table public.funnel_no_llamar enable row level security;
alter table public.funnel_no_llamar_rectificaciones enable row level security;
comment on table public.funnel_no_llamar is
  'Política P3. Solo gerencia la lee y la escribe directo; el TMK entra por la gestión no_llamar de SU prospecto. Sin UPDATE. DELETE solo con rectificación de gerencia en los 10 minutos previos (auditada).';

-- 4a. Antes de entrar: normaliza, firma con el JWT (no lo que mande el cliente), y tope anti-sabotaje.
create or replace function public.funnel_nl_antes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text; quien text; n int; tope int;
begin
  t := funnel_tel_norm(new.telefono);
  if t is null or t !~ '^[2-8][0-9]{7}$' then raise exception 'Teléfono inválido para NO LLAMAR: %', new.telefono using errcode = 'check_violation'; end if;
  new.telefono := t;
  quien := coalesce(auth.jwt() ->> 'email', current_setting('kuxtal.actor', true), 'sistema');
  new.registrado_por := quien;
  if current_setting('kuxtal.desde_ingesta', true) = 'si' then
    new.motivo := 'base_origen';
    tope := funnel_param('tope_no_llamar_ingesta', 5000);
  else
    tope := funnel_param('tope_no_llamar_hora', 50);
  end if;
  -- El tope cuenta SIEMPRE por actor, venga por gestión, por ingesta o directo (A12 #2)
  if auth.jwt() is not null or current_setting('kuxtal.desde_ingesta', true) = 'si' then
    select count(*) into n from public.funnel_no_llamar where registrado_por = quien and registrado_en > now() - interval '1 hour';
    if n >= tope then
      raise exception 'Tope de altas a NO LLAMAR por hora alcanzado (% de %) para %. Si es legítimo, avisá a gerencia general.', n, tope, quien using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.funnel_nl_antes() from public, anon, authenticated;
drop trigger if exists trg_nl_antes on public.funnel_no_llamar;
create trigger trg_nl_antes before insert on public.funnel_no_llamar for each row execute function public.funnel_nl_antes();

-- 4b. Al entrar: el prospecto con ese número PRINCIPAL queda bloqueado. Si coincide solo con un ALTERNO,
--     no se bloquea solo (podría ser la línea de la casa de tres personas): se marca para que gerencia revise.
create or replace function public.funnel_nl_aplicar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare prev text := current_setting('kuxtal.desde_lista', true);
begin
  perform set_config('kuxtal.desde_lista', 'si', true);
  update public.funnel_prospectos
     set estado_previo = estado, tmk_previo = tmk_id, no_llamar_telefono = new.telefono,
         no_llamar = true, estado = 'no_llamar', tmk_id = null, recontacto_en = null, actualizado_en = now()
   where telefono = new.telefono and no_llamar = false;
  update public.funnel_prospectos
     set revisar_no_llamar = true, actualizado_en = now()
   where telefonos_alt @> array[new.telefono] and no_llamar = false;
  perform set_config('kuxtal.desde_lista', coalesce(prev,''), true);
  return new;
end $$;
revoke all on function public.funnel_nl_aplicar() from public, anon, authenticated;
drop trigger if exists trg_nl_aplicar on public.funnel_no_llamar;
create trigger trg_nl_aplicar after insert on public.funnel_no_llamar for each row execute function public.funnel_nl_aplicar();

-- 4c. Candado: sin UPDATE nunca. DELETE solo si gerencia dejó una rectificación en los últimos 10 min.
create or replace function public.funnel_nl_candado() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare quien text; r record;
begin
  if tg_op = 'UPDATE' then
    raise exception 'NO LLAMAR es permanente (P3): no se edita. Teléfono %', old.telefono using errcode = 'check_violation';
  end if;
  quien := coalesce(auth.jwt() ->> 'email', current_setting('kuxtal.actor', true), '');
  select * into r from public.funnel_no_llamar_rectificaciones
   where telefono = old.telefono and en > now() - interval '10 minutes' and autorizado_por = quien and usada_en is null
   order by en desc limit 1;
  if r.id is null or not (funnel_es_gerente() or auth.jwt() is null) then
    raise exception 'NO LLAMAR es permanente (P3): borrar requiere rectificación de gerencia (funnel_no_llamar_rectificaciones) en los últimos 10 min. Teléfono %', old.telefono using errcode = 'check_violation';
  end if;
  update public.funnel_no_llamar_rectificaciones set usada_en = now() where id = r.id;   -- se consume: una rectificación, un borrado
  perform set_config('kuxtal.rectificando', 'si', true);
  update public.funnel_prospectos
     set no_llamar = false, estado = coalesce(estado_previo, 'nuevo'), tmk_id = tmk_previo,
         estado_previo = null, tmk_previo = null, no_llamar_telefono = null, actualizado_en = now()
   where no_llamar and (telefono = old.telefono or no_llamar_telefono = old.telefono);
  update public.funnel_prospectos set revisar_no_llamar = false where telefonos_alt @> array[old.telefono];
  perform set_config('kuxtal.rectificando', '', true);
  return old;
end $$;
revoke all on function public.funnel_nl_candado() from public, anon, authenticated;
drop trigger if exists trg_nl_candado on public.funnel_no_llamar;
create trigger trg_nl_candado before update or delete on public.funnel_no_llamar for each row execute function public.funnel_nl_candado();

-- 4d. Políticas: solo gerencia lee y escribe la lista directo. El TMK entra por la gestión.
drop policy if exists fnl_sel on public.funnel_no_llamar;
create policy fnl_sel on public.funnel_no_llamar for select to authenticated using (funnel_es_gerente());
drop policy if exists fnl_ins on public.funnel_no_llamar;
create policy fnl_ins on public.funnel_no_llamar for insert to authenticated with check (funnel_es_gerente());
drop policy if exists fnl_del on public.funnel_no_llamar;
create policy fnl_del on public.funnel_no_llamar for delete to authenticated using (funnel_es_gerente());
drop policy if exists fnlr_sel on public.funnel_no_llamar_rectificaciones;
create policy fnlr_sel on public.funnel_no_llamar_rectificaciones for select to authenticated using (funnel_es_gerente());
drop policy if exists fnlr_ins on public.funnel_no_llamar_rectificaciones;
create policy fnlr_ins on public.funnel_no_llamar_rectificaciones for insert to authenticated with check (funnel_es_gerente() and autorizado_por = (auth.jwt() ->> 'email'));
grant select, insert, delete on public.funnel_no_llamar to authenticated;
grant select, insert on public.funnel_no_llamar_rectificaciones to authenticated;
grant usage, select on sequence public.funnel_no_llamar_rectificaciones_id_seq to authenticated;

-- 4e. Para el front: "¿está bloqueado?" sin leer la lista.
create or replace function public.funnel_esta_bloqueado(p_tel text) returns boolean
language sql stable security definer set search_path = public, pg_temp as
$$ select funnel_es_staff() and exists (select 1 from public.funnel_no_llamar where telefono = funnel_tel_norm(p_tel)) $$;
revoke all on function public.funnel_esta_bloqueado(text) from public, anon;
grant execute on function public.funnel_esta_bloqueado(text) to authenticated;

-- ── 5. Prospectos: normalización + candados ──────────────────────────────────
-- 5a. INSERT o cambio de teléfonos: normaliza principal y alternos; si el principal está en la lista, nace bloqueado;
--     si un alterno está en la lista, nace "revisar". Al insertar, la disposición previa de bases viejas se respeta.
create or replace function public.funnel_fp_normalizar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text; alts text[] := '{}'; x text; prev text;
begin
  new.telefono := funnel_tel_norm(new.telefono);
  foreach x in array coalesce(new.telefonos_alt, '{}') loop
    x := funnel_tel_norm(x);
    if x ~ '^[2-8][0-9]{7}$' and x is distinct from new.telefono and not (alts @> array[x]) then alts := alts || x; end if;
  end loop;
  new.telefonos_alt := alts;
  if new.telefono is not null then new.tipo_linea := case when left(new.telefono,1) in ('3','4','5','8') then 'MOVIL' else 'FIJO' end; end if;
  if new.telefono is not null and exists (select 1 from public.funnel_no_llamar n where n.telefono = new.telefono) then
    new.no_llamar := true; new.estado := 'no_llamar'; new.tmk_id := null; new.recontacto_en := null;
  elsif cardinality(alts) > 0 and exists (select 1 from public.funnel_no_llamar n where n.telefono = any(alts)) then
    new.revisar_no_llamar := true;
  end if;
  if tg_op = 'INSERT' and not new.no_llamar then
    if new.disposicion_previa = 'NO_INTERESADO' then new.estado := 'no_interesado'; new.recontacto_en := now() + interval '30 days';
    elsif new.disposicion_previa in ('NUMERO_ERRADO','FUERA_DE_SERVICIO','FAX_DATOS') then new.estado := lower(new.disposicion_previa);
    elsif new.disposicion_previa = 'NO_CALIFICA' then new.estado := 'no_califica';
    elsif new.disposicion_previa in ('VOLVER_A_LLAMAR','INTERESADO_SIN_FECHA') then new.estado := 'recontactar'; new.recontacto_en := coalesce(new.recontacto_en, now() + interval '1 day');
    end if;
    if new.disposicion_previa = 'NO_LLAMAR' and new.telefono is not null then
      prev := current_setting('kuxtal.desde_ingesta', true);
      perform set_config('kuxtal.desde_ingesta', 'si', true);
      insert into public.funnel_no_llamar (telefono, motivo, origen) values (new.telefono, 'base_origen', 'base de origen: ' || coalesce(new.fuentes_todas[1], '?')) on conflict do nothing;
      perform set_config('kuxtal.desde_ingesta', coalesce(prev,''), true);
      new.no_llamar := true; new.estado := 'no_llamar'; new.tmk_id := null; new.no_llamar_telefono := new.telefono;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.funnel_fp_normalizar() from public, anon, authenticated;
drop trigger if exists trg_fp_antes_insertar on public.funnel_prospectos;
drop trigger if exists trg_fp_normalizar on public.funnel_prospectos;
create trigger trg_fp_normalizar before insert or update of telefono, telefonos_alt on public.funnel_prospectos
  for each row execute function public.funnel_fp_normalizar();

-- 5b. Candado del prospecto: no_llamar solo sube desde la lista, solo baja por rectificación; bloqueado no se toca ni se asigna.
create or replace function public.funnel_fp_candado_nl() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.no_llamar and not new.no_llamar and current_setting('kuxtal.rectificando', true) is distinct from 'si' then
    raise exception 'NO LLAMAR es irreversible (P3). Teléfono %', old.telefono using errcode = 'check_violation';
  end if;
  if new.no_llamar and not old.no_llamar and current_setting('kuxtal.desde_lista', true) is distinct from 'si'
     and not exists (select 1 from public.funnel_no_llamar n where n.telefono = new.telefono) then
    raise exception 'no_llamar solo se marca a través de la lista funnel_no_llamar (gestión no_llamar o gerencia). Teléfono %', new.telefono using errcode = 'check_violation';
  end if;
  if new.no_llamar and new.tmk_id is not null then
    raise exception 'Prospecto en NO LLAMAR no se asigna a un TMK. Teléfono %', new.telefono using errcode = 'check_violation';
  end if;
  if new.no_llamar and old.no_llamar and new.estado is distinct from 'no_llamar' and current_setting('kuxtal.rectificando', true) is distinct from 'si' then
    raise exception 'Prospecto en NO LLAMAR: el estado no cambia. Teléfono %', new.telefono using errcode = 'check_violation';
  end if;
  if new.estado = 'no_llamar' and not new.no_llamar then
    raise exception 'estado=no_llamar solo con la lista. Usá la gestión no_llamar.' using errcode = 'check_violation';
  end if;
  -- Columnas de linaje/tope/legal: solo gerencia o el sistema (A12 #4)
  if auth.jwt() is not null and not funnel_es_gerente()
     and current_setting('kuxtal.desde_gestion', true) is distinct from 'si' and current_setting('kuxtal.desde_lista', true) is distinct from 'si' and (
       new.intentos is distinct from old.intentos or new.fuentes_todas is distinct from old.fuentes_todas
       or new.n_fuentes is distinct from old.n_fuentes or new.revisar_no_llamar is distinct from old.revisar_no_llamar
       or new.disposicion_previa is distinct from old.disposicion_previa or new.consentimiento is distinct from old.consentimiento
       or new.calidad_registro is distinct from old.calidad_registro or new.segmento is distinct from old.segmento
       or new.base_id is distinct from old.base_id or new.estado_previo is distinct from old.estado_previo
       or new.tmk_previo is distinct from old.tmk_previo or new.no_llamar_telefono is distinct from old.no_llamar_telefono) then
    raise exception 'Columna de linaje/tope/legal: solo gerencia' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
revoke all on function public.funnel_fp_candado_nl() from public, anon, authenticated;
drop trigger if exists trg_fp_candado_nl on public.funnel_prospectos;
create trigger trg_fp_candado_nl before update on public.funnel_prospectos for each row execute function public.funnel_fp_candado_nl();

-- ── 6. Gestiones: la bitácora que mide a la base ─────────────────────────────
create table if not exists public.funnel_gestiones (
  id               bigserial primary key,
  prospecto_id     bigint not null references public.funnel_prospectos(id) on delete restrict,
  base_id          bigint references public.funnel_bases(id),
  tmk_id           bigint references public.funnel_agentes(id),
  telefono_marcado text,
  canal            text not null default 'llamada' check (canal in ('llamada','whatsapp','sms','presencial','sistema')),
  disposicion      text not null references public.funnel_estados(clave),
  cita_en          timestamptz,
  asistio          boolean,
  notas            text,
  duracion_seg     integer,
  creado_por       text,
  creado_en        timestamptz not null default now()
);
create index if not exists ix_fg_base  on public.funnel_gestiones (base_id, disposicion);
create index if not exists ix_fg_prosp on public.funnel_gestiones (prospecto_id, creado_en desc);
create index if not exists ix_fg_tmk   on public.funnel_gestiones (tmk_id, creado_en desc);

-- 6a. BEFORE: el servidor decide base_id / tmk_id / creado_por (nunca el cliente), valida y aplica topes.
create or replace function public.funnel_fg_antes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; mi_agente bigint; n_num int; tope_p int; tope_n int; e record;
begin
  select * into p from public.funnel_prospectos where id = new.prospecto_id;
  if p.id is null then raise exception 'Prospecto % no existe', new.prospecto_id; end if;
  select * into e from public.funnel_estados where clave = new.disposicion;
  if e.clave is null then raise exception 'Disposición desconocida: %', new.disposicion using errcode = 'check_violation'; end if;
  new.base_id := p.base_id;
  if auth.jwt() is not null then
    new.creado_por := auth.jwt() ->> 'email';
    select a.id into mi_agente from public.funnel_agentes a where lower(a.email) = lower(auth.jwt() ->> 'email') limit 1;
    new.tmk_id := coalesce(mi_agente, p.tmk_id);
  else
    new.creado_por := coalesce(new.creado_por, current_setting('kuxtal.actor', true), 'sistema');
    new.tmk_id := coalesce(new.tmk_id, p.tmk_id);
  end if;
  if p.no_llamar then raise exception 'Prospecto en NO LLAMAR: no se gestiona (P3). Teléfono %', p.telefono using errcode = 'check_violation'; end if;
  if new.disposicion = 'no_llamar' and auth.jwt() is not null and not funnel_es_gerente() and (mi_agente is null or mi_agente is distinct from p.tmk_id) then
    raise exception 'Solo el TMK asignado o gerencia pueden marcar NO LLAMAR' using errcode = 'insufficient_privilege';
  end if;
  -- telefono_marcado: solo el principal o un alterno del prospecto (A12 #1)
  new.telefono_marcado := coalesce(funnel_tel_norm(new.telefono_marcado), p.telefono);
  if new.telefono_marcado is not null and new.telefono_marcado is distinct from p.telefono and not (p.telefonos_alt @> array[new.telefono_marcado]) then
    raise exception 'telefono_marcado debe ser el principal o un alterno del prospecto' using errcode = 'check_violation';
  end if;
  if new.disposicion = 'no_llamar' and new.telefono_marcado is null then
    raise exception 'NO LLAMAR requiere un teléfono válido' using errcode = 'check_violation';
  end if;
  -- Disposiciones reservadas: inactivas (asistio, agotado) o irreversibles salvo no_llamar → solo gerencia/sistema (A12 #9)
  if auth.jwt() is not null and not funnel_es_gerente() and (e.activo is not true or (e.irreversible and new.disposicion <> 'no_llamar')) then
    raise exception 'Disposición % reservada al sistema o gerencia', new.disposicion using errcode = 'insufficient_privilege';
  end if;
  new.asistio := (new.disposicion = 'asistio');
  -- Topes (Diseño #2): 7 por persona; 2 sin-contacto seguidos por número → siguiente número o agotado.
  tope_p := funnel_param('tope_intentos_persona', 7); tope_n := funnel_param('tope_intentos_numero', 2);
  if e.grupo = 'sin_contacto' and p.intentos + 1 >= tope_p then
    new.notas := concat_ws(' · ', new.notas, 'AGOTADO: tope de ' || tope_p || ' intentos'); new.disposicion := 'agotado';
  end if;
  return new;
end $$;
revoke all on function public.funnel_fg_antes() from public, anon, authenticated;
drop trigger if exists trg_fg_antes on public.funnel_gestiones;
create trigger trg_fg_antes before insert on public.funnel_gestiones for each row execute function public.funnel_fg_antes();

-- 6b. AFTER: aplica al prospecto (estado, intentos, recontacto por funnel_estados, etapa) y NO LLAMAR.
create or replace function public.funnel_fg_aplicar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare e record; p record; n_num int; tope_n int; sig text; prev text := current_setting('kuxtal.desde_gestion', true);
begin
  select * into e from public.funnel_estados where clave = new.disposicion;
  select * into p from public.funnel_prospectos where id = new.prospecto_id;
  perform set_config('kuxtal.desde_gestion', 'si', true);
  if new.disposicion = 'no_llamar' then
    insert into public.funnel_no_llamar (telefono, motivo, origen)
      select distinct t, 'pidio_no_ser_contactado', 'gestión #' || new.id || ' por ' || coalesce(new.creado_por, '?')
        from unnest(array_remove(array[p.telefono, new.telefono_marcado], null)) t
       where t ~ '^[2-8][0-9]{7}$' and not exists (select 1 from public.funnel_no_llamar n where n.telefono = t)
      on conflict do nothing;
    perform set_config('kuxtal.desde_gestion', coalesce(prev,''), true);
    return new;
  end if;
  -- ¿este número ya lleva N sin-contacto seguidos? → el siguiente intento va al otro número
  tope_n := funnel_param('tope_intentos_numero', 2);
  select count(*) into n_num from (
    select g.disposicion, fe.grupo from public.funnel_gestiones g join public.funnel_estados fe on fe.clave = g.disposicion
     where g.prospecto_id = p.id and g.telefono_marcado = new.telefono_marcado order by g.creado_en desc limit tope_n) u
   where u.grupo = 'sin_contacto';
  sig := null;
  if e.grupo = 'sin_contacto' and n_num >= tope_n then
    select a into sig from unnest(p.telefonos_alt) a where a is distinct from new.telefono_marcado limit 1;
  end if;
  update public.funnel_prospectos
     set estado         = case when new.disposicion = 'asistio' then estado else new.disposicion end,
         intentos       = case when new.disposicion = 'asistio' then intentos else intentos + 1 end,
         recontacto_en  = case when new.disposicion = 'asistio' then recontacto_en
                               when e.recontacto_intervalo is not null then coalesce(new.cita_en, now() + e.recontacto_intervalo)
                               when new.disposicion = 'asistira' then recontacto_en
                               else null end,
         presenta_en    = coalesce(new.cita_en, presenta_en),
         etapa          = coalesce(e.sig_etapa, etapa),
         comentario     = case when sig is not null then concat_ws(' · ', comentario, 'Siguiente intento al ' || sig) else comentario end,
         actualizado_en = now()
   where id = new.prospecto_id;
  perform set_config('kuxtal.desde_gestion', coalesce(prev,''), true);
  return new;
end $$;
revoke all on function public.funnel_fg_aplicar() from public, anon, authenticated;
drop trigger if exists trg_fg_aplicar on public.funnel_gestiones;
create trigger trg_fg_aplicar after insert on public.funnel_gestiones for each row execute function public.funnel_fg_aplicar();

-- 6c. PUENTE: la pantalla vieja hace PATCH estado directo. Eso también deja gestión (no hay "letra muerta").
create or replace function public.funnel_fp_puente_gestion() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_setting('kuxtal.desde_gestion', true) = 'si' or current_setting('kuxtal.desde_lista', true) = 'si' then return new; end if;
  if new.estado is distinct from old.estado and new.estado is not null and new.estado not in ('nuevo','no_llamar','agotado','asistio') then
    insert into public.funnel_gestiones (prospecto_id, disposicion, cita_en, canal, notas)
      values (new.id, new.estado, case when new.estado = 'asistira' then new.presenta_en else new.recontacto_en end, 'llamada', 'puente desde pantalla');
  end if;
  return new;
end $$;
revoke all on function public.funnel_fp_puente_gestion() from public, anon, authenticated;
drop trigger if exists trg_fp_puente_gestion on public.funnel_prospectos;
create trigger trg_fp_puente_gestion after update of estado on public.funnel_prospectos
  for each row execute function public.funnel_fp_puente_gestion();

-- 6d. RECEPCIÓN manda en asistencia: cuando llega (recepcion_en), nace la gestión 'asistio' sola.
create or replace function public.funnel_fp_asistio() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.recepcion_en is not null and old.recepcion_en is null then
    insert into public.funnel_gestiones (prospecto_id, disposicion, canal, asistio, notas)
      values (new.id, 'asistio', 'presencial', true, 'Recepción: ' || coalesce(new.recepcionado_por, '?'));
  end if;
  return new;
end $$;
revoke all on function public.funnel_fp_asistio() from public, anon, authenticated;
drop trigger if exists trg_fp_asistio on public.funnel_prospectos;
create trigger trg_fp_asistio after update of recepcion_en on public.funnel_prospectos
  for each row execute function public.funnel_fp_asistio();

-- 6e. RLS de gestiones: el TMK ve y registra las de SUS prospectos; gerencia todo. Roles de sala NO registran llamadas.
alter table public.funnel_gestiones enable row level security;
drop policy if exists fg_sel on public.funnel_gestiones;
create policy fg_sel on public.funnel_gestiones for select to authenticated using (
  funnel_ve_todo() or exists (select 1 from public.funnel_prospectos p join public.funnel_agentes a on a.id = p.tmk_id
                               where p.id = funnel_gestiones.prospecto_id and lower(a.email) = lower(auth.jwt() ->> 'email')));
drop policy if exists fg_ins on public.funnel_gestiones;
create policy fg_ins on public.funnel_gestiones for insert to authenticated with check (
  funnel_es_gerente() or exists (select 1 from public.funnel_prospectos p join public.funnel_agentes a on a.id = p.tmk_id
                                  where p.id = funnel_gestiones.prospecto_id and lower(a.email) = lower(auth.jwt() ->> 'email')));
revoke all on public.funnel_gestiones from anon, authenticated;
grant select on public.funnel_gestiones to authenticated;
grant insert (prospecto_id, telefono_marcado, canal, disposicion, cita_en, asistio, notas, duracion_seg) on public.funnel_gestiones to authenticated;
grant usage, select on sequence public.funnel_gestiones_id_seq to authenticated;

-- ── 7. Ingesta con linaje: una función para la pantalla y para el cargador de 480k ──
--    Si el teléfono ya existe: NO rebota; agrega la base a fuentes_todas y rellena huecos. Decisión 4 tiene mecanismo.
create or replace function public.funnel_ingestar(p_base_id bigint, p_filas jsonb)
returns table (insertados int, enriquecidos int, sin_telefono int, bloqueados int, errores jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
declare f jsonb; t text; pid bigint; cod text; ins int := 0; enr int := 0; sint int := 0; blq int := 0; ins_id bigint; ins_nl boolean; errs jsonb := '[]'::jsonb; prev text;
begin
  if auth.jwt() is not null and not funnel_es_gerente() then raise exception 'Solo gerencia carga bases' using errcode = 'insufficient_privilege'; end if;
  if jsonb_array_length(p_filas) > funnel_param('ingesta_max_lote', 2000) then
    raise exception 'Lote de % filas: el máximo es %. Mandá en tandas.', jsonb_array_length(p_filas), funnel_param('ingesta_max_lote', 2000) using errcode = 'check_violation';
  end if;
  select codigo into cod from public.funnel_bases where id = p_base_id;
  if cod is null then cod := 'B' || p_base_id; end if;
  prev := current_setting('kuxtal.desde_ingesta', true);
  perform set_config('kuxtal.desde_ingesta', 'si', true);
  for f in select * from jsonb_array_elements(p_filas) loop
   begin
    t := funnel_tel_norm(f->>'telefono');
    if t is null or t !~ '^[2-8][0-9]{7}$' then
      sint := sint + 1;      -- sin teléfono válido: se cuenta y se reporta, NO se inserta (no hay llave, no es idempotente)
      continue;
    end if;
    select id into pid from public.funnel_prospectos where telefono = t;
    ins_id := null; ins_nl := false;
    if pid is null then
      insert into public.funnel_prospectos (base_id, nombre, telefono, telefonos_alt, email, municipio, departamento, genero, edad, ocupacion,
                                            tipo_tarjetas, segmento, calidad_registro, fuentes_todas, n_fuentes, disposicion_previa, comentario, consentimiento, estado, etapa)
        values (p_base_id, coalesce(f->>'nombre','(sin nombre)'), t,
                coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(f->'telefonos_alt','[]'::jsonb)) x), '{}'),
                f->>'email', f->>'municipio', f->>'departamento', f->>'genero', nullif(f->>'edad','')::int, f->>'ocupacion',
                f->>'tipo_tarjeta', f->>'segmento', nullif(f->>'calidad_registro','')::int,
                coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(f->'fuentes_todas','[]'::jsonb)) x), array[cod]),
                greatest(1, coalesce(nullif(f->>'n_fuentes','')::int, 1)), nullif(f->>'disposicion_previa',''), f->>'gestion_previa_texto',
                coalesce(nullif(f->>'consentimiento',''), 'DESCONOCIDO'), 'nuevo', 'telemarketing')
        on conflict (telefono) where telefono is not null do nothing
        returning id, no_llamar into ins_id, ins_nl;
      if ins_id is null then select id into pid from public.funnel_prospectos where telefono = t; else pid := ins_id; ins := ins + 1; if ins_nl then blq := blq + 1; end if; end if;
    end if;
    if ins_id is null then
      update public.funnel_prospectos
         set fuentes_todas = case when fuentes_todas @> array[cod] then fuentes_todas else fuentes_todas || cod end,
             n_fuentes     = case when fuentes_todas @> array[cod] then n_fuentes else n_fuentes + 1 end,
             nombre        = case when length(coalesce(f->>'nombre','')) > length(coalesce(nombre,'')) then f->>'nombre' else nombre end,
             email         = coalesce(email, f->>'email'),
             municipio     = coalesce(municipio, f->>'municipio'),
             segmento      = coalesce(f->>'segmento', segmento),
             telefonos_alt = (select array_agg(distinct x) from unnest(telefonos_alt || coalesce((select array_agg(y) from jsonb_array_elements_text(coalesce(f->'telefonos_alt','[]'::jsonb)) y), '{}')) x),
             actualizado_en = now()
       where id = pid;
      enr := enr + 1;
    end if;
    if coalesce(f->>'dpi', f->>'direccion', f->>'ingreso_estimado', f->>'banco') is not null then
      insert into public.funnel_prospectos_sensible (prospecto_id, dpi, direccion, ingreso_estimado, banco, score)
        values (pid, f->>'dpi', f->>'direccion', nullif(f->>'ingreso_estimado','')::numeric, f->>'banco', nullif(f->>'score','')::int)
      on conflict (prospecto_id) do update set dpi = coalesce(funnel_prospectos_sensible.dpi, excluded.dpi),
        direccion = coalesce(funnel_prospectos_sensible.direccion, excluded.direccion),
        ingreso_estimado = greatest(funnel_prospectos_sensible.ingreso_estimado, excluded.ingreso_estimado),
        banco = coalesce(funnel_prospectos_sensible.banco, excluded.banco), actualizado_en = now();
    end if;
   exception when others then
    errs := errs || jsonb_build_object('telefono', f->>'telefono', 'nombre', left(coalesce(f->>'nombre',''), 40), 'error', sqlerrm);
   end;
  end loop;
  perform set_config('kuxtal.desde_ingesta', coalesce(prev,''), true);
  update public.funnel_bases set total = (select count(*) from public.funnel_prospectos where base_id = p_base_id) where id = p_base_id;
  return query select ins, enr, sint, blq, errs;
end $$;
revoke all on function public.funnel_ingestar(bigint, jsonb) from public, anon;
grant execute on function public.funnel_ingestar(bigint, jsonb) to authenticated;

-- ── 8. La vista que mide cada base (lo que pregunta el gerente) ──────────────
create or replace view public.funnel_desempeno_bases as
with g as (
  select g.base_id,
         count(*)                                                        as llamadas,
         count(distinct g.prospecto_id)                                  as marcados,
         count(*) filter (where e.grupo in ('contacto','cita','final') and e.cuenta_como is distinct from 'dato_malo') as contacto_efectivo,
         count(*) filter (where e.cuenta_como = 'dato_malo')             as dato_malo,
         count(distinct g.prospecto_id) filter (where g.disposicion = 'asistira') as citas
    from public.funnel_gestiones g join public.funnel_estados e on e.clave = g.disposicion
   group by g.base_id),
a as (
  select base_id, count(*) filter (where recepcion_en is not null) as asistieron
    from public.funnel_prospectos group by base_id),
v as (
  select p.base_id, count(*) as ventas
    from public.funnel_contratos c join public.funnel_prospectos p on p.id = c.prospecto_id
   where c.estado is distinct from 'anulado' group by p.base_id)
select
  b.id, b.codigo, b.nombre, b.origen, b.consentimiento, b.estado_catalogo,
  c.dueno, c.proveedor, c.costo,                                          -- null para quien no es gerencia (RLS de la cédula)
  b.telefonos_unicos                                                      as entregados,
  b.personas_nuevas,
  coalesce(g.marcados, 0)                                                 as marcados,
  coalesce(g.llamadas, 0)                                                 as llamadas,
  coalesce(g.contacto_efectivo, 0)                                        as contacto_efectivo,
  coalesce(g.dato_malo, 0)                                                as dato_malo,
  coalesce(g.citas, 0)                                                    as citas,
  coalesce(a.asistieron, 0)                                               as asistieron,
  coalesce(v.ventas, 0)                                                   as ventas,
  round(100.0 * coalesce(g.marcados,0) / nullif(b.telefonos_unicos,0), 1)              as pct_penetracion,
  round(100.0 * coalesce(g.contacto_efectivo,0) / nullif(g.marcados,0), 1)             as pct_contacto,
  round(100.0 * coalesce(g.dato_malo,0) / nullif(g.llamadas,0), 1)                     as pct_dato_malo,
  round(100.0 * coalesce(g.citas,0) / nullif(g.contacto_efectivo,0), 1)                as tasa_cita,
  round(100.0 * coalesce(a.asistieron,0) / nullif(g.citas,0), 1)                       as tasa_asistencia,
  round(100.0 * coalesce(v.ventas,0) / nullif(a.asistieron,0), 1)                      as tasa_cierre,
  round(100.0 * coalesce(v.ventas,0) / nullif(b.telefonos_unicos,0), 2)                as pct_conversion_total,
  round(c.costo / nullif(b.personas_nuevas,0), 2)                                      as costo_por_persona_nueva,
  round(c.costo / nullif(g.citas,0), 2)                                                as costo_por_cita,
  round(c.costo / nullif(v.ventas,0), 2)                                               as costo_por_venta,
  case when coalesce(g.llamadas,0) >= funnel_param('min_muestra_quemada',100)
        and 100.0 * coalesce(g.dato_malo,0) / nullif(g.llamadas,0) > funnel_param('pct_dato_malo_quemada',15)
       then 'QUEMADA' when coalesce(g.llamadas,0) < funnel_param('min_muestra_quemada',100) then 'SIN MUESTRA' else 'OK' end as veredicto_p6
from public.funnel_bases b
left join public.funnel_bases_cedula c on c.base_id = b.id
left join g on g.base_id = b.id
left join a on a.base_id = b.id
left join v on v.base_id = b.id
where funnel_ve_todo() or auth.jwt() is null;   -- un TMK vería cifras parciales y creería que son la base entera (A12 #12)
alter view public.funnel_desempeno_bases set (security_invoker = on);
grant select on public.funnel_desempeno_bases to authenticated;
comment on view public.funnel_desempeno_bases is
  'Hoja 05 del catálogo maestro, calculada sola. Asistencia = recepcion_en (Recepción manda). P6 con muestra mínima. Costo solo visible a gerencia.';

commit;
-- ═══════════════════════════════════════════════════════════════════════════════
-- CÓMO SE APLICA (George):
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260825_maestro_de_datos.sql').read()}))")
-- Después: supabase/qa/probar_maestro_de_datos.sql (corre en transacción y hace ROLLBACK).
-- ═══════════════════════════════════════════════════════════════════════════════
