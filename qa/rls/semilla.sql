-- semilla.sql — datos de PRUEBA para la copia local (nunca para la base viva).
-- Una cuenta por rol (sub = uuid fijo por rol, correo <rol>@prueba.kx) y un equipo mínimo:
--   S  = supervisor_tmk (cuenta del rol supervisor_tmk)
--   A  = tmk de la cuenta telemarketing, reporta a S
--   B  = tmk de OTRA cuenta, reporta a S
--   C  = tmk de otra cuenta, SIN jefe (fuera del equipo de S)
--   X  = fila de agente con el CORREO de la cuenta telemarketing pero sin cuenta propia
--        (el caso «correo repetido / cambiado»): no debe regalarle nada a nadie.
do $s$
declare r record;
begin
  if current_setting('kux.copia', true) is distinct from 'si' then
    raise exception 'semilla.sql solo corre en una copia (set kux.copia=si)';
  end if;
  for r in select clave from funnel_roles loop
    insert into auth.users(id,email,raw_app_meta_data)
    values (md5('kx-'||r.clave)::uuid, r.clave||'@prueba.kx', jsonb_build_object('role', r.clave))
    on conflict (id) do nothing;
  end loop;
  insert into auth.users(id,email,raw_app_meta_data) values
    (md5('kx-otroB')::uuid,'otrob@prueba.kx','{"role":"telemarketing"}'),
    (md5('kx-otroC')::uuid,'otroc@prueba.kx','{"role":"telemarketing"}')
  on conflict (id) do nothing;
end $s$;

-- Los agentes entran como FILAS VIEJAS (sin cuenta), sin disparar triggers: así la semilla deja el
-- mismo punto de partida en una base migrada o sin migrar (en una migrada, «atar» ataría a A al insertarlo).
set local session_replication_role = replica;
insert into funnel_agentes(id,nombre,rol,email,activo,peso,supervisor_id,user_id) overriding system value values
 (900001,'S prueba','supervisor_tmk','supervisor_tmk@prueba.kx',true,1,null,null),
 (900002,'A prueba','tmk','telemarketing@prueba.kx',true,1,900001,null),
 (900003,'B prueba','tmk','otrob@prueba.kx',true,1,900001,null),
 (900004,'C prueba','tmk','otroc@prueba.kx',true,1,null,null),
 (900005,'X prueba','tmk','TELEMARKETING@prueba.kx',true,1,null,null);

set local session_replication_role = origin;
insert into funnel_prospectos(id,nombre,tmk_id) overriding system value values
 (900101,'pA',900002),(900102,'pB',900003),(900103,'pC',900004),(900104,'pX',900005),(900105,'pSin',null);

insert into funnel_comisiones(id,rol,beneficiario_id,monto) overriding system value values
 (900201,'tmk',900002,10),(900202,'tmk',900003,10);
