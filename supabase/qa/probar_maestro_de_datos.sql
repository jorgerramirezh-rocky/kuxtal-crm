-- PRUEBA DEL GUARDIÁN · maestro de datos · corre ENTERA dentro de una transacción y termina en ROLLBACK.
-- No deja nada en la base. Cada bloque REINTRODUCE un defecto a propósito y confirma que rebota.
-- Si un candado no grita, la prueba falla con "FALLÓ:" y el rollback deshace todo igual.
begin;

-- Base y dos prospectos de prueba (teléfonos ficticios de la serie 5999xxxx)
insert into public.funnel_bases (nombre, tipo, total, activa, codigo, consentimiento, telefonos_unicos, personas_nuevas, costo)
  values ('PRUEBA_GUARDIAN', 'prueba', 2, true, 'KX-TEST', 'SI', 2, 2, 20);
do $$
declare v_base bigint; v_p1 bigint; v_p2 bigint; v_ok int := 0; v_err text;
begin
  select id into v_base from public.funnel_bases where codigo = 'KX-TEST';

  -- T1 · el teléfono se normaliza al entrar ("+502 5999-0001" -> "59990001")
  insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Prueba Uno', '+502 5999-0001', 'nuevo', 'telemarketing') returning id into v_p1;
  if (select telefono from public.funnel_prospectos where id = v_p1) <> '59990001' then raise exception 'FALLÓ T1: no normalizó el teléfono'; end if;
  v_ok := v_ok + 1;

  -- T2 · una persona = una fila: el mismo teléfono otra vez REBOTA
  begin
    insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Prueba Uno Bis', '59990001', 'nuevo', 'telemarketing');
    raise exception 'FALLÓ T2: dejó entrar un teléfono duplicado';
  exception when unique_violation then v_ok := v_ok + 1; end;

  -- T3 · teléfono inválido REBOTA (9 dígitos)
  begin
    insert into public.funnel_prospectos (base_id, nombre, telefono, estado, etapa) values (v_base, 'Prueba Mala', '599900019', 'nuevo', 'telemarketing');
    raise exception 'FALLÓ T3: dejó entrar un teléfono de 9 dígitos';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T4 · una gestión "no_contesta" sube intentos y agenda recontacto en ~4h
  insert into public.funnel_gestiones (prospecto_id, disposicion, telefono_marcado) values (v_p1, 'no_contesta', '59990001');
  if (select intentos from public.funnel_prospectos where id = v_p1) <> 1 then raise exception 'FALLÓ T4: no sumó el intento'; end if;
  if (select recontacto_en from public.funnel_prospectos where id = v_p1) not between now() + interval '3 hours' and now() + interval '5 hours' then raise exception 'FALLÓ T4: recontacto mal agendado'; end if;
  v_ok := v_ok + 1;

  -- T5 · la gestión "no_llamar" mete a la lista y BLOQUEA al prospecto (sin TMK, estado no_llamar)
  update public.funnel_prospectos set tmk_id = (select id from public.funnel_agentes limit 1) where id = v_p1;
  insert into public.funnel_gestiones (prospecto_id, disposicion) values (v_p1, 'no_llamar');
  if not exists (select 1 from public.funnel_no_llamar where telefono = '59990001') then raise exception 'FALLÓ T5: no entró a la lista'; end if;
  if (select no_llamar from public.funnel_prospectos where id = v_p1) is not true then raise exception 'FALLÓ T5: el prospecto no quedó bloqueado'; end if;
  if (select tmk_id from public.funnel_prospectos where id = v_p1) is not null then raise exception 'FALLÓ T5: sigue asignado a un TMK'; end if;
  v_ok := v_ok + 1;

  -- T6 · CANDADO: intentar desbloquear al prospecto REBOTA
  begin
    update public.funnel_prospectos set no_llamar = false where id = v_p1;
    raise exception 'FALLÓ T6: dejó revertir NO LLAMAR en el prospecto';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T7 · CANDADO: asignarle un TMK a un bloqueado REBOTA
  begin
    update public.funnel_prospectos set tmk_id = (select id from public.funnel_agentes limit 1) where id = v_p1;
    raise exception 'FALLÓ T7: dejó asignar TMK a un NO LLAMAR';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T8 · CANDADO: borrar de la lista REBOTA
  begin
    delete from public.funnel_no_llamar where telefono = '59990001';
    raise exception 'FALLÓ T8: dejó borrar de la lista NO LLAMAR';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T9 · CANDADO: editar la lista REBOTA
  begin
    update public.funnel_no_llamar set motivo = 'x' where telefono = '59990001';
    raise exception 'FALLÓ T9: dejó editar la lista NO LLAMAR';
  exception when check_violation then v_ok := v_ok + 1; end;

  -- T10 · si mañana llega una base nueva con ese teléfono (o como alterno), la persona NACE bloqueada
  insert into public.funnel_no_llamar (telefono, motivo) values ('59990002', 'pidio_no_ser_contactado');
  insert into public.funnel_prospectos (base_id, nombre, telefono, telefonos_alt, estado, etapa) values (v_base, 'Prueba Dos', '59990003', '{59990002}', 'nuevo', 'telemarketing') returning id into v_p2;
  if (select no_llamar from public.funnel_prospectos where id = v_p2) is not true then raise exception 'FALLÓ T10: entró sin bloqueo teniendo un alterno en la lista'; end if;
  v_ok := v_ok + 1;

  -- T11 · la vista mide: 1 base, 1 marcado, 2 llamadas, penetración 50%
  if (select marcados from public.funnel_desempeno_bases where codigo = 'KX-TEST') <> 1 then raise exception 'FALLÓ T11: la vista no cuenta marcados'; end if;
  if (select llamadas from public.funnel_desempeno_bases where codigo = 'KX-TEST') <> 2 then raise exception 'FALLÓ T11: la vista no cuenta llamadas'; end if;
  v_ok := v_ok + 1;

  raise notice 'GUARDIÁN OK: % de 11 candados gritaron como debían', v_ok;
end $$;

rollback;
