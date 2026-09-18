#!/bin/bash
# copia-local.sh — levanta una COPIA de la base viva de Kuxtal en el Postgres local
# para ensayar migraciones de RLS (bloque 1). Nunca escribe en la base viva: solo lee
# con pg_dump y vuelca directo a la copia por tubería (sin archivo en disco con PII).
# Uso:  qa/rls/copia-local.sh <nombre-base-local>
set -euo pipefail
BASE="${1:?falta el nombre de la base local}"
. "$HOME/.espiga-secrets.sh" >/dev/null 2>&1
[ -n "${KUXTAL_DB_URL:-}" ] || { echo "🔴 sin KUXTAL_DB_URL en el cofre"; exit 1; }
case "$BASE" in kux_*) ;; *) echo "🔴 la base local tiene que empezar con kux_"; exit 1;; esac
LOCAL="postgresql://$(whoami)@localhost:5432/$BASE"
dropdb --if-exists "$BASE"; createdb "$BASE"
psql -q -X -v ON_ERROR_STOP=1 "$LOCAL" >/dev/null <<'SQL'
create schema if not exists auth;
create schema if not exists extensions;
do $a$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_admin') then create role supabase_admin nologin; end if;
end $a$;
create or replace function auth.jwt() returns jsonb language sql stable as
  $a$ select coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb, '{}'::jsonb) $a$;
create or replace function auth.uid() returns uuid language sql stable as
  $a$ select nullif(auth.jwt()->>'sub','')::uuid $a$;
create or replace function auth.role() returns text language sql stable as
  $a$ select auth.jwt()->>'role' $a$;
create table auth.users (id uuid primary key, email text, raw_app_meta_data jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now(),
  banned_until timestamptz, last_sign_in_at timestamptz);
-- Las sesiones: el paso 3 las cierra al cambiar el rol, dar de baja o restablecer.
create table auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid not null, created_at timestamptz default now());
grant usage on schema auth to anon, authenticated, service_role;
SQL
# Las cuentas PRIMERO: funnel_agentes.user_id apunta a auth.users (bloque 1).
psql -X -q -At "$KUXTAL_DB_URL" -c "copy (select id, email, raw_app_meta_data from auth.users) to stdout" \
  | psql -X -q "$LOCAL" -c "copy auth.users(id,email,raw_app_meta_data) from stdin"
pg_dump "$KUXTAL_DB_URL" -n public --no-owner 2>/dev/null \
  | grep -vE '^(CREATE SCHEMA public;|COMMENT ON SCHEMA public)' \
  | psql -q -X -v ON_ERROR_STOP=1 "$LOCAL" >/dev/null
echo "✅ copia lista: $BASE · socios=$(psql -X -At "$LOCAL" -c 'select count(*) from socios') · cuentas=$(psql -X -At "$LOCAL" -c 'select count(*) from auth.users')"
