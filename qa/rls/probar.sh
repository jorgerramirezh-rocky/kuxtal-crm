#!/bin/bash
# probar.sh <base-local> — aserciones del bloque 1 sobre una COPIA ya migrada y sembrada.
# Contra la copia SIN migrar tiene que fallar: así se prueba que el guardián grita.
# Cada caso corre en su transacción con ROLLBACK (los cambios de preparación incluidos).
set -uo pipefail
L="postgresql://$(whoami)@localhost:5432/${1:?base}"
FALLAS=0; N=0
claims() { [ "$1" = sinrol ] && { echo '{"role":"authenticated"}'; return; }
  [ "$1" = _servicio ] && { echo '{"role":"service_role"}'; return; }
  [ "$1" = _dueno ] && { echo '{}'; return; }
  echo "{\"role\":\"authenticated\",\"sub\":\"$(psql -X -At "$L" -c "select md5('kx-$1')::uuid")\",\"email\":\"$1@prueba.kx\",\"app_metadata\":{\"role\":\"$1\"}}"; }
# caso <nombre> <esperado> <rol> <preparación-como-dueño> <consulta-como-rol>
caso() {
  local nom="$1" esp="$2" rol="$3" prep="$4" q="$5" v
  v=$(psql -X -At -v ON_ERROR_STOP=1 "$L" 2>&1 <<SQL
begin;
$prep
select set_config('request.jwt.claims', '$(claims "$rol")', true) \gset
$( [ "$rol" = _dueno ] && echo "-- dueño: sin cambiar de rol" || { [ "$rol" = _servicio ] && echo "set local role service_role;" || echo "set local role authenticated;"; } )
$q
rollback;
SQL
) ; if printf '%s' "$v" | grep -q 'ERROR:'; then v=$(printf '%s\n' "$v" | grep -m1 'ERROR:' | sed 's/.*ERROR: */ERROR: /'); else v=$(printf '%s\n' "$v" | grep -vE '^(BEGIN|ROLLBACK|SET|UPDATE [0-9]+|INSERT 0 [0-9]+)$' | grep -v '^$' | tail -1); fi
  N=$((N+1))
  if [ "$v" = "$esp" ] || { [ "$esp" = ERROR ] && [ "${v#ERROR}" != "$v" ]; }; then echo "  ✅ $nom"; else echo "  🔴 $nom — esperaba «${esp}», dio «${v}»"; FALLAS=$((FALLAS+1)); fi
}
ATAR="update funnel_agentes set user_id=md5('kx-telemarketing')::uuid where id=900002;
      update funnel_agentes set user_id=md5('kx-otroB')::uuid where id=900003;
      update funnel_agentes set user_id=md5('kx-otroC')::uuid where id=900004;
      update funnel_agentes set user_id=md5('kx-supervisor_tmk')::uuid where id=900001;"
PROS="select coalesce(string_agg(nombre,',' order by nombre),'-') from funnel_prospectos where id>=900100;"

echo "· identidad por cuenta, no por correo"
caso "tmk atado ve SOLO lo suyo (no pX, que comparte su correo)" "pA" telemarketing "$ATAR" "$PROS"
caso "tmk atado edita SOLO lo suyo" "pA" telemarketing "$ATAR" "with u as (update funnel_prospectos set comentario='x' where id>=900100 returning nombre) select coalesce(string_agg(nombre,','),'-') from u;"
caso "tmk no se reasigna un prospecto ajeno" "ERROR" telemarketing "$ATAR" "update funnel_prospectos set tmk_id=900003 where id=900101;"
caso "tmk ve SOLO sus comisiones" "900201" telemarketing "$ATAR" "select coalesce(string_agg(id::text,','),'-') from funnel_comisiones where id>=900200;"
caso "cuenta sin agente atado no ve prospectos" "-" telemarketing "" "$PROS"
caso "cliente no ve comisiones aunque se le ate nada" "-" cliente "$ATAR" "select coalesce(string_agg(id::text,','),'-') from funnel_comisiones where id>=900200;"

echo "· equipo (supervisor sin bandera de gerente, el caso del issue #48)"
caso "supervisor_tmk ve a su equipo (A y B), no a C ni X" "pA,pB" supervisor_tmk "$ATAR update funnel_roles set es_gerente=false where clave='supervisor_tmk';" "$PROS"
caso "tmk no pide el organigrama de otro" "0" telemarketing "$ATAR" "select count(*) from funnel_ve_equipo(900001);"
caso "gerente sí puede pedir el organigrama de otro" "3" gerente_tmk "$ATAR" "select count(*) from funnel_ve_equipo(900001);"

echo "· un solo sistema de roles"
caso "no se ata un agente de rol distinto al de la cuenta" "ERROR" admin "" "update funnel_agentes set user_id=md5('kx-vendedor')::uuid where id=900002;"
caso "sí se ata cuando el rol calza (vendedor→vendedor)" "1" admin "update funnel_agentes set rol='vendedor' where id=900005;" "with u as (update funnel_agentes set user_id=md5('kx-vendedor')::uuid where id=900005 returning 1) select count(*) from u;"
caso "una cuenta no se ata a dos agentes" "ERROR" admin "$ATAR" "update funnel_agentes set user_id=md5('kx-telemarketing')::uuid where id=900005;"
caso "etiqueta de George: liner" "Liner (vendedor)" admin "" "select nombre from funnel_roles where clave='vendedor';"

caso "alta desde la pantalla ata la cuenta sola (correo + rol que calza)" "t" gerente_tmk "" "with i as (insert into funnel_agentes(nombre,rol,email,peso) values ('Nuevo','tmk','Telemarketing@prueba.kx',1) returning user_id) select coalesce(user_id = md5('kx-telemarketing')::uuid,false) from i;"
caso "alta con rol que no calza queda sin cuenta (y en avisos)" "t" gerente_tmk "" "with i as (insert into funnel_agentes(nombre,rol,email,peso) values ('Nuevo','vendedor','otrob@prueba.kx',1) returning user_id) select user_id is null from i;"
caso "alta de una cuenta que ya tiene agente activo no la roba" "t" gerente_tmk "$ATAR" "with i as (insert into funnel_agentes(nombre,rol,email,peso) values ('Dup','tmk','otrob@prueba.kx',1) returning user_id) select user_id is null from i;"
caso "el recién atado ve su prospecto (y no pX, que comparte su correo)" "pNuevo" telemarketing "insert into funnel_agentes(id,nombre,rol,email,peso) overriding system value values (900009,'Nuevo','tmk','telemarketing@prueba.kx',1); insert into funnel_prospectos(id,nombre,tmk_id) overriding system value values (900109,'pNuevo',900009);" "$PROS"

echo "· la matriz de la pestaña Roles manda"
caso "quitar ver_socios a telemarketing lo deja en 0" "0" telemarketing "update funnel_permisos set permitido=false where rol_clave='telemarketing' and permiso='ver_socios';" "select count(*) from socios;"
caso "dar editar_socios a telemarketing lo deja editar" "1" telemarketing "update funnel_permisos set permitido=true where rol_clave='telemarketing' and permiso='editar_socios';" "with u as (update socios set estado=estado where id=(select min(id) from public.socios) returning 1) select count(*) from u;"
caso "sin editar_socios telemarketing no edita" "0" telemarketing "" "with u as (update socios set estado=estado where id=(select min(id) from public.socios) returning 1) select count(*) from u;"
caso "quitar ver_comisiones a gerente_tmk: ya no ve las ajenas" "-" gerente_tmk "update funnel_permisos set permitido=false where rol_clave='gerente_tmk' and permiso='ver_comisiones';" "select coalesce(string_agg(id::text,','),'-') from funnel_comisiones where id>=900200;"
caso "quitar gestionar_comisiones a supervisor: no edita reglas" "0" supervisor "update funnel_permisos set permitido=false where rol_clave='supervisor' and permiso='gestionar_comisiones';" "with u as (update funnel_comision_reglas set activo=activo returning 1) select count(*) from u;"
caso "quitar cerrar_contrato a vendedor: no cierra" "ERROR: no autorizado" vendedor "update funnel_permisos set permitido=false where rol_clave='vendedor' and permiso='cerrar_contrato';" "select funnel_cerrar_contrato(900101,'x','x',1) is null;"
caso "rol apagado no puede nada" "f" gerente_ventas "update funnel_roles set activo=false where clave='gerente_ventas';" "select funnel_puede('editar_socios');"
caso "cambio de rol: baja del agente viejo + agente nuevo con la misma cuenta" "1" admin "$ATAR update funnel_agentes set activo=false where id=900002; update auth.users set raw_app_meta_data='{\"role\":\"vendedor\"}' where id=md5('kx-telemarketing')::uuid;" "with i as (insert into funnel_agentes(nombre,rol,email,activo,peso,user_id) values ('A liner','vendedor','telemarketing@prueba.kx',true,1,md5('kx-telemarketing')::uuid) returning 1) select count(*) from i;"
caso "telemarketing no se da permisos solo" "0" telemarketing "" "with u as (update funnel_permisos set permitido=true where rol_clave='telemarketing' and permiso='editar_socios' returning 1) select count(*) from u;"
caso "telemarketing no ve los avisos" "0" telemarketing "" "select count(*) from funnel_descalces();"
caso "un gerente sin «gestionar roles» no ve correos de login en avisos" "0" gerente_tmk "" "select count(*) from funnel_descalces();"
caso "el admin sí ve los avisos" "t" admin "" "select count(*)>0 from funnel_descalces();"
caso "el admin no se puede apagar (no se encierra)" "ERROR" admin "" "update funnel_roles set activo=false where clave='admin';"
caso "el admin no pierde «gestionar roles»" "ERROR" admin "" "update funnel_permisos set permitido=false where rol_clave='admin' and permiso='gestionar_roles';"
caso "otros roles sí se apagan" "1" admin "" "with u as (update funnel_roles set activo=false where clave='servicio' returning 1) select count(*) from u;"
caso "la vista de descalces no se lee directo" "ERROR" gerente_tmk "" "select count(*) from funnel_equipo_descalces;"

echo "· paso 3: personas (alta desde el panel)"
NUEVA="insert into auth.users(id,email,raw_app_meta_data) values (md5('kx-nueva')::uuid,'nueva@prueba.kx','{\"role\":\"telemarketing\"}');"
ALTA="$NUEVA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva Persona', 'telemarketing', 900001);"
caso "telemarketing no lista personas" "ERROR" telemarketing "" "select count(*) from funnel_personas_listar();"
caso "admin lista personas" "t" admin "" "select count(*)>0 from funnel_personas_listar();"
caso "la lista no trae cuentas de socios" "0" admin "" "select count(*) from funnel_personas_listar() where rol='cliente';"
caso "el panel sabe si puedo (telemarketing: no)" "false" telemarketing "" "select funnel_personas_puedo()->>'puede';"
caso "el panel sabe si puedo (admin: sí)" "true" admin "" "select funnel_personas_puedo()->>'puede';"
caso "una cuenta del equipo NO puede registrar (solo el servidor)" "ERROR" admin "$NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'X', 'telemarketing', null);"
caso "alta: nace su agente tmk, atado y con su jefe" "tmk|t|900001|Nueva Persona" _dueno "$ALTA" "select rol, user_id is not null, supervisor_id, nombre from funnel_agentes where email='nueva@prueba.kx' and activo;"
caso "alta: queda en la bitácora" "1" _dueno "$ALTA" "select count(*) from funnel_personas_bitacora where persona=md5('kx-nueva')::uuid and accion='alta';"
caso "el servidor SÍ puede registrar (y un alta no cierra sesiones)" "0" _servicio "$NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'X', 'telemarketing', null);"
caso "alta con un rol que la cuenta no tiene: frena" "ERROR" _servicio "$NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'X', 'vendedor', null);"
caso "alta con un jefe que no existe: frena" "ERROR" _servicio "$NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'X', 'telemarketing', 424242);"
caso "nada sobre uno mismo" "ERROR" _servicio "" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-admin')::uuid, 'desactivar');"
caso "cambiar a liner: el tmk se da de baja y nace un vendedor" "vendedor" _dueno "$ALTA update auth.users set raw_app_meta_data='{\"role\":\"vendedor\"}' where id=md5('kx-nueva')::uuid; select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'vendedor', null);" "select string_agg(rol,',') from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "cambiar el rol cierra sus sesiones" "2" _servicio "$ALTA insert into auth.sessions(user_id) values (md5('kx-nueva')::uuid),(md5('kx-nueva')::uuid); update auth.users set raw_app_meta_data='{\"role\":\"vendedor\"}' where id=md5('kx-nueva')::uuid;" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'vendedor', null);"
caso "pasar a hostess (sin rol de agente): queda sin agente activo" "0" _dueno "$ALTA update auth.users set raw_app_meta_data='{\"role\":\"recepcion\"}' where id=md5('kx-nueva')::uuid; select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'recepcion', null);" "select count(*) from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "desactivar cierra sus sesiones" "1" _dueno "$ALTA insert into auth.sessions(user_id) values (md5('kx-nueva')::uuid);" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'desactivar');"
caso "desactivar da de baja su agente" "0" _dueno "$ALTA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'desactivar');" "select count(*) from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "activar: vuelve su agente" "1" _dueno "$ALTA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'desactivar'); select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'activar');" "select count(*) from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "telemarketing no lee la bitácora" "0" telemarketing "" "select count(*) from funnel_personas_bitacora;"
caso "nadie del equipo escribe la bitácora" "ERROR" admin "" "insert into funnel_personas_bitacora(actor,persona,accion) values (md5('kx-admin')::uuid, md5('kx-admin')::uuid, 'alta');"
caso "permiso nuevo: solo admin gestiona personas" "admin" admin "" "select string_agg(rol_clave,',') from funnel_permisos where permiso='gestionar_personas' and permitido;"

echo "── $((N-FALLAS))/$N verdes"
[ "$FALLAS" -eq 0 ]
