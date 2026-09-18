#!/bin/bash
# sondear.sh <base-local> — mide, rol por rol, qué deja hacer la RLS. Salida: rol<TAB>capacidad<TAB>valor.
# Cada sonda corre en su propia transacción con ROLLBACK: la copia no cambia.
set -uo pipefail
L="postgresql://$(whoami)@localhost:5432/${1:?base}"
ROLES="$(psql -X -At "$L" -c "select clave from funnel_roles order by clave") sinrol"
sonda() { # rol, capacidad, sql-que-devuelve-un-valor
  local rol="$1" cap="$2" q="$3" sub email claims v
  if [ "$rol" = sinrol ]; then claims='{"role":"authenticated","sub":"00000000-0000-0000-0000-00000000dead","email":"nadie@prueba.kx"}'
  else sub=$(psql -X -At "$L" -c "select md5('kx-$rol')::uuid")
       claims="{\"role\":\"authenticated\",\"sub\":\"$sub\",\"email\":\"$rol@prueba.kx\",\"app_metadata\":{\"role\":\"$rol\"}}"; fi
  v=$(psql -X -At -v ON_ERROR_STOP=1 "$L" 2>/dev/null <<SQL
begin;
select set_config('request.jwt.claims', '$claims', true);
set local role authenticated;
$q
rollback;
SQL
) || v="ERROR"
  v=$(printf '%s' "$v" | grep -vE '^(BEGIN|ROLLBACK|SET)$' | grep -v '^$' | tail -1)
  printf '%s\t%s\t%s\n' "$rol" "$cap" "${v:-ERROR}"
}
for r in $ROLES; do
  sonda "$r" socios.ver        "select count(*) from socios;"
  sonda "$r" socios.editar     "with u as (update socios set estado=estado where id=(select min(id) from public.socios) returning 1) select count(*) from u;"
  sonda "$r" socios.crear      "insert into socios(nombre) values ('prueba-rls') returning 'si';"
  sonda "$r" socios.borrar     "with d as (delete from socios where id=(select min(id) from public.socios) returning 1) select count(*) from d;"
  sonda "$r" prospectos.ver    "select coalesce(string_agg(nombre,',' order by id),'-') from funnel_prospectos where id>=900100;"
  sonda "$r" prospectos.editar "with u as (update funnel_prospectos set comentario='x' where id>=900100 returning nombre) select coalesce(string_agg(nombre,',' order by nombre),'-') from u;"
  sonda "$r" comisiones.ver    "select coalesce(string_agg(id::text,',' order by id),'-') from funnel_comisiones where id>=900200;"
  sonda "$r" reglas_comision.editar "with u as (update funnel_comision_reglas set activo=activo returning 1) select count(*) from u;"
  sonda "$r" contratos.ver     "select count(*)>=0 and exists(select 1 from funnel_reservas) from funnel_contratos;"
  sonda "$r" agentes.editar    "with u as (update funnel_agentes set peso=peso where id=900002 returning 1) select count(*) from u;"
  sonda "$r" roles.editar      "with u as (update funnel_roles set activo=activo returning 1) select count(*) from u;"
done
