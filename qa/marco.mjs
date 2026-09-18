// QA del MARCO del embudo (M1): extrae las funciones REALES de app.html y las prueba
// con fetch/api stubeado — sin red, sin tocar la base. node qa/marco.mjs
import {readFileSync} from 'fs';
import vm from 'vm';

const src=readFileSync(new URL('../app.html',import.meta.url),'utf8');

// Extrae "function NOMBRE(...){...}" con llaves balanceadas (ignora llaves en strings/templates).
function extraer(nombre){
  let i=src.indexOf('function '+nombre+'(');
  if(i<0) throw new Error('no encontré function '+nombre);
  if(src.slice(i-6,i)==='async ') i-=6; // conservar el async de las funciones async
  let j=src.indexOf('{',i), depth=0, k=j, q=null;
  for(;k<src.length;k++){
    const c=src[k], p=src[k-1];
    if(q){ if(c===q&&p!=='\\') q=null; continue; }
    if(c==="'"||c==='"'||c==='`'){ q=c; continue; }
    if(c==='{') depth++;
    else if(c==='}'){ depth--; if(!depth) break; }
  }
  return src.slice(i,k+1);
}

const FN=['azarConSemilla','repartoRoundRobin','aplicarReparto','partesGT','tsGT','ordenarMiDia','cuerpoCita','paramsResultado','rpcResultado','citadosDeHoy','montoMembresia','registrarEnganche','normalizaMotivoBaja'];
const sandbox={console,TZ_GT:'America/Guatemala'};
vm.createContext(sandbox);
for(const f of FN) vm.runInContext(extraer(f),sandbox);

let fail=0;
const ok=(cond,msg)=>{ console.log((cond?'  ✓ ':'  ✗ ')+msg); if(!cond) fail++; };

// ── (a) Reparto equitativo ──
console.log('\n(a) repartoRoundRobin');
{
  const ag=[{id:1,nombre:'A',rol:'tmk',activo:true,user_id:'u1',peso:1},{id:2,nombre:'B',rol:'tmk',activo:true,user_id:'u2',peso:1},{id:3,nombre:'C',rol:'tmk',activo:true,user_id:'u3',peso:1},
            {id:4,nombre:'V',rol:'vendedor',activo:true,peso:1},{id:5,nombre:'X',rol:'tmk',activo:false,user_id:'u5',peso:1}];
  const pr=Array.from({length:10},(_,i)=>({id:i+1,nombre:'L'+(i+1),tmk_id:null}));
  const r=sandbox.repartoRoundRobin(pr,ag,0);
  const c=[r.plan[1].length,r.plan[2].length,r.plan[3].length];
  ok(JSON.stringify(c)==='[4,3,3]', '3 TMK y 10 leads → 4/3/3 (fue '+c.join('/')+')');
  ok(r.plan[4]===undefined && r.plan[5]===undefined, 'ni el vendedor ni el TMK inactivo reciben');
  ok(r.sinAsignar.length===0 && r.total===10, 'total=10, nadie sin asignar');
  const r1=sandbox.repartoRoundRobin(pr,ag,1); // re-repartir rota quién arranca
  ok(r1.plan[2][0].id===1, 'offset 1: el primer lead va al 2do TMK (re-repartir rota)');
  const ya=[{id:1,nombre:'ya',tmk_id:9}].concat(pr.slice(1));
  ok(sandbox.repartoRoundRobin(ya,ag,0).total===9, 'los que ya tienen tmk_id no se tocan');
  const sinT=sandbox.repartoRoundRobin(pr,[{id:4,rol:'vendedor',activo:true}],0);
  ok(sinT.sinAsignar.length===10, 'sin TMK activos → los 10 quedan visibles en sinAsignar');
  const pes=sandbox.repartoRoundRobin(pr,[{id:1,rol:'tmk',activo:true,user_id:'u1',peso:2},{id:2,rol:'tmk',activo:true,user_id:'u2',peso:1}],0);
  ok(pes.plan[1].length===7&&pes.plan[2].length===3, 'peso 2 vs 1 → 7/3 (mismo criterio que el RPC)');
}

// ── (a) aplicarReparto con fetch stubeado ──
console.log('\n(a) aplicarReparto (api stub)');
{
  const calls=[];
  const apiStub=async(path,opt)=>{
    calls.push({path,opt});
    if(path.startsWith('funnel_prospectos')){
      const ids=path.match(/id=in\.\(([^)]*)\)/)[1].split(',').map(Number);
      return {ok:true,json:async()=>ids.map(id=>({id}))};
    }
    return {ok:true,json:async()=>[]};
  };
  const plan={7:[{id:1},{id:2},{id:3},{id:4}],8:[{id:5},{id:6},{id:7}],9:[{id:8},{id:9},{id:10}]};
  const n=await sandbox.aplicarReparto(plan,apiStub,'qa@kuxtal');
  ok(n===10, 'devuelve 10 asignados (fue '+n+')');
  const patches=calls.filter(c=>c.opt.method==='PATCH');
  ok(patches.length===3, 'un PATCH por agente (3)');
  ok(patches.every(c=>c.path.includes('tmk_id=is.null')), 'todos los PATCH llevan el candado tmk_id=is.null');
  ok(JSON.parse(patches[0].opt.body).tmk_id===7, 'el body asigna el tmk_id correcto');
  const evs=calls.filter(c=>c.path==='funnel_eventos');
  ok(evs.length===1 && JSON.parse(evs[0].opt.body).length===10, 'bitácora: 1 POST con 10 eventos asignado');
  ok(JSON.parse(evs[0].opt.body)[0].actor==='qa@kuxtal', 'actor del evento = usuario');
}

// ── (a) aplicarReparto: falla a mitad → los ya asignados NO pierden bitácora (revisión adversaria) ──
console.log('\n(a) aplicarReparto con falla a mitad de camino');
{
  const calls=[];
  const apiStub=async(path,opt)=>{
    calls.push({path,opt});
    if(path.startsWith('funnel_prospectos')){
      const ids=path.match(/id=in\.\(([^)]*)\)/)[1].split(',').map(Number);
      if(ids.includes(5)) return {ok:false,status:500,json:async()=>[]}; // el 2do PATCH falla
      return {ok:true,json:async()=>ids.map(id=>({id}))};
    }
    return {ok:true,json:async()=>[]};
  };
  const plan={7:[{id:1},{id:2}],8:[{id:5},{id:6}]};
  let lanzo=false;
  try{ await sandbox.aplicarReparto(plan,apiStub,'qa@kuxtal'); }catch(e){ lanzo=true; }
  ok(lanzo, 'la falla del PATCH se propaga (el caller muestra el error)');
  const evs=calls.filter(c=>c.path==='funnel_eventos');
  ok(evs.length===1 && JSON.parse(evs[0].opt.body).length===2, 'los 2 ya asignados igual quedan en la bitácora (fue '+(evs.length?JSON.parse(evs[0].opt.body).length:0)+')');
}

// ── (b) Mi día ──
console.log('\n(a2) reparto al azar con semilla');
{
  const ag=[{id:1,rol:'tmk',activo:true,user_id:'u1',peso:1},{id:2,rol:'tmk',activo:true,user_id:'u2',peso:1},{id:3,rol:'tmk',activo:true,user_id:'u3',peso:1}];
  const pr=Array.from({length:30},(_,i)=>({id:i+1,tmk_id:null}));
  const firma=r=>Object.keys(r.plan).map(k=>k+':'+r.plan[k].map(p=>p.id).join('.')).join('|');
  const a=sandbox.repartoRoundRobin(pr,ag,0,12345), b=sandbox.repartoRoundRobin(pr,ag,0,12345), c=sandbox.repartoRoundRobin(pr,ag,0,999);
  ok(firma(a)===firma(b), 'misma semilla → mismo reparto (la vista previa ES lo que se guarda)');
  const conSin=sandbox.repartoRoundRobin(pr,[...ag,{id:9,rol:'tmk',activo:true,peso:1}],0,7);
  ok(!conSin.plan[9], 'un agente SIN cuenta no recibe nada (no puede abrir su lista)');
  const pr10=Array.from({length:10},(_,i)=>({id:i+1,tmk_id:null})); const cuenta={1:0,2:0,3:0};
  for(let sem=1;sem<=60;sem++){ const r=sandbox.repartoRoundRobin(pr10,ag,0,sem); for(const k of [1,2,3]) if(r.plan[k].length===4) cuenta[k]++; }
  ok(cuenta[1]>0&&cuenta[2]>0&&cuenta[3]>0, 'el que sobra no le toca siempre al mismo ('+JSON.stringify(cuenta)+')');
  ok(firma(a)!==firma(c), 'otra semilla → otro reparto (barajar de nuevo)');
  ok(firma(a)!==firma(sandbox.repartoRoundRobin(pr,ag,0)), 'con semilla no sale en orden de id');
  ok([1,2,3].every(k=>a.plan[k].length===10), 'sigue parejo: 30 entre 3 → 10/10/10');
  const ids=[].concat(a.plan[1],a.plan[2],a.plan[3]).map(p=>p.id).sort((x,y)=>x-y);
  ok(ids.length===30&&ids.every((v,i)=>v===i+1), 'nadie se pierde ni se duplica');
}

console.log('\n(b) ordenarMiDia + cuerpoCita');
{
  const hoy='2026-07-14';
  const ls=[{id:1},{id:2,recontacto_en:'2026-07-20T09:00:00'},{id:3,recontacto_en:'2026-07-01T09:00:00'},{id:4,recontacto_en:'2026-07-14T08:00:00'},{id:5,recontacto_en:'2026-06-10T09:00:00'}];
  const o=sandbox.ordenarMiDia(ls,hoy).map(l=>l.id);
  ok(JSON.stringify(o)==='[5,3,4,2,1]', 'vencidas primero (más vieja arriba), futuras después, sin fecha al final → '+o.join(','));
  ok(sandbox.cuerpoCita('',null,'19:00').error==='Elegí el restaurante', 'sin restaurante → error');
  ok(sandbox.cuerpoCita(2,'','19:00').error==='Poné el día de la presentación', 'sin día → error');
  const c=sandbox.cuerpoCita('2','2026-07-15','18:30');
  ok(c.params.p_cuando==='2026-07-15T18:30:00-06:00'&&c.params.p_restaurante===2, 'cita ok → restaurante + hora de Guatemala (−06:00)');
  ok(sandbox.cuerpoCita(2,'2026-07-15','').error==='Elegí la hora (de los horarios del lugar)', 'sin hora → pide elegirla (bloque 3: no hay hora libre)');
}

// ── (b2) Bloque 2: hora de Guatemala y resultado de la llamada ──
console.log('\n(b2) partesGT + paramsResultado + rpcResultado');
{
  // EL BUG: a las 7:30 de la noche en Guatemala ya es 01:30 del día siguiente en Londres.
  const p=sandbox.partesGT('2026-09-19T01:30:00Z');
  ok(p.d==='2026-09-18'&&p.h==='19:30', '01:30 UTC = 18-sep 19:30 en Guatemala (fue '+p.d+' '+p.h+')');
  ok(sandbox.partesGT('2026-09-18T15:00:00+00:00').h==='09:00', 'lo que viene de la base (+00:00) se muestra en hora de Guatemala');
  ok(sandbox.partesGT(null).d===''&&sandbox.partesGT('basura').d==='', 'sin fecha o fecha rota → vacío, no revienta');
  ok(sandbox.tsGT('2026-09-20','15:00')==='2026-09-20T15:00:00-06:00', 'lo que se guarda lleva la zona de Guatemala');
  ok(sandbox.partesGT(sandbox.tsGT('2026-09-20','15:00')).h==='15:00', 'ida y vuelta: 15:00 se guarda y se vuelve a ver 15:00');
  const hoyN=sandbox.ordenarMiDia([{id:1,recontacto_en:'2026-09-19T01:30:00Z'},{id:2}],'2026-09-18').map(l=>l.id);
  ok(JSON.stringify(hoyN)==='[1,2]', 'un recontacto a las 19:30 de HOY cuenta como de hoy (no de mañana)');
  const pr=sandbox.paramsResultado;
  ok(pr(5,'interesado',{}).error==='Marcá primero si ya es socio', 'interesado sin marcar socio → pide socio');
  ok(pr(5,'interesado',{socio:true}).params.p_es_socio===true, 'interesado + socio → manda es_socio');
  ok(pr(5,'no_interesado',{socio:false}).params.p_es_socio===false, 'no interesado + no socio');
  ok(pr(5,'reprogramar',{dia:'2026-09-20'}).error==='Poné la hora para volver a llamar', 'reprogramar sin hora → error');
  ok(pr(5,'reprogramar',{hora:'10:00'}).error==='Poné el día para volver a llamar', 'reprogramar sin día → error');
  ok(pr(5,'reprogramar',{dia:'2026-09-20',hora:'10:00'}).params.p_cuando==='2026-09-20T10:00:00-06:00', 'reprogramar → fecha y hora de Guatemala');
  ok(pr(5,'citar',{dia:'2026-09-20'}).error==='Elegí el restaurante', 'citar sin restaurante → error');
  ok(pr(5,'citar',{rest:'3',dia:'2026-09-20',hora:'19:00',socio:false}).params.p_restaurante===3, 'citar ok');
  ok(JSON.stringify(pr(5,'no_contesta',{}).params)==='{"p_id":5,"p_resultado":"no_contesta"}', 'no contestó no manda nada más');
  ok(pr(5,'vendido',{}).error==='Resultado desconocido', 'resultado inventado → error');
  const bien=await sandbox.rpcResultado({p_id:1},async()=>({ok:true,status:200,json:async()=>({estado:'no_contesta',intentos:1,sigue_conmigo:false})}));
  ok(bien.ok&&bien.data.sigue_conmigo===false, 'respuesta ok → datos del servidor');
  const mal=await sandbox.rpcResultado({p_id:1},async()=>({ok:false,status:400,json:async()=>({message:'esa fecha y hora ya pasó'})}));
  ok(!mal.ok&&mal.msg==='Esa fecha y hora ya pasó', 'error 400 → el motivo del servidor, con mayúscula');
  const caido=await sandbox.rpcResultado({p_id:1},async()=>({ok:false,status:503,json:async()=>({message:'detalle interno'})}));
  ok(!caido.ok&&caido.msg==='No se pudo guardar', 'error 5xx → mensaje genérico (no muestra detalle interno)');
  const red=await sandbox.rpcResultado({p_id:1},async()=>{ throw new Error('red'); });
  ok(!red.ok&&/conexión/.test(red.msg), 'sin red → avisa, no miente');
}

// ── (c) Recepción ──
console.log('\n(c) citadosDeHoy');
{
  const ls=[{id:1,presenta_en:'2026-07-14T19:00:00'},{id:2,presenta_en:'2026-07-15T19:00:00'},{id:3}];
  const h=sandbox.citadosDeHoy(ls,'2026-07-14');
  ok(h.length===1&&h[0].id===1, 'solo el citado de hoy pasa el filtro');
}

// ── (d) Contrato desde membresías ──
console.log('\n(d) montoMembresia + registrarEnganche (api stub)');
{
  ok(sandbox.montoMembresia({tipo:'Gold',precio:1000,descuento:100})===900, 'Gold precio 1000 − desc 100 → monto 900');
  ok(sandbox.montoMembresia({precio:500})===500, 'sin descuento → precio');
  ok(sandbox.montoMembresia({precio:100,descuento:150})===0, 'descuento mayor al precio → 0 (no negativo)');
  const calls=[];
  const apiStub=async(path,opt)=>{ calls.push({path,opt}); return {ok:true,json:async()=>[]}; };
  const r1=await sandbox.registrarEnganche(55,9,250,'12 cuotas',apiStub,true,'qa@kuxtal');
  ok(r1.patched&&r1.evento, 'con columna: PATCH al contrato + evento');
  ok(calls[0].path==='funnel_contratos?id=eq.55'&&JSON.parse(calls[0].opt.body).enganche===250, 'PATCH correcto a funnel_contratos.enganche');
  const evb=JSON.parse(calls[1].opt.body);
  ok(evb.tipo==='enganche'&&evb.payload.enganche===250&&evb.payload.plan_pago==='12 cuotas', 'evento con enganche y plan de pago');
  calls.length=0;
  const r2=await sandbox.registrarEnganche(55,9,250,'12 cuotas',apiStub,false,'qa@kuxtal');
  ok(!r2.patched&&r2.evento&&calls.length===1&&calls[0].path==='funnel_eventos', 'sin columna (migración no aplicada): SOLO evento, sin PATCH');
  calls.length=0;
  const r3=await sandbox.registrarEnganche(55,9,0,'x',apiStub,true,'qa');
  ok(!r3.patched&&!r3.evento&&calls.length===0, 'enganche 0/vacío → no escribe nada');
}

// ── (e) Baja ──
console.log('\n(e) normalizaMotivoBaja');
{
  ok(sandbox.normalizaMotivoBaja('')===null&&sandbox.normalizaMotivoBaja('   ')===null&&sandbox.normalizaMotivoBaja(null)===null, 'vacío/espacios/null → null (obligatorio)');
  ok(sandbox.normalizaMotivoBaja('  se mudó ')==='se mudó', 'recorta espacios');
}

console.log(fail?`\n❌ QA marco FALLÓ (${fail})`:'\n✅ QA marco OK — reparto, mi día, recepción, contrato y baja');
process.exit(fail?1:0);
