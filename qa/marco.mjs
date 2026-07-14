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

const FN=['repartoRoundRobin','aplicarReparto','ordenarMiDia','cuerpoCita','citadosDeHoy','montoMembresia','registrarEnganche','normalizaMotivoBaja'];
const sandbox={console};
vm.createContext(sandbox);
for(const f of FN) vm.runInContext(extraer(f),sandbox);

let fail=0;
const ok=(cond,msg)=>{ console.log((cond?'  ✓ ':'  ✗ ')+msg); if(!cond) fail++; };

// ── (a) Reparto equitativo ──
console.log('\n(a) repartoRoundRobin');
{
  const ag=[{id:1,nombre:'A',rol:'tmk',activo:true,peso:1},{id:2,nombre:'B',rol:'tmk',activo:true,peso:1},{id:3,nombre:'C',rol:'tmk',activo:true,peso:1},
            {id:4,nombre:'V',rol:'vendedor',activo:true,peso:1},{id:5,nombre:'X',rol:'tmk',activo:false,peso:1}];
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
  const pes=sandbox.repartoRoundRobin(pr,[{id:1,rol:'tmk',activo:true,peso:2},{id:2,rol:'tmk',activo:true,peso:1}],0);
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

// ── (b) Mi día ──
console.log('\n(b) ordenarMiDia + cuerpoCita');
{
  const hoy='2026-07-14';
  const ls=[{id:1},{id:2,recontacto_en:'2026-07-20T09:00:00'},{id:3,recontacto_en:'2026-07-01T09:00:00'},{id:4,recontacto_en:'2026-07-14T08:00:00'},{id:5,recontacto_en:'2026-06-10T09:00:00'}];
  const o=sandbox.ordenarMiDia(ls,hoy).map(l=>l.id);
  ok(JSON.stringify(o)==='[5,3,4,2,1]', 'vencidas primero (más vieja arriba), futuras después, sin fecha al final → '+o.join(','));
  ok(sandbox.cuerpoCita('',null,'19:00').error==='Elegí el restaurante', 'sin restaurante → error');
  ok(sandbox.cuerpoCita(2,'','19:00').error==='Poné el día de la presentación', 'sin día → error');
  const c=sandbox.cuerpoCita('2','2026-07-15','18:30');
  ok(c.body.presenta_en==='2026-07-15T18:30:00'&&c.body.restaurante_id===2&&c.body.estado==='asistira', 'cita ok → presenta_en+restaurante_id+estado asistira');
  ok(sandbox.cuerpoCita(2,'2026-07-15','').body.presenta_en.endsWith('19:00:00'), 'hora default 19:00');
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
