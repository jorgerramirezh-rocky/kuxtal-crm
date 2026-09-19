// QA del bloque 5 (descuentos por segmento, aprobación y verificación) SIN navegador: saca de app.html
// las funciones REALES y las corre con datos de prueba y la base simulada. Mide: el precio (lista −
// membresía − descuento APROBADO de esa membresía), que el monto ya no se escribe ni se manda, que no
// se cierra con un descuento pendiente, que rechazar/observar/arrepentirse exigen motivo, el escapado y
// las pestañas por permiso.
// node qa/verificacion.mjs
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
let respuesta = () => ({ ok: true, status: 200, json: async () => ({ contrato_id: 1, no_socio: '3907', monto: 900 }) })
const ctx = { console, TZ_GT: 'America/Guatemala', llamadas }
vm.createContext(ctx)
vm.runInContext([
  linea('const esc='), linea('const usd='), linea('const horaGT='),
  "var toasts=[], el={}, USER='x@y', MIS_PERMISOS={}, ROLE='', verTodo=false, esGerente=false, funTab='';",
  "var MEMBS=[{tipo:'VIP',precio:1200,descuento:0,enganche:100},{tipo:'Gold <b>',precio:700,descuento:50}], PLANES=[{nombre:'Contado'}];",
  "var AGENTES=[{id:21,nombre:'L <i>1</i>',rol:'vendedor',activo:true},{id:31,nombre:'C1',rol:'cerrador',activo:true}];",
  "var DESCUENTOS=[{id:1,nombre:'Contado <script>',tipo:'porcentaje',valor:10,membresias:null,activo:true},{id:2,nombre:'Solo VIP',tipo:'monto',valor:100,membresias:['VIP'],activo:true},{id:3,nombre:'Apagado',tipo:'monto',valor:5,membresias:null,activo:false}];",
  "var PEDIDOS={}, cierreLeads=[], APROB=[], RECHAZO={}, VERIF=[], VNOTA={};",
  "function $(id){ return el[id]||null; } function toast(m){ toasts.push(m); } function pintarCierre(){} function pintarAprob(){} function pintarVerif(){}",
  "async function vistaCierre(){} async function vistaVerificacion(){} function opAgentes(){ return ''; } function imprimirContrato(){}",
  "async function registrarEnganche(){ return {}; } async function probeContratosExt(){ return false; }",
  "var api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };",
  ...['partesGT', 'rpcSala', 'montoMembresia', 'segmentosDe', 'precioCierre', 'agNom', 'cierreCard', 'cerrarContrato',
      'pedirDescuento', 'aprobCard', 'resolverDesc', 'verifCard', 'verificar', 'funPintarTabs'].map(extraer),
].join('\n'), ctx)
ctx.respuesta = () => respuesta()
vm.runInContext('api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); }; var respuesta=this.respuesta;', ctx)

// ── precio ──
const [vip, gold] = ctx.MEMBS
ok(ctx.segmentosDe(ctx.DESCUENTOS, 'VIP').map(d => d.id).join() === '1,2', 'segmentos de VIP: los de todas + los de VIP, sin los apagados')
ok(ctx.segmentosDe(ctx.DESCUENTOS, 'Gold <b>').map(d => d.id).join() === '1', 'un segmento solo-VIP no aparece en otra membresía')
ok(ctx.precioCierre(gold, null) === 650, 'sin descuento: lista − descuento de la membresía (700 − 50)')
ok(ctx.precioCierre(vip, { estado: 'aprobada', membresia: 'VIP', monto_descuento: 120 }) === 1080, 'aprobado para esa membresía: se resta')
ok(ctx.precioCierre(vip, { estado: 'pendiente', membresia: 'VIP', monto_descuento: 120 }) === 1200, 'pendiente: NO se resta')
ok(ctx.precioCierre(gold, { estado: 'aprobada', membresia: 'VIP', monto_descuento: 120 }) === 650, 'aprobado para OTRA membresía: no se resta')
ok(ctx.precioCierre(vip, { estado: 'aprobada', membresia: 'VIP', monto_descuento: 5000 }) === 0, 'nunca negativo')

// ── tarjeta de cierre ──
const lead = { id: 9, nombre: 'Ana <img src=x onerror=alert(1)>', vendedor_id: 21, cerrador_id: 31, _memb: 'VIP' }
let card = ctx.cierreCard(lead)
ok(!/id="mon9"/.test(card) && !/Monto \(US\$\)/.test(card), 'el monto ya no se escribe a mano')
ok(!/id="ver9"/.test(card), 'el verificador ya no se elige al cerrar')
ok(card.includes('Cerrar contrato en US$ 1,200.00'), 'el botón dice el precio que va a poner la base')
ok(!card.includes('<img') && !card.includes('<script') && !card.includes('<i>1</i>') && !card.includes('Gold <b>'), 'tarjeta de cierre: todo escapado')
ctx.PEDIDOS[9] = { id: 5, segmento: 'Contado', membresia: 'VIP', monto_descuento: 120, estado: 'pendiente' }
card = ctx.cierreCard(lead)
ok(!card.includes('Cerrar contrato en') && card.includes('esperando aprobación'), 'con el descuento pendiente no hay botón de cierre')
ctx.PEDIDOS[9] = { id: 5, segmento: 'Contado', membresia: 'VIP', monto_descuento: 120, estado: 'rechazada', nota: '<b>no</b>' }
card = ctx.cierreCard(lead)
ok(card.includes('rechazado') && card.includes('&lt;b&gt;no&lt;/b&gt;') && card.includes('Cerrar contrato en US$ 1,200.00'), 'rechazado: se ve el motivo (escapado) y se cierra a precio normal')
ok(!ctx.cierreCard({ ...lead, cerrador_id: null }).includes('Cerrar contrato en'), 'sin closer no hay botón de cierre')

// ── cerrar: qué se manda ──
ctx.cierreLeads = [lead]
ctx.el = { mem9: { value: 'VIP' }, pln9: { value: 'Contado' }, vig9: { value: '4' }, eng9: { value: '' }, dig9: { value: '' } }
vm.runInContext('el=this.el; cierreLeads=this.cierreLeads;', ctx)
ctx.PEDIDOS[9] = { id: 5, membresia: 'VIP', monto_descuento: 120, estado: 'aprobada' }
vm.runInContext('PEDIDOS=this.PEDIDOS;', ctx)
const b1 = { disabled: false, innerHTML: 'x' }
await Promise.all([ctx.cerrarContrato(9, b1), ctx.cerrarContrato(9, b1)])
const cierres = llamadas.filter(x => x.path.includes('funnel_cerrar_contrato'))
ok(cierres.length === 1, 'doble toque: un solo cierre')
ok(cierres[0] && !('p_monto' in cierres[0].body) && !('p_verificador' in cierres[0].body), 'no se manda monto ni verificador')
ok(cierres[0] && cierres[0].body.p_solicitud === 5, 'con descuento aprobado para esa membresía: va el pedido')
llamadas.length = 0
ctx.PEDIDOS[9] = { id: 6, membresia: 'Gold <b>', monto_descuento: 120, estado: 'aprobada' }
await ctx.cerrarContrato(9, { disabled: false, innerHTML: 'x' })
ok(llamadas[0] && llamadas[0].body.p_solicitud === null, 'aprobado para OTRA membresía: no se manda')

// ── aprobaciones y verificación ──
llamadas.length = 0
ctx.el.rmot4 = { value: '  ' }
await ctx.resolverDesc(4, false, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('Escribí por qué lo rechazás'), 'rechazar sin motivo: no llama a la base')
ctx.el.vnot7 = { value: '' }
await ctx.verificar(7, 'arrepentido', { disabled: false })
await ctx.verificar(7, 'observado', { disabled: false })
ok(llamadas.length === 0, 'observar o «se arrepintió» sin nota: no llama a la base')
await ctx.verificar(7, 'verificado', { disabled: false })
ok(llamadas.length === 1 && llamadas[0].body.p_resultado === 'verificado', 'verificado: va sin nota')

const vc = ctx.verifCard({ id: 7, cliente: 'Luis <script>', telefono: '5541-2233"><x', membresia: 'VIP', plan_pago: 'Contado', precio_lista: 1200,
  descuento: 120, monto: 1080, estado: 'observado', verificacion_nota: '<img src=x>', liner: 'L', closer: 'C' })
ok(!vc.includes('<script') && !vc.includes('<img') && vc.includes('href="tel:55412233"'), 'verificación: escapado y el teléfono limpio en el enlace')
ok(vc.includes('Se arrepintió…') && vc.includes('Con observaciones…') && vc.includes('>Verificado<'), 'las tres salidas de la verificación')
ctx.VNOTA[7] = 'arrepentido'
ok(ctx.verifCard({ id: 7, cliente: 'x', estado: 'por_verificar' }).includes('Confirmar: se arrepintió'), '«se arrepintió» pide confirmar con nota')

// ── pestañas por permiso ──
ctx.el.funTabs = { innerHTML: '' }
vm.runInContext("MIS_PERMISOS={verificar_contratos:true}; ROLE='verificador'; verTodo=true; esGerente=false;", ctx); ctx.funPintarTabs()
ok(/>Verificación</.test(ctx.el.funTabs.innerHTML) && !/Aprobaciones|Descuentos/.test(ctx.el.funTabs.innerHTML), 'el verificador ve Verificación, no Aprobaciones ni Descuentos')
vm.runInContext("MIS_PERMISOS={recibir_sala:true}; ROLE='vendedor'; verTodo=true; esGerente=false;", ctx); ctx.funPintarTabs()
ok(!/Verificación|Aprobaciones|Descuentos/.test(ctx.el.funTabs.innerHTML), 'sin esos permisos (un liner) no ve Verificación, Aprobaciones ni Descuentos')
vm.runInContext("MIS_PERMISOS={verificar_contratos:true,aprobar_descuentos:true,gestionar_descuentos:true}; ROLE='gerente_ventas'; verTodo=true; esGerente=true;", ctx); ctx.funPintarTabs()
ok(['Aprobaciones', 'Verificación', 'Descuentos'].every(t => ctx.el.funTabs.innerHTML.includes('>' + t + '<')), 'el gerente de ventas ve Aprobaciones, Verificación y Descuentos')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Verificación y descuentos OK')
