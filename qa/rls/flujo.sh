#!/bin/bash
# flujo.sh <base-migrada-y-sembrada> — QA de PUNTA A PUNTA del embudo de Kuxtal, como lo vive la gente:
# telemarketer cita → supervisor confirma → gerencia arma el turno → hostess recibe y califica → la rueda da
# liner y closer → el gerente de ventas crea un segmento → el liner pide descuento → el gerente lo aprueba →
# el liner cierra → el verificador llama y verifica → comisiones liberadas a las personas correctas.
# Cada paso corre con la cuenta de ESE puesto y hace COMMIT (como en la vida real), sobre un CLON
# (kux_flujo) que se borra al final: la base de origen no se toca.
set -uo pipefail
ORIG="${1:?base migrada y sembrada}"; C=kux_flujo
U="postgresql://$(whoami)@localhost:5432"
dropdb --if-exists "$C" >/dev/null 2>&1; createdb -T "$ORIG" "$C" || { echo "🔴 no pude clonar $ORIG"; exit 1; }
FALLAS=0; N=0
claims() { echo "{\"role\":\"authenticated\",\"sub\":\"$(psql -X -At "$U/$C" -c "select md5('kx-$1')::uuid")\",\"email\":\"$1@prueba.kx\",\"app_metadata\":{\"role\":\"$1\"}}"; }
# paso <nombre> <rol> <sql> [<esperado> <consulta-de-control-como-dueño>]
paso() {
  local nom="$1" rol="$2" q="$3" esp="${4:-}" ctl="${5:-}" out v
  out=$(psql -X -At -v ON_ERROR_STOP=1 "$U/$C" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '$(claims "$rol")', true) \gset
set local role authenticated;
$q
commit;
SQL
); N=$((N+1))
  if printf '%s' "$out" | grep -q 'ERROR:'; then echo "  🔴 $nom — $(printf '%s\n' "$out" | grep -m1 'ERROR:')"; FALLAS=$((FALLAS+1)); return; fi
  if [ -n "$ctl" ]; then v=$(psql -X -At "$U/$C" -c "$ctl" 2>&1 | tail -1)
    if [ "$v" = "$esp" ]; then echo "  ✅ $nom → $v"; else echo "  🔴 ${nom} — esperaba «${esp}», dio «${v}»"; FALLAS=$((FALLAS+1)); fi
  else echo "  ✅ $nom"; fi
}
REST="(select min(id) from funnel_restaurantes where activo)"
# La cita: hoy (hora de Guatemala), en la próxima hora en punto; horario y cupo reales en el lugar.
CUANDO="((date_trunc('hour', now() at time zone 'America/Guatemala') + interval '1 hour') at time zone 'America/Guatemala')"
psql -X -q -v ON_ERROR_STOP=1 "$U/$C" <<SQL >/dev/null || { echo "🔴 no pude preparar"; exit 1; }
set kux.copia=si;
begin;
insert into auth.users(id,email,raw_app_meta_data) values
 (md5('kx-recepcion')::uuid,'recepcion@prueba.kx','{"role":"recepcion"}'),(md5('kx-vendedor')::uuid,'vendedor@prueba.kx','{"role":"vendedor"}'),
 (md5('kx-verificador')::uuid,'verificador@prueba.kx','{"role":"verificador"}'),(md5('kx-supervisor')::uuid,'supervisor@prueba.kx','{"role":"supervisor"}'),
 (md5('kx-gerente_ventas')::uuid,'gerente_ventas@prueba.kx','{"role":"gerente_ventas"}') on conflict (id) do nothing;
set local session_replication_role = replica;
update funnel_agentes set user_id=md5('kx-telemarketing')::uuid where id=900002;
update funnel_agentes set user_id=md5('kx-supervisor_tmk')::uuid where id=900001;
insert into funnel_agentes(id,nombre,rol,email,activo,peso,user_id) overriding system value values
 (900011,'Hostess H','recepcion','recepcion@prueba.kx',true,1,md5('kx-recepcion')::uuid),
 (900021,'Liner L1','vendedor','vendedor@prueba.kx',true,1,md5('kx-vendedor')::uuid),
 (900022,'Liner L2','vendedor','l2@prueba.kx',true,1,null),
 (900031,'Closer C1','cerrador','c1@prueba.kx',true,1,null),
 (900041,'Verif V1','verificador','verificador@prueba.kx',true,1,md5('kx-verificador')::uuid);
set local session_replication_role = origin;
delete from funnel_horarios where restaurante_id=$REST;
insert into funnel_horarios(restaurante_id,dia_semana,hora,cupo)
 select $REST, extract(dow from $CUANDO at time zone 'America/Guatemala')::int, ($CUANDO at time zone 'America/Guatemala')::time, 30;
insert into funnel_membresias(tipo,precio,activo) values ('QA-Oro',1000,true) on conflict (tipo) do update set precio=1000, descuento=null, activo=true;
commit;
SQL
ID=900101; CID="(select id from funnel_contratos where prospecto_id=$ID)"
SOL=0   # se lee como dueño después de pedir (la tabla está cerrada a las cuentas: así debe ser)
echo "· flujo completo, paso a paso, cada puesto con su cuenta"
paso "1 · el telemarketer cita (hoy, en horario)" telemarketing "select funnel_tmk_resultado($ID,'citar',true,$CUANDO,$REST);" "asistira|true" "select estado||'|'||(cita_confirmada_en is null)::text from funnel_prospectos where id=$ID"
paso "2 · el supervisor de TMK confirma" supervisor_tmk "select funnel_cita_confirmar($ID,$REST,$CUANDO,true,false);" "true" "select (cita_confirmada_en is not null)::text from funnel_prospectos where id=$ID"
paso "3 · el supervisor de ventas arma el turno" supervisor "select funnel_turno_poner((now() at time zone 'America/Guatemala')::date,$REST,a) from unnest(array[900011,900021,900022,900031]) a;" "4" "select count(*) from funnel_turnos"
paso "4 · la hostess ve a su cliente de hoy" recepcion "select 1;" "1" "select 1 where exists (select 1 from funnel_prospectos where id=$ID)"
paso "4b · (la lista de la hostess trae al cliente)" recepcion "do \$\$ begin if not exists (select 1 from funnel_sala_hoy() where id=$ID) then raise exception 'la hostess no ve al cliente'; end if; end \$\$;"
paso "5 · llega" recepcion "select funnel_sala_llegada($ID);" "true" "select (recepcion_en is not null)::text from funnel_prospectos where id=$ID"
paso "6 · califica → la rueda le da liner" recepcion "select funnel_sala_calificar($ID,true,40,'casado',2,'Visa');" "sala|900021" "select etapa||'|'||vendedor_id from funnel_prospectos where id=$ID"
paso "7 · pasa a closer (rueda)" recepcion "select funnel_sala_asignar($ID,'cerrador',null,0);" "900031" "select cerrador_id from funnel_prospectos where id=$ID"
paso "8 · el gerente de ventas crea un segmento de 10 %" gerente_ventas "insert into funnel_descuentos(nombre,tipo,valor) values ('QA contado','porcentaje',10);" "gerente_ventas@prueba.kx" "select creado_por from funnel_descuentos where nombre='QA contado'"
paso "9 · el liner pide el descuento" vendedor "select funnel_descuento_pedir($ID,'QA-Oro',(select id from funnel_descuentos where nombre='QA contado'));" "pendiente|100.00" "select estado||'|'||monto_descuento from funnel_descuento_solicitudes where prospecto_id=$ID order by id desc limit 1"
SOL=$(psql -X -At "$U/$C" -c "select max(id) from funnel_descuento_solicitudes where prospecto_id=$ID")
paso "10 · el gerente de ventas lo aprueba" gerente_ventas "select funnel_descuento_resolver($SOL,true);" "aprobada" "select estado from funnel_descuento_solicitudes where id=$SOL"
paso "11 · el liner cierra (el precio lo pone la base)" vendedor "select funnel_cerrar_contrato($ID,'QA-Oro','Contado',900021,900031,null,4,$SOL);" "por_verificar|900.00|socio" "select c.estado||'|'||c.monto||'|'||p.etapa from funnel_contratos c join funnel_prospectos p on p.id=c.prospecto_id where c.prospecto_id=$ID"
paso "11b · (las comisiones nacen pendientes)" vendedor "select 1;" "pendiente" "select string_agg(distinct estado,',') from funnel_comisiones where contrato_id=$CID"
paso "12 · el verificador llama y verifica" verificador "select funnel_contrato_verificar($CID,'verificado');" "verificado" "select estado from funnel_contratos where id=$CID"
paso "13 · comisiones liberadas, cada una a su persona" verificador "select 1;" "cerrador:900031:27.00,supervisor_tmk:900001:9.00,tmk:900002:18.00,vendedor:900021:27.00,verificador:900041:30.00" \
  "select string_agg(rol||':'||beneficiario_id||':'||monto,',' order by rol) from funnel_comisiones where contrato_id=$CID and estado='liberada' and beneficiario_id is not null"
paso "14 · nació el socio con el precio final" verificador "select 1;" "900.00|QA-Oro" "select s.total_num||'|'||s.tipo from socios s join funnel_prospectos p on p.socio_id=s.id where p.id=$ID"
paso "15 · la bitácora cuenta la historia completa" verificador "select 1;" "citar,cita_confirmada,llegada,sala,sala_asignado,descuento_pedido,descuento_aprobado,contrato,verificacion" \
  "select string_agg(tipo,',' order by id) from (select distinct on (tipo) id,tipo from funnel_eventos where prospecto_id=$ID order by tipo,id) x"
dropdb "$C" >/dev/null 2>&1
echo "── $((N-FALLAS))/$N pasos verdes"
[ "$FALLAS" -eq 0 ]
