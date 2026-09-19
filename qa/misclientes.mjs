// QA del bloque 7 («mis clientes»: cada quien ve lo suyo) SIN navegador: funciones REALES de app.html con la
// base simulada. Mide: en qué paso va cada cliente, el escapado, las pestañas por puesto (liner y closer: Mis
// clientes y Cierre; reservas solo con el permiso) y que el verificador lo asigna solo la gerencia.
// node qa/misclientes.mjs
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
const src = readFileSync(new URL('../app.html', import.meta.url), 'utf8')
function extraer(nombre) {
  let i = src.indexOf('function ' + nombre + '(')
  if (i < 0) throw new Error('no encontré function ' + nombre)
  if (src.slice(i - 6, i) === 'async ') i -= 6
  let j = src.indexOf('{', i), depth = 0, k = j, q = null
  for (; k < src.length; k++) {
    const c = src[k], p = src[k - 1]
    if (q) { if (c === q && p !== '\\') q = null; continue }
    if (c === "'" || c === '"' || c === '`') { q = c; continue }
    if (c === '{') depth++
    else if (c === '}') { depth--; if (!depth) break }
  }
  return src.slice(i, k + 1)
}
const linea = (ini) => { const i = src.indexOf(ini); if (i < 0) throw new Error('no encontré ' + ini); return src.slice(i, src.indexOf('\n', i)) }
let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }
const llamadas = []
let respuesta = () => ({ ok: true, status: 200, json: async () => ([]) })
const ctx = { console, TZ_GT: 'America/Guatemala', llamadas }
vm.createContext(ctx)
vm.runInContext([
  linea('const esc='), linea('const usd='), linea('const horaGT='),
  "var toasts=[], el={}, MIS_PERMISOS={}, ROLE='', verTodo=false, esGerente=false, funTab='', AGENTES=[{id:41,nombre:'Vera <b>',rol:'verificador',activo:true},{id:42,nombre:'V2',rol:'verificador',activo:true}], VNOTA={}, VERIF=[];",
  "function $(id){ return el[id]||null; } function toast(m){ toasts.push(m); } async function vistaVerificacion(){}",
  "var api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };",
  linea('const cuandoGT='), "function hoyStr(){ return '2026-09-19'; } async function funIrTab(){}",
  ...['partesGT', 'rpcSala', 'pasoCliente', 'tonoPaso', 'misClienteCard', 'vistaMisClientes', 'verifCard', 'asignarVerificador', 'funPintarTabs'].map(extraer),
].join('\n'), ctx)
ctx.respuesta = () => respuesta()
vm.runInContext('var respuesta=this.respuesta; api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };', ctx)

const P = (o) => ctx.pasoCliente(o)
ok(P({ etapa: 'sala', closer: null }) === 'En sala · falta closer' && P({ etapa: 'sala', closer: 'C' }) === 'En sala · con closer', 'en sala: con o sin closer')
ok(P({ etapa: 'sala', descuento: 'pendiente' }) === 'En sala · descuento esperando al gerente', 'descuento pendiente')
ok(P({ etapa: 'socio', contrato: 'por_verificar' }) === 'Cerrado · falta verificar' && P({ contrato: 'verificado' }) === 'Contrato verificado' && P({ contrato: 'cancelado' }) === 'Se arrepintió', 'cerrado, verificado, se arrepintió')
ok(P({ etapa: 'baja' }) === 'No calificó / baja' && P({ etapa: 'telemarketing' }) === 'Por llegar', 'baja y por llegar')

ctx.el.funCap = {}; ctx.el.funCont = { innerHTML: '' }
respuesta = () => ({ ok: true, status: 200, json: async () => ([{ id: 1, nombre: 'Ana <img src=x>', telefono: '55', recepcion_en: '2026-09-19T18:00:00Z', etapa: 'sala', mi_papel: 'liner', liner: 'L <i>1</i>', closer: null }]) })
await ctx.vistaMisClientes()
const h = ctx.el.funCont.innerHTML
ok(h.includes('sos el liner') && h.includes('En sala · falta closer') && h.includes('llegó hoy 12:00') && h.includes('En sala ahora (1)'), 'la tarjeta dice quién sos, cuándo llegó (con el día) y en qué paso va, agrupada')
ok(h.includes('Esperá a que la sala le asigne closer') && h.includes('href="tel:55"'), 'sin closer: dice qué esperar; teléfono para llamar')
ok(!h.includes('<img') && !h.includes('<i>1</i>'), '«mis clientes»: escapado')
respuesta = () => ({ ok: true, status: 200, json: async () => ([]) })
await ctx.vistaMisClientes()
ok(ctx.el.funCont.innerHTML.includes('Todavía no tenés clientes'), 'sin clientes: lo dice')

ctx.el.funTabs = { innerHTML: '' }
vm.runInContext("MIS_PERMISOS={cerrar_contrato:true}; ROLE='vendedor'; verTodo=false; esGerente=false;", ctx); ctx.funPintarTabs()
let t = ctx.el.funTabs.innerHTML
ok(t.includes('>Mis clientes<') && t.includes('>Cierre<') && !/Todos|Postventa|Reservas|Mi día/.test(t), 'el liner ve Mis clientes y Cierre; no Mi día, Todos, Postventa ni Reservas')
vm.runInContext("MIS_PERMISOS={}; ROLE='gerente_ventas'; verTodo=true; esGerente=true;", ctx); ctx.funPintarTabs()
ok(!ctx.el.funTabs.innerHTML.includes('>Reservas<'), 'la gerencia de ventas no ve Reservas (sin el permiso)')
vm.runInContext("MIS_PERMISOS={gestionar_reservas:true}; ROLE='reservaciones'; verTodo=true; esGerente=false;", ctx); ctx.funPintarTabs()
ok(ctx.el.funTabs.innerHTML.includes('>Reservas<'), 'con el permiso de reservas, sí')

vm.runInContext("MIS_PERMISOS={verificar_contratos:true};", ctx)
let vc = ctx.verifCard({ id: 7, cliente: 'x', estado: 'por_verificar', verificador_id: 41, verificador: 'Vera <b>' })
ok(!vc.includes('id="asv7"') && vc.includes('Asignado a vos.'), 'el verificador no cambia la asignación')
vm.runInContext("MIS_PERMISOS={verificar_contratos:true,corregir_sala:true};", ctx)
vc = ctx.verifCard({ id: 7, cliente: 'x', estado: 'por_verificar', verificador_id: 41, verificador: 'Vera <b>' })
ok(vc.includes('id="asv7"') && vc.includes('>V2<') && !vc.includes('<option value="41">'), 'la gerencia asigna el verificador (sin repetir el actual)')
llamadas.length = 0
await ctx.asignarVerificador(7, { value: '42' }, { disabled: false })
ok(llamadas[0] && /funnel_contrato_asignar_verificador/.test(llamadas[0].path) && llamadas[0].body.p_agente === 42 && ctx.toasts.includes('Asignado a V2'), 'asignar (con botón) manda el elegido y nombra a la persona')
let vs = ctx.verifCard({ id: 8, cliente: 'x', estado: 'por_verificar', verificador_id: null })
ok(vs.includes('Sin verificador') && !/onchange="asignar/.test(vs), 'sin verificador: marca roja; el selector solo no asigna')

vm.runInContext("MIS_PERMISOS={cerrar_contrato:true};", ctx)
const conC = ctx.misClienteCard({ id: 3, nombre: 'x', etapa: 'sala', mi_papel: 'closer', closer: 'C', contrato: null })
ok(conC.includes('Ir a cierre'), 'con closer y permiso de cierre: botón «Ir a cierre»')
ok(ctx.tonoPaso({ contrato: 'verificado' }) === 'ok' && ctx.tonoPaso({ contrato: 'cancelado' }) === 'err' && ctx.tonoPaso({ etapa: 'sala', descuento: 'pendiente' }) === 'warn', 'colores por paso')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Mis clientes OK')
