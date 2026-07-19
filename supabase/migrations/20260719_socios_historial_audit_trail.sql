-- ─────────────────────────────────────────────────────────────────────────────
-- Socios · Historial de cambios de campos  (Field Audit Trail)   2026-07-19
-- HALLAZGO Kaizen: 213d1775 — «Kuxtal guarda socios pero nunca quién/cuándo
-- cambió cada campo». Inspiración: Salesforce "Field Audit Trail" (rastro
-- inmutable de valor-anterior → valor-nuevo por campo, con actor y fecha).
--
-- SIN APLICAR AUTOMÁTICAMENTE. Lo revisa y lo corre un humano (George/Lola),
-- igual que las otras migraciones del repo, contra el proyecto KUXTAL
-- (tevzfdiumfekvapamovw):
--
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260719_socios_historial_audit_trail.sql').read()}))")
--
-- POR QUÉ EXISTE
--   La app (app.html) edita cada socio con un PATCH directo a PostgREST
--   (`patchSocio` → PATCH /rest/v1/socios?id=eq.<id>). El registro queda con el
--   valor NUEVO, pero se pierde para siempre el valor viejo, QUIÉN lo cambió y
--   CUÁNDO. Hoy sólo existe un log grueso app-side (tabla `interacciones`,
--   "Editó: nombre, teléfono") — sin valores viejo/nuevo y SALTABLE (depende de
--   que el cliente lo escriba; un PATCH directo no lo genera). Eso no es un rastro
--   de auditoría.
--
-- QUÉ HACE (todo idempotente y ADITIVO — no toca los updates existentes)
--   1. Tabla `socios_historial`: una fila por CAMPO que cambió, con valor
--      anterior, valor nuevo, actor (uuid + email + rol del JWT) y fecha.
--   2. Trigger AFTER UPDATE en `socios` que compara OLD vs NEW campo por campo
--      (vía to_jsonb) y escribe SÓLO los campos que de verdad cambiaron. Como es
--      un trigger de Postgres, captura TODO update — por la app, por un script,
--      por el SQL editor — no se puede saltar (a diferencia del log app-side).
--   3. RLS: la tabla es SÓLO-LECTURA para el staff que administra socios
--      (admin / gerente_general / gerente_ventas, los mismos de la policy
--      socios_auth_update). NADIE la escribe a mano: no hay policy de
--      INSERT/UPDATE/DELETE, y sólo el trigger (SECURITY DEFINER, dueño postgres)
--      inserta. anon no la ve.
--
-- POR QUÉ TRIGGER Y NO LOG EN EL CLIENTE
--   El trigger vive en la base: es la ÚNICA vía por la que pasan todos los UPDATE.
--   Un log app-side se puede omitir (otro cliente, un curl, un fix por SQL) y
--   además puede MENTIR sobre el valor viejo. El trigger lee OLD/NEW reales dentro
--   de la misma transacción del UPDATE: si el UPDATE ocurre, el rastro ocurre.
--
-- POR QUÉ NO ROMPE NADA
--   Es un trigger AFTER UPDATE que sólo INSERTA en otra tabla. No modifica NEW, no
--   cambia la firma de ningún RPC, no altera columnas de socios. Si dos llamadas
--   concurrentes editan, cada UPDATE genera su propio rastro dentro de su TX.
--   El único modo de fallar sería violar un constraint de socios_historial, y sus
--   NOT NULL (registro_id, campo) siempre están presentes → no puede tumbar un
--   UPDATE legítimo.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- 1) La tabla del rastro. Inmutable por diseño (sólo el trigger escribe).
create table if not exists public.socios_historial (
  id                 bigint generated always as identity primary key,
  tabla              text        not null default 'socios',
  registro_id        bigint      not null,          -- socios.id afectado
  campo              text        not null,          -- nombre de la columna que cambió
  valor_anterior     text,                          -- valor viejo (texto; null = era null)
  valor_nuevo        text,                          -- valor nuevo (texto; null = quedó null)
  cambiado_por       uuid,                          -- auth.uid() del JWT (null = sin sesión / service_role / SQL)
  cambiado_por_email text,                          -- email del JWT, para leerlo sin joinear
  cambiado_por_rol   text,                          -- app_metadata.role del JWT
  cambiado_en        timestamptz not null default now()
);

comment on table public.socios_historial is
  'Field Audit Trail de socios (HALLAZGO 213d1775). Una fila por CAMPO que cambió en un UPDATE de socios: valor_anterior→valor_nuevo, actor (uuid/email/rol del JWT) y fecha. La escribe SÓLO el trigger trg_socios_audit (SECURITY DEFINER); nadie inserta/edita/borra a mano (sin policy de escritura). Sólo-lectura para admin/gerente_general/gerente_ventas.';

-- Índices para las consultas típicas: "historia de este socio" y "cambios de este campo".
create index if not exists socios_historial_registro_idx
  on public.socios_historial (registro_id, cambiado_en desc);
create index if not exists socios_historial_campo_idx
  on public.socios_historial (campo, cambiado_en desc);

-- 2) El trigger que captura el cambio por campo.
--    SECURITY DEFINER (dueño postgres): puede insertar en socios_historial aunque
--    el que edita socios sea un rol con RLS. auth.uid()/auth.jwt() siguen leyendo
--    el JWT de la request (los GUC request.jwt.* NO se pierden en un definer).
--    Compara OLD vs NEW con to_jsonb y `is distinct from` (maneja NULLs bien) →
--    sólo registra los campos realmente distintos, aunque el PATCH mande todo el
--    body (la app siempre manda todos los campos del formulario).
create or replace function public.socios_audit_cambios()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  old_j   jsonb := to_jsonb(OLD);
  new_j   jsonb := to_jsonb(NEW);
  k       text;
  v_uid   uuid  := auth.uid();
  v_email text  := auth.jwt() ->> 'email';
  v_rol   text  := auth.jwt() -> 'app_metadata' ->> 'role';
  -- Columnas que NO se auditan:
  --   id/creado_en → no cambian (PK y timestamp de alta).
  --   token        → es la credencial magic-link del socio; NO duplicamos su
  --                  valor en una segunda tabla (evita esparcir el secreto).
  ignorar text[] := array['id', 'creado_en', 'token'];
begin
  for k in select jsonb_object_keys(new_j) loop
    if k = any(ignorar) then
      continue;
    end if;
    if (old_j -> k) is distinct from (new_j -> k) then
      insert into public.socios_historial
        (tabla, registro_id, campo, valor_anterior, valor_nuevo,
         cambiado_por, cambiado_por_email, cambiado_por_rol)
      values
        (tg_table_name, new.id, k, old_j ->> k, new_j ->> k,
         v_uid, v_email, v_rol);
    end if;
  end loop;
  return new;
end;
$function$;

-- Re-ejecutable: dropear el trigger si ya existe antes de crearlo.
drop trigger if exists trg_socios_audit on public.socios;
create trigger trg_socios_audit
  after update on public.socios
  for each row
  execute function public.socios_audit_cambios();

-- 3) RLS: sólo-lectura para el staff que administra socios; nadie escribe a mano.
alter table public.socios_historial enable row level security;

-- Cinturón y tirantes: sin GRANTs de escritura para roles de app; sólo SELECT a
-- authenticated (y la policy de abajo lo acota por rol). anon no toca nada.
revoke all on public.socios_historial from anon;
revoke all on public.socios_historial from authenticated;
grant select on public.socios_historial to authenticated;

-- Lectura acotada al mismo conjunto que puede EDITAR socios (socios_auth_update):
-- admin, gerente_general, gerente_ventas. Son los que auditan los cambios.
-- (Si George prefiere SÓLO admin, dejar un único elemento en el ARRAY.)
drop policy if exists socios_historial_lectura_staff on public.socios_historial;
create policy socios_historial_lectura_staff
  on public.socios_historial
  for select
  to authenticated
  using (
    ((auth.jwt() -> 'app_metadata'::text) ->> 'role'::text)
      = any (array['admin'::text, 'gerente_general'::text, 'gerente_ventas'::text])
  );

-- NO se crea ninguna policy de INSERT/UPDATE/DELETE a propósito: con RLS activa y
-- sin policy de escritura, ningún rol de app puede escribir el historial. La única
-- vía de inserción es el trigger (definer, dueño postgres), que RLS no le aplica.

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN sugerida DESPUÉS de aplicar (prueba el guardián, no lo razones):
--
--   -- (a) El trigger captura un cambio real. Editá un socio de prueba y mirá:
--   --     UPDATE public.socios SET celular='00000000' WHERE id=<id_de_prueba>;
--   select campo, valor_anterior, valor_nuevo, cambiado_por_email, cambiado_en
--     from public.socios_historial
--    where registro_id = <id_de_prueba>
--    order by cambiado_en desc;
--   -- Debe aparecer UNA fila (campo='celular') con el valor viejo y el nuevo.
--
--   -- (b) Reintroducir el defecto a propósito: un UPDATE que NO cambia nada
--   --     (mismo valor) NO debe generar filas (el guard `is distinct from`).
--
--   -- (c) anon NO ve el historial (por PostgREST con la llave publishable, sin
--   --     Authorization):  GET /rest/v1/socios_historial  -> [] o 401.
--
--   -- (d) Un rol NO autorizado (p.ej. telemarketing) logueado tampoco lo lee:
--   --     GET /rest/v1/socios_historial con su token -> [] (RLS lo filtra).
--
--   -- (e) Un admin logueado SÍ lee el rastro completo.
-- ─────────────────────────────────────────────────────────────────────────────
