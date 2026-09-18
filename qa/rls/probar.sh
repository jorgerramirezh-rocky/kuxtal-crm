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
LISTA="select coalesce(string_agg(nombre,',' order by nombre),'-') from funnel_tmk_mi_lista() where id>=900100;"

echo "· identidad por cuenta, no por correo"
caso "tmk atado ve SOLO lo suyo (no pX, que comparte su correo) — por su lista" "pA" telemarketing "$ATAR" "$LISTA"
caso "tmk atado no edita la tabla directo (bloque 2: solo por funnel_tmk_resultado)" "-" telemarketing "$ATAR" "with u as (update funnel_prospectos set comentario='x' where id>=900100 returning nombre) select coalesce(string_agg(nombre,','),'-') from u;"
caso "tmk no se reasigna un prospecto (no toca ninguna fila)" "0" telemarketing "$ATAR" "with u as (update funnel_prospectos set tmk_id=900003 where id=900101 returning 1) select count(*) from u;"
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
caso "el recién atado ve su prospecto (y no pX, que comparte su correo)" "pNuevo" telemarketing "insert into funnel_agentes(id,nombre,rol,email,peso) overriding system value values (900009,'Nuevo','tmk','telemarketing@prueba.kx',1); insert into funnel_prospectos(id,nombre,tmk_id) overriding system value values (900109,'pNuevo',900009);" "$LISTA"

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
LEGADO="insert into funnel_agentes(id,nombre,rol,email,activo,peso,supervisor_id) overriding system value values (900050,'Legado','tmk','nueva@prueba.kx',true,1,900001); insert into funnel_prospectos(id,nombre,tmk_id) overriding system value values (900150,'pLegado',900050);"
caso "alta de alguien que YA estaba en el equipo: adopta su agente (no crea otro)" "900050|1" _dueno "$LEGADO $NUEVA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', null);" "select min(id)||'|'||count(*) from funnel_agentes where lower(email)='nueva@prueba.kx' and activo;"
caso "el adoptado conserva su jefe si no se eligió otro" "900001" _dueno "$LEGADO $NUEVA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', null);" "select supervisor_id from funnel_agentes where id=900050;"
caso "sus prospectos de antes quedan con su cuenta nueva" "t" _dueno "$LEGADO $NUEVA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', null);" "select (select user_id from funnel_agentes a join funnel_prospectos p on p.tmk_id=a.id where p.id=900150) = md5('kx-nueva')::uuid;"
caso "dos agentes sin cuenta con el mismo correo: no adivina (frena)" "ERROR" _dueno "$LEGADO insert into funnel_agentes(nombre,rol,email,activo,peso) values ('Legado2','tmk','NUEVA@prueba.kx',true,1); $NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', null);"
caso "adoptarlo poniéndolo de su propio jefe: frena" "ERROR" _dueno "$LEGADO $NUEVA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', 900050);"
caso "cambiar el rol de una cuenta desactivada: frena (no vuelve al reparto)" "ERROR" _dueno "$ALTA update auth.users set banned_until=now()+interval '100 years', raw_app_meta_data='{\"role\":\"vendedor\"}' where id=md5('kx-nueva')::uuid;" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'vendedor', null);"
caso "se le puede QUITAR el jefe" "sin jefe" _dueno "$ALTA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'telemarketing', null, true);" "select coalesce(supervisor_id::text,'sin jefe') from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "sin pedir cambio de jefe, lo conserva" "900001" _dueno "$ALTA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'telemarketing', null);" "select supervisor_id from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "nadie es su propio jefe" "ERROR" _dueno "$ALTA" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'cambiar_rol', null, 'telemarketing', (select id from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo), true);"
caso "reenviar enlace no corta sesiones (la clave no cambió)" "0" _dueno "$ALTA insert into auth.sessions(user_id) values (md5('kx-nueva')::uuid);" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'restablecer');"
caso "alta de alguien que ya está con OTRO rol y sin cuenta: frena (no duplica)" "ERROR" _dueno "$LEGADO insert into auth.users(id,email,raw_app_meta_data) values (md5('kx-otro')::uuid,'nueva@prueba.kx','{\"role\":\"vendedor\"}');" "select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-otro')::uuid, 'alta', 'X', 'vendedor', null);"
caso "adopta aunque el correo del agente tenga espacios o mayúsculas" "900050" _dueno "$LEGADO update funnel_agentes set email='  NUEVA@prueba.kx ' where id=900050; $NUEVA select funnel_personas_registrar(md5('kx-admin')::uuid, md5('kx-nueva')::uuid, 'alta', 'Nueva', 'telemarketing', null);" "select id from funnel_agentes where user_id=md5('kx-nueva')::uuid and activo;"
caso "telemarketing no lee la bitácora" "0" telemarketing "" "select count(*) from funnel_personas_bitacora;"
caso "nadie del equipo escribe la bitácora" "ERROR" admin "" "insert into funnel_personas_bitacora(actor,persona,accion) values (md5('kx-admin')::uuid, md5('kx-admin')::uuid, 'alta');"
caso "permiso nuevo: solo admin gestiona personas" "admin" admin "" "select string_agg(rol_clave,',') from funnel_permisos where permiso='gestionar_personas' and permitido;"

echo "· bloque 2: telemarketing"
RES="select funnel_tmk_resultado"
DUE="reset role;"
SOLO3="update funnel_agentes set activo=false where rol='tmk' and id not in (900002,900003,900004);"
caso "tmk no lee la tabla directo" "-" telemarketing "$ATAR" "$PROS"
caso "su lista trae SOLO lo mínimo (sin correo, edad, tarjetas…)" "comentario,es_socio,estado,id,intentos,nombre,presenta_en,recontacto_en,restaurante_id,telefono" telemarketing "$ATAR" "select string_agg(k,',' order by k) from (select jsonb_object_keys(to_jsonb(l)) k from funnel_tmk_mi_lista() l where id=900101) s;"
caso "cuenta sin agente: lista vacía" "-" telemarketing "" "$LISTA"
caso "contestó: interesado y socio" "interesado|true" telemarketing "$ATAR" "$RES(900101,'interesado',true); select estado||'|'||es_socio from funnel_tmk_mi_lista() where id=900101;"
caso "contestó: no interesado y no socio" "no_interesado|false" telemarketing "$ATAR" "$RES(900101,'no_interesado',false); select estado||'|'||es_socio from funnel_tmk_mi_lista() where id=900101;"
caso "no anota sobre el prospecto de otro" "ERROR" telemarketing "$ATAR" "$RES(900102,'interesado');"
caso "no contestó: pasa a OTRO telemarketer activo, intento 1" "true|1|no_contesta" telemarketing "$ATAR" "$RES(900101,'no_contesta'); $DUE select (tmk_id<>900002 and tmk_id in (select id from funnel_agentes where activo and rol='tmk'))::text||'|'||intentos_sin_respuesta||'|'||estado from funnel_prospectos where id=900101;"
caso "no contestó: sale de mi lista" "-" telemarketing "$ATAR" "$RES(900101,'no_contesta'); $LISTA"
caso "no repite al que ya lo intentó (B ya llamó → le toca a C)" "900004" telemarketing "$ATAR $SOLO3 insert into funnel_eventos(prospecto_id,tipo,payload) values (900101,'no_contesta','{\"tmk_id\":900003}');" "$RES(900101,'no_contesta'); $DUE select tmk_id from funnel_prospectos where id=900101;"
caso "si ya lo intentaron todos, a otro que no sea yo" "900003" telemarketing "$ATAR update funnel_agentes set activo=false where rol='tmk' and id not in (900002,900003); insert into funnel_eventos(prospecto_id,tipo,payload) values (900101,'no_contesta','{\"tmk_id\":900003}');" "$RES(900101,'no_contesta'); $DUE select tmk_id from funnel_prospectos where id=900101;"
caso "si no hay otro telemarketer, se queda conmigo" "900002|no_contesta" telemarketing "$ATAR update funnel_agentes set activo=false where rol='tmk' and id<>900002;" "$RES(900101,'no_contesta'); $DUE select tmk_id||'|'||estado from funnel_prospectos where id=900101;"
caso "al 3er intento: no contactable (y no cambia de dueño)" "no_contactable|3|900002" telemarketing "$ATAR update funnel_prospectos set intentos_sin_respuesta=2 where id=900101;" "$RES(900101,'no_contesta'); $DUE select estado||'|'||intentos_sin_respuesta||'|'||tmk_id from funnel_prospectos where id=900101;"
caso "gerencia baja el tope a 2: al 2do intento, no contactable" "no_contactable" telemarketing "$ATAR update funnel_parametros set valor=2 where clave='tmk_intentos_max'; update funnel_prospectos set intentos_sin_respuesta=1 where id=900101;" "$RES(900101,'no_contesta'); $DUE select estado from funnel_prospectos where id=900101;"
caso "no contactable ya no aparece en la lista" "-" telemarketing "$ATAR update funnel_prospectos set estado='no_contactable' where id=900101;" "$LISTA"
caso "sobre un no contactable, el telemarketer no anota" "ERROR" telemarketing "$ATAR update funnel_prospectos set estado='no_contactable' where id=900101;" "$RES(900101,'interesado');"
caso "contestar pone los intentos en 0" "0" telemarketing "$ATAR update funnel_prospectos set intentos_sin_respuesta=2 where id=900101;" "$RES(900101,'interesado'); select intentos from funnel_tmk_mi_lista() where id=900101;"
caso "reprogramar: se queda con el MISMO, a esa hora" "recontactar|900002|true" telemarketing "$ATAR" "$RES(900101,'reprogramar',null,now()+interval '2 hours'); $DUE select estado||'|'||tmk_id||'|'||(abs(extract(epoch from recontacto_en-(now()+interval '2 hours')))<5)::text from funnel_prospectos where id=900101;"
caso "reprogramar sin fecha: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'reprogramar');"
caso "reprogramar a una hora que ya pasó: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'reprogramar',null,now()-interval '1 day');"
caso "reprogramar a más de 6 meses: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'reprogramar',null,now()+interval '1 year');"
caso "citar: restaurante + día → asistirá" "asistira" telemarketing "$ATAR" "$RES(900101,'citar',true,now()+interval '1 day',(select min(id) from funnel_restaurantes where activo)); select estado from funnel_tmk_mi_lista() where id=900101;"
caso "citar sin restaurante: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'citar',true,now()+interval '1 day');"
caso "resultado inventado: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'vendido');"
caso "nota: queda el comentario" "llamar después de las 5" telemarketing "$ATAR" "$RES(900101,'nota',null,null,null,'  llamar después de las 5 '); select comentario from funnel_tmk_mi_lista() where id=900101;"
caso "nota vacía: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'nota',null,null,null,'   ');"
caso "fuera de telemarketing (ya en sala): frena" "ERROR" telemarketing "$ATAR update funnel_prospectos set etapa='sala' where id=900101;" "$RES(900101,'interesado');"
caso "queda en la bitácora quién llamó y a quién pasó" "900002|true" telemarketing "$ATAR" "$RES(900101,'no_contesta'); $DUE select (payload->>'tmk_id')||'|'||(payload ? 'pasa_a')::text from funnel_eventos where prospecto_id=900101 and tipo='no_contesta';"
caso "supervisor (sin bandera de gerente) anota sobre su equipo" "interesado" supervisor_tmk "$ATAR update funnel_roles set es_gerente=false where clave='supervisor_tmk';" "$RES(900102,'interesado'); $DUE select estado from funnel_prospectos where id=900102;"
caso "supervisor no anota fuera de su equipo" "ERROR" supervisor_tmk "$ATAR update funnel_roles set es_gerente=false where clave='supervisor_tmk';" "$RES(900103,'interesado');"
caso "gerencia anota sobre cualquiera" "interesado" gerente_tmk "$ATAR" "$RES(900103,'interesado'); $DUE select estado from funnel_prospectos where id=900103;"
caso "tmk no cambia el tope" "0" telemarketing "$ATAR" "with u as (update funnel_parametros set valor=5 returning 1) select count(*) from u;"
caso "gerencia sí cambia el tope" "1" gerente_tmk "" "with u as (update funnel_parametros set valor=2 where clave='tmk_intentos_max' returning 1) select count(*) from u;"
caso "el tope no baja de 2 ni sube de 5" "ERROR" gerente_tmk "" "update funnel_parametros set valor=9 where clave='tmk_intentos_max';"
caso "anónimo no llama a las funciones nuevas" "false|false" _dueno "" "select has_function_privilege('anon','public.funnel_tmk_resultado(bigint,text,boolean,timestamptz,bigint,text)','execute')::text||'|'||has_function_privilege('anon','public.funnel_tmk_mi_lista()','execute')::text;"
caso "no contestó: nunca a un agente SIN cuenta (X no tiene)" "900002" telemarketing "$ATAR update funnel_agentes set activo=false where rol='tmk' and id not in (900002,900005);" "$RES(900101,'no_contesta'); $DUE select tmk_id from funnel_prospectos where id=900101;"
caso "citado y después no contestó: la cita se borra" "true" telemarketing "$ATAR" "$RES(900101,'citar',true,now()+interval '1 day',(select min(id) from funnel_restaurantes where activo)); $RES(900101,'no_contesta'); $DUE select (presenta_en is null and restaurante_id is null)::text from funnel_prospectos where id=900101;"
caso "citado y después no interesado: la cita se borra" "true" telemarketing "$ATAR" "$RES(900101,'citar',true,now()+interval '1 day',(select min(id) from funnel_restaurantes where activo)); $RES(900101,'no_interesado',false); $DUE select (presenta_en is null)::text from funnel_prospectos where id=900101;"
caso "citar a una hora que ya pasó hace 30 min: frena" "ERROR" telemarketing "$ATAR" "$RES(900101,'citar',true,now()-interval '30 minutes',(select min(id) from funnel_restaurantes where activo));"
caso "tmk no falsea la bitácora que decide la reasignación" "ERROR" telemarketing "$ATAR" "insert into funnel_eventos(prospecto_id,tipo,payload) values (900102,'no_contesta','{\"tmk_id\":900004}');"
caso "tmk sí anota que llamó o escribió (contacto) sobre lo suyo" "1" telemarketing "$ATAR" "with i as (insert into funnel_eventos(prospecto_id,tipo,actor,payload) values (900101,'contacto','telemarketing@prueba.kx','{}') returning 1) select count(*) from i;"
caso "prospecto sin dueño + no contestó (gerencia): va a alguien con cuenta" "true" gerente_tmk "$ATAR" "$RES(900105,'no_contesta'); $DUE select (tmk_id in (select id from funnel_agentes where activo and user_id is not null))::text from funnel_prospectos where id=900105;"
caso "S1: tmk no anota sobre un prospecto SIN dueño" "ERROR" telemarketing "$ATAR" "$RES(900105,'citar',true,now()+interval '1 day',(select min(id) from funnel_restaurantes where activo));"
caso "S1: tmk no se queda un prospecto sin dueño con «no contestó»" "ERROR" telemarketing "$ATAR" "$RES(900105,'no_contesta');"
caso "S1: supervisor (sin bandera) no toca prospectos sin dueño" "ERROR" supervisor_tmk "$ATAR update funnel_roles set es_gerente=false where clave='supervisor_tmk';" "$RES(900105,'interesado');"
caso "id que no existe: mismo mensaje que uno ajeno" "ERROR: no autorizado" telemarketing "$ATAR" "$RES(123456789,'interesado');"
caso "tmk no anota «contacto» sobre un prospecto ajeno" "ERROR" telemarketing "$ATAR" "insert into funnel_eventos(prospecto_id,tipo,actor,payload) values (900102,'contacto','telemarketing@prueba.kx','{}');"
caso "tmk no firma la bitácora como «sistema»" "ERROR" telemarketing "$ATAR" "insert into funnel_eventos(prospecto_id,tipo,actor,payload) values (900101,'contacto','sistema','{}');"
caso "anónimo no llama al reparto" "false" _dueno "" "select has_function_privilege('anon','public.funnel_repartir(bigint)','execute')::text;"
caso "tmk no reparte" "ERROR" telemarketing "$ATAR" "select funnel_repartir(1);"
REP9="$ATAR $SOLO3 insert into funnel_bases(id,nombre,total) overriding system value values (900301,'b9',9); insert into funnel_prospectos(nombre,base_id) select 'r'||g,900301 from generate_series(1,9) g;"
caso "reparto: nunca a un agente sin cuenta" "0" gerente_tmk "$REP9 update funnel_agentes set activo=true where id=900005;" "select funnel_repartir(900301); $DUE select count(*) from funnel_prospectos where base_id=900301 and tmk_id=900005;"
caso "reparto parejo: 9 entre 3 con cuenta → 3/3/3" "3,3,3" gerente_tmk "$REP9" "select funnel_repartir(900301); $DUE select string_agg(n::text,',') from (select count(*) n from funnel_prospectos where base_id=900301 group by tmk_id) s;"
caso "reparto al azar: 12 repartos de la misma base no salen todos iguales" "true" _dueno "$REP9" "select set_config('request.jwt.claims','{\"role\":\"authenticated\",\"app_metadata\":{\"role\":\"admin\"}}',true); do \$\$ declare i int; s text; v text[]:='{}'; begin for i in 1..12 loop update funnel_prospectos set tmk_id=null where base_id=900301; perform funnel_repartir(900301); select string_agg(tmk_id::text,',' order by id) into s from funnel_prospectos where base_id=900301; v:=array_append(v,s); end loop; perform set_config('kx.distintos',(select count(distinct x)::text from unnest(v) x),true); end \$\$; select (current_setting('kx.distintos')::int>1)::text;"

echo "── $((N-FALLAS))/$N verdes"
[ "$FALLAS" -eq 0 ]
