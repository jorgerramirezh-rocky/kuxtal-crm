-- PRUEBA DEL GUARDIÁN v2 · maestro de datos · corre ENTERA en una transacción y termina en ROLLBACK.
-- Reintroduce defectos a propósito Y simula roles reales (TMK y gerente por JWT) para probar la RLS.
-- Si un candado no grita, falla con "FALLÓ Tn" y el rollback deshace todo igual.
begin;

-- Setup: un TMK y un gerente de prueba, una base, la cédula
insert into public.funnel_agentes (nombre, rol, email, activo) values ('TMK Prueba', 'tmk', 'tmk.prueba@kuxtal.test', true);
insert into public.funnel_agentes (nombre, rol, email, activo) values ('TMK Rival',  'tmk', 'tmk.rival@kuxtal.test',  true);
insert into public.funnel_bases (nombre, tipo, total, activa, codigo, consentimiento, telefonos_unicos, personas_nuevas)
  values ('PRUEBA_GUARDIAN', 'prueba', 0, true, 'KX-TEST', 'SI', 3, 3);
insert into public.funnel_bases_cedula (base_id, costo, proveedor, dueno) select id, 300, 'Proveedor Prueba', 'Dueno Prueba' from public.funnel_bases where codigo = 'KX-TEST';

do $$
declare v_base bigint; v_tmk bigint; v_rival bigint; v_p1 bigint; v_p2 bigint; v_p3 bigint; v_ok int := 0; r record; n int;
  jwt_tmk    text := '{"email":"tmk.prueba@kuxtal.test","app_metadata":{"role":"telemarketing"},"role":"authenticated"}';
  jwt_rival  text := '{"email":"tmk.rival@kuxtal.test","app_metadata":{"role":"telemarketing"},"role":"authenticated"}';
  jwt_ger    text := '{"email":"gerente.prueba@kuxtal.test","app_metadata":{"role":"gerente_general"},"role":"authenticated"}';
begin
  select id into v_base from public.funnel_bases where codigo = 'KX-TEST';
  select id into v_tmk from public.funnel_agentes where email = 'tmk.prueba@kuxtal.test';
  select id into v_rival from public.funnel_agentes where email = 'tmk.rival@kuxtal.test';
  if v_tmk is null or v_rival is null then raise exception 'FALLÓ setup: sin agentes de prueba'; end if;

  -- T1 · normaliza principal y alternos; teléfono vacío queda NULL (no rebota la carga)
  insert into public.funnel_prospectos (base_id, nombre, telefono, telefonos_alt, estado, etapa, tmk_id)
    values (v_base, 'Prueba Uno', '+502 5999-0001', array['(502) 2999 0009', 'basura', '5999-0001'], 'nuevo', 'telemarketing', v_tmk) returning id into v_p1;
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.telefono <> '59990001' or r.telefonos_alt <> array['29990009'] or r.tipo_linea <> 'MOVIL' then raise exception 'FALLÓ T1: normalización % %', r.telefono, r.telefonos_alt; end if;
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Sin Tel', '', 'nuevo', 'telemarketing') returning id into v_p3;
  if (select telefono from public.funnel_prospectos where id = v_p3) is not null then raise exception 'FALLÓ T1b: teléfono vacío debía ser NULL'; end if;
  v_ok := v_ok + 1;

  -- T2 · duplicado REBOTA; T3 · 9 dígitos REBOTA
  begin
    insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Bis', '59990001', 'nuevo', 'telemarketing');
    raise exception 'FALLÓ T2: dejó entrar un teléfono duplicado';
  exception when unique_violation then v_ok := v_ok + 1; end;
  begin
    insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Mala', '599900019', 'nuevo', 'telemarketing');
    raise exception 'FALLÓ T3: dejó entrar 9 dígitos';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T4 · el TMK (por JWT) registra no_contesta: intentos=1, recontacto ~4h, tmk_id/base_id/creado_por los pone el servidor aunque mande otros
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  insert into public.funnel_gestiones (prospecto_id, disposicion, telefono_marcado) values (v_p1, 'no_contesta', '59990001');
  execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  select * into r from public.funnel_gestiones where prospecto_id = v_p1 order by id desc limit 1;
  if r.tmk_id <> v_tmk or r.base_id <> v_base or r.creado_por <> 'tmk.prueba@kuxtal.test' then raise exception 'FALLÓ T4: el servidor no fijó tmk/base/creado_por (% % %)', r.tmk_id, r.base_id, r.creado_por; end if;
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.intentos <> 1 or r.estado <> 'no_contesta' or r.recontacto_en not between now() + interval '3 hours' and now() + interval '5 hours' then raise exception 'FALLÓ T4: no aplicó la gestión'; end if;
  v_ok := v_ok + 1;

  -- T5 · el RIVAL no puede registrar gestión sobre un prospecto ajeno (RLS)
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_rival, true);
  begin
    insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p1, 'no_contesta');
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T5: un TMK rival registró gestión ajena';
  exception when insufficient_privilege or check_violation then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;

  -- T6 · el RIVAL no puede leer lo sensible ni la lista NO LLAMAR ni la cédula (0 filas, no error)
  insert into public.funnel_prospectos_sensible (prospecto_id, dpi, ingreso_estimado) values (v_p1, '1234567890123', 15000);
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_rival, true);
  select count(*) into n from public.funnel_prospectos_sensible; if n <> 0 then execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T6: TMK lee datos sensibles (%)', n; end if;
  select count(*) into n from public.funnel_bases_cedula; if n <> 0 then execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T6: TMK lee la cédula/costo'; end if;
  select costo into r from public.funnel_desempeno_bases where codigo = 'KX-TEST'; if r.costo is not null then execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T6: la vista filtra el costo al TMK'; end if;
  execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1;

  -- T7 · el TMK NO puede escribir directo en la lista NO LLAMAR (anti-sabotaje)
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    insert into public.funnel_no_llamar (telefono, motivo) values ('59990002', 'pidio_no_ser_contactado');
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T7: un TMK escribió directo en NO LLAMAR';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;

  -- T8 · el TMK DUEÑO sí puede disponer no_llamar por gestión → lista + bloqueo + sin TMK
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p1, 'no_llamar');
  execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  if not exists (select 1 from public.funnel_no_llamar where telefono = '59990001') then raise exception 'FALLÓ T8: no entró a la lista'; end if;
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.no_llamar is not true or r.tmk_id is not null or r.estado <> 'no_llamar' then raise exception 'FALLÓ T8: no quedó bloqueado'; end if;
  v_ok := v_ok + 1;

  -- T9 · CANDADOS sobre el bloqueado: revertir, asignar, cambiar estado, gestionar → todo REBOTA
  begin update public.funnel_prospectos set no_llamar = false where id = v_p1; raise exception 'FALLÓ T9a: revirtió no_llamar';
  exception when check_violation then v_ok := v_ok + 1; end;
  begin update public.funnel_prospectos set tmk_id = v_tmk where id = v_p1; raise exception 'FALLÓ T9b: asignó TMK a bloqueado';
  exception when check_violation then null; end;
  begin update public.funnel_prospectos set estado = 'nuevo' where id = v_p1; raise exception 'FALLÓ T9c: cambió estado de bloqueado';
  exception when check_violation then null; end;
  begin insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p1, 'no_contesta'); raise exception 'FALLÓ T9d: gestionó a un bloqueado';
  exception when check_violation then null; end;

  -- T10 · la lista no se edita ni se borra sin rectificación (ni como gerente)
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  begin update public.funnel_no_llamar set motivo = 'otro' where telefono = '59990001'; execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T10a: editó la lista';
  exception when check_violation or insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  begin delete from public.funnel_no_llamar where telefono = '59990001'; execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T10b: borró sin rectificación';
  exception when check_violation then execute 'reset role'; perform set_config('request.jwt.claims', '', true); null; end;

  -- T11 · no se puede poner no_llamar=true "a mano" sin fila en la lista
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Prueba Dos', '59990003', 'nuevo', 'telemarketing') returning id into v_p2;
  begin update public.funnel_prospectos set no_llamar = true, tmk_id = null where id = v_p2; raise exception 'FALLÓ T11: bloqueo a mano sin lista';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T12 · alterno compartido NO bloquea a terceros: los marca "revisar"
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  insert into public.funnel_no_llamar (telefono, motivo) values ('29990009', 'pidio_no_ser_contactado');   -- el fijo de la casa (alterno de p1)
  execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  insert into public.funnel_prospectos (base_id, nombre, telefono, telefonos_alt, estado, etapa) values (v_base, 'Vecina', '59990004', array['29990009'], 'nuevo', 'telemarketing') returning id into v_p3;
  select * into r from public.funnel_prospectos where id = v_p3;
  if r.no_llamar then raise exception 'FALLÓ T12: bloqueó a una tercera por un alterno compartido'; end if;
  if not r.revisar_no_llamar then raise exception 'FALLÓ T12: no marcó revisar_no_llamar'; end if;
  v_ok := v_ok + 1;

  -- T13 · RECTIFICACIÓN auditada de gerencia: con fila en rectificaciones, el DELETE sí pasa y desbloquea
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  insert into public.funnel_no_llamar_rectificaciones (telefono, motivo, autorizado_por) values ('59990001', 'error de captura, la persona lo pidió', 'gerente.prueba@kuxtal.test');
  delete from public.funnel_no_llamar where telefono = '59990001';
  execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.no_llamar or exists (select 1 from public.funnel_no_llamar where telefono = '59990001') then raise exception 'FALLÓ T13: la rectificación no desbloqueó'; end if;
  if r.estado <> 'no_contesta' or r.tmk_id <> v_tmk then raise exception 'FALLÓ T13: no restauró estado/tmk previos (% %)', r.estado, r.tmk_id; end if;
  -- la misma rectificación NO sirve dos veces
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  insert into public.funnel_no_llamar (telefono, motivo) values ('59990001', 'otro');
  begin delete from public.funnel_no_llamar where telefono = '59990001'; execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T13b: la rectificación se reutilizó';
  exception when check_violation then execute 'reset role'; perform set_config('request.jwt.claims', '', true); null; end;
  insert into public.funnel_no_llamar_rectificaciones (telefono, motivo, autorizado_por) values ('59990001', 'segunda', 'gerente.prueba@kuxtal.test');
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  delete from public.funnel_no_llamar where telefono = '59990001'; execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  v_ok := v_ok + 1;

  -- T14 · tope anti-sabotaje: las altas por hora se cortan (tope = las que ya lleva el gerente + 2)
  select count(*) into n from public.funnel_no_llamar where registrado_por = 'gerente.prueba@kuxtal.test' and registrado_en > now() - interval '1 hour';
  update public.funnel_parametros set valor = (n + 2)::text where clave = 'tope_no_llamar_hora';
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  insert into public.funnel_no_llamar (telefono, motivo) values ('59990005', 'otro');
  insert into public.funnel_no_llamar (telefono, motivo) values ('59990006', 'otro');
  begin insert into public.funnel_no_llamar (telefono, motivo) values ('59990007', 'otro'); execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T14: no aplicó el tope por hora';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;

  -- T15 · tope de intentos: al 7º sin-contacto la persona queda AGOTADA
  update public.funnel_prospectos set intentos = 6, tmk_id = v_tmk where id = v_p2;
  insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p2, 'no_contesta');
  select * into r from public.funnel_prospectos where id = v_p2;
  if r.estado <> 'agotado' or r.recontacto_en is not null then raise exception 'FALLÓ T15: no agotó (%)', r.estado; end if;
  v_ok := v_ok + 1;

  -- T16 · PUENTE: la pantalla vieja hace PATCH estado → nace la gestión sola (sin recursión)
  update public.funnel_prospectos set estado = 'interesado' where id = v_p3;
  select count(*) into n from public.funnel_gestiones where prospecto_id = v_p3 and disposicion = 'interesado';
  if n <> 1 then raise exception 'FALLÓ T16: puente generó % gestiones', n; end if;
  if (select intentos from public.funnel_prospectos where id = v_p3) <> 1 then raise exception 'FALLÓ T16: el puente no aplicó intentos'; end if;
  v_ok := v_ok + 1;

  -- T17 · RECEPCIÓN manda: recepcion_en → gestión 'asistio' y la vista cuenta asistencia
  update public.funnel_prospectos set recepcion_en = now(), recepcionado_por = 'recepcion.prueba' where id = v_p3;
  if not exists (select 1 from public.funnel_gestiones where prospecto_id = v_p3 and disposicion = 'asistio') then raise exception 'FALLÓ T17: recepción no generó asistio'; end if;
  select * into r from public.funnel_desempeno_bases where codigo = 'KX-TEST';
  if r.asistieron <> 1 or r.marcados < 2 or r.veredicto_p6 <> 'SIN MUESTRA' then raise exception 'FALLÓ T17: vista asistieron=% marcados=% veredicto=%', r.asistieron, r.marcados, r.veredicto_p6; end if;
  v_ok := v_ok + 1;

  -- T18 · disposición previa de base vieja: NO_INTERESADO entra descansando 30 días; NO_LLAMAR entra bloqueado
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa, disposicion_previa) values (v_base, 'Viejo No', '59990010', 'nuevo', 'telemarketing', 'NO_INTERESADO') returning id into v_p2;
  select * into r from public.funnel_prospectos where id = v_p2;
  if r.estado <> 'no_interesado' or r.recontacto_en < now() + interval '29 days' then raise exception 'FALLÓ T18a: NO_INTERESADO previo no descansó'; end if;
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa, disposicion_previa) values (v_base, 'Viejo NL', '59990011', 'nuevo', 'telemarketing', 'NO_LLAMAR') returning id into v_p2;
  if (select no_llamar from public.funnel_prospectos where id = v_p2) is not true or not exists (select 1 from public.funnel_no_llamar where telefono = '59990011') then raise exception 'FALLÓ T18b: NO_LLAMAR previo no bloqueó'; end if;
  v_ok := v_ok + 1;

  -- T19 · funnel_ingestar: un teléfono repetido NO rebota: enriquece y suma la base al linaje (Decisión 4)
  select * into r from public.funnel_ingestar(v_base, '[{"nombre":"Prueba Uno Largo Nombre","telefono":"5999 0001","email":"uno@x.test","dpi":"9999999999999"},{"nombre":"Nuevo","telefono":"59990020","fuentes_todas":["KX-0001"]},{"nombre":"Sin","telefono":""}]'::jsonb);
  if r.insertados <> 1 or r.enriquecidos <> 1 or r.sin_telefono <> 1 then raise exception 'FALLÓ T19: ingestar ins=% enr=% sin=%', r.insertados, r.enriquecidos, r.sin_telefono; end if;
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.email <> 'uno@x.test' or not (r.fuentes_todas @> array['KX-TEST']) then raise exception 'FALLÓ T19: no enriqueció / no sumó linaje'; end if;
  if (select fuentes_todas[1] from public.funnel_prospectos where telefono = '59990020') <> 'KX-0001' then raise exception 'FALLÓ T19: perdió la primera fuente'; end if;
  v_ok := v_ok + 1;

  -- T20 · ATAQUE A12#1: el TMK dueño manda telefono_marcado AJENO en una gestión no_llamar → REBOTA (no bloquea a terceros)
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa, tmk_id) values (v_base, 'Mio', '59990030', 'nuevo', 'telemarketing', v_tmk) returning id into v_p2;
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa, tmk_id) values (v_base, 'Del rival', '59990031', 'nuevo', 'telemarketing', v_rival) returning id into v_p3;
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    insert into public.funnel_gestiones (prospecto_id, disposicion, telefono_marcado) values (v_p2, 'no_llamar', '59990031');
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T20: bloqueó un número ajeno vía telefono_marcado';
  exception when check_violation then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;
  if (select no_llamar from public.funnel_prospectos where id = v_p3) then raise exception 'FALLÓ T20: el del rival quedó bloqueado'; end if;

  -- T21 · ATAQUE A12#4: el TMK resetea intentos / cambia linaje por PATCH → REBOTA
  update public.funnel_prospectos set intentos = 3 where id = v_p2;
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    update public.funnel_prospectos set intentos = 0 where id = v_p2;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T21: TMK reseteó intentos';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    update public.funnel_prospectos set fuentes_todas = array['B99'] where id = v_p2;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T21b: TMK cambió la atribución';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); null; end;

  -- T22 · ATAQUE A12#9: el TMK pone 'asistio' o 'fallecido' por gestión → REBOTA
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p2, 'asistio');
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T22: TMK marcó asistio';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;

  -- T23 · ATAQUE A12#2: gestiones no_llamar del mismo TMK en una hora → el tope corta (tope = las que ya lleva + 2)
  select count(*) into n from public.funnel_no_llamar where registrado_por = 'tmk.prueba@kuxtal.test' and registrado_en > now() - interval '1 hour';
  update public.funnel_parametros set valor = (n + 1)::text where clave = 'tope_no_llamar_hora';   -- la siguiente pasa, la que sigue rebota
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p2, 'no_llamar');   -- 1ª del tmk: pasa
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  exception when others then execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T23 setup: %', sqlerrm; end;
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa, tmk_id) values (v_base, 'Tercero', '59990032', 'nuevo', 'telemarketing', v_tmk) returning id into v_p3;
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_tmk, true);
  begin
    insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p3, 'no_llamar');   -- 3ª: tope
    execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T23: el tope no aplicó a la vía de gestión';
  exception when insufficient_privilege then execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1; end;

  -- T24 · A12#3: Recepción marca llegada y la persona NO se pierde (etapa/estado intactos)
  update public.funnel_prospectos set estado = 'asistira', etapa = 'presentacion' where id = v_p1;
  update public.funnel_prospectos set recepcion_en = now(), recepcionado_por = 'recep' where id = v_p1;
  select * into r from public.funnel_prospectos where id = v_p1;
  if r.estado <> 'asistira' or r.etapa <> 'presentacion' then raise exception 'FALLÓ T24: asistio movió estado/etapa (% %)', r.estado, r.etapa; end if;
  v_ok := v_ok + 1;

  -- T25 · A12#6: esta_bloqueado entiende +502 (como staff)
  execute 'set local role authenticated'; perform set_config('request.jwt.claims', jwt_ger, true);
  if not funnel_esta_bloqueado('+502 2999-0009') then execute 'reset role'; perform set_config('request.jwt.claims', '', true); raise exception 'FALLÓ T25: esta_bloqueado no normaliza +502'; end if;
  execute 'reset role'; perform set_config('request.jwt.claims', '', true); v_ok := v_ok + 1;

  -- T26 · A12#5: ingestar tolera una fila mala sin tirar el lote, y reporta el error
  select * into r from public.funnel_ingestar(v_base, '[{"nombre":"Bien","telefono":"59990040"},{"nombre":"Mal","telefono":"59990041","edad":"treinta"}]'::jsonb);
  if r.insertados <> 1 or jsonb_array_length(r.errores) <> 1 then raise exception 'FALLÓ T26: ins=% errores=%', r.insertados, r.errores; end if;
  v_ok := v_ok + 1;

  raise notice 'GUARDIÁN OK: % bloques verdes', v_ok;
end $$;

rollback;
