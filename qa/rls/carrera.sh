#!/bin/bash
# carrera.sh <base-migrada> — la rueda con DOS sesiones de verdad al mismo tiempo (con commit).
# Clona la base a kux_carrera (nunca toca la base de origen), deja a L1 y L2 empatados y hace
# calificar a dos clientes EN PARALELO, cada sesión esperando 1.5 s antes de su commit.
# Con candado: liners distintos. Sin candado: los dos le caen al mismo (así se probó que grita).
set -uo pipefail
ORIG="${1:?base migrada}"; C=kux_carrera
U="postgresql://$(whoami)@localhost:5432"
dropdb --if-exists "$C" >/dev/null 2>&1; createdb -T "$ORIG" "$C" || { echo "🔴 no pude clonar $ORIG"; exit 1; }
HOY="((now() at time zone 'America/Guatemala')::date)"
A_LAS="(($HOY + time '12:00') at time zone 'America/Guatemala')"
psql -X -q -v ON_ERROR_STOP=1 "$U/$C" <<SQL >/dev/null || { echo "🔴 no pude preparar"; exit 1; }
set kux.copia=si;
begin;
insert into funnel_agentes(id,nombre,rol,email,activo,peso) overriding system value values
 (900011,'H1','recepcion','recepcion@prueba.kx',true,1),(900021,'L1','vendedor','l1@prueba.kx',true,1),(900022,'L2','vendedor','l2@prueba.kx',true,1);
insert into funnel_turnos(fecha,restaurante_id,agente_id) select $HOY, min(id), a from funnel_restaurantes, unnest(array[900011,900021,900022]) a where activo group by a;
select set_config('kux.confirmando','si',true);
update funnel_prospectos set estado='asistira', etapa='telemarketing', restaurante_id=(select min(id) from funnel_restaurantes where activo),
  presenta_en=$A_LAS, cita_confirmada_en=now() where id in (900101,900102);
commit;
SQL
ADM='{"role":"authenticated","app_metadata":{"role":"admin"},"email":"admin@prueba.kx"}'
uno() { psql -X -At -v ON_ERROR_STOP=1 "$U/$C" <<SQL 2>&1 | grep -E '^[0-9]+$|ERROR' ; }
begin;
select set_config('request.jwt.claims', '$ADM', true) \gset
set local role authenticated;
select funnel_sala_calificar($1, true)->'liner'->>'agente_id';
select pg_sleep(1.5) \gset
commit;
SQL
T=$(mktemp -d)
uno 900101 > "$T/a" & uno 900102 > "$T/b" & wait
A=$(cat "$T/a"); B=$(cat "$T/b")
dropdb "$C" >/dev/null 2>&1
echo "  sesión 1 → liner $A · sesión 2 → liner $B"
if [[ "$A" =~ ^[0-9]+$ && "$B" =~ ^[0-9]+$ && "$A" != "$B" ]]; then echo "✅ carrera: dos clientes a la vez → dos liners distintos"; exit 0; fi
echo "🔴 carrera: la rueda repitió liner (o falló)"; exit 1
