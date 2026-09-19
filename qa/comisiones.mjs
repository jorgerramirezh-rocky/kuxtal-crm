// QA del bloque 6 (reglas de comisión, cancelados y reabrir) SIN navegador: funciones REALES de app.html
// con la base simulada. Mide: valores válidos de una regla, qué se manda al guardar, que reabrir exige
// motivo, los avisos de reservas y enganche, el escapado y las pestañas por permiso.
// node qa/comisiones.mjs
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
let respuesta = () => ({ ok: true, status: 200, json: async () => ([{ id: 1 }]) })
const ctx = { console, TZ_GT: 'America/Guatemala', llamadas }
vm.createContext(ctx)
vm.runInContext([
  linea('const esc='), linea('const usd='), linea('const cuandoGT='), linea('const ROL_COM='),
  "var toasts=[], el={}, MIS_PERMISOS={}, ROLE='', verTodo=false, esGerente=false, funTab='', MEMBS=[{tipo:'VIP',precio:1200,descuento:120}], REGLAS=[], RAPAGA={}, VERIF=[], VNOTA={}, CANCEL=[], RNOTA={}, VSUB='pend'; function pintarReglas(){}",
  "function hoyStr(){ return '2026-09-19'; } function $(id){ return el[id]||null; } function toast(m){ toasts.push(m); } async function vistaReglas(){} async function vistaVerificacion(){} function pintarVerif(){}",
  "var api=async (path,opt)=>{ llamadas.push({path, method:opt&&opt.method, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };",
  ...['partesGT', 'rpcSala', 'montoMembresia', 'ganaRegla', 'montoTipico', 'errRegla', 'valoresRegla', 'reglaCard', 'guardarRegla', 'crearRegla', 'canceladoCard', 'reabrir', 'verifCard', 'funPintarTabs'].map(extraer),
].join('\n'), ctx)
ctx.respuesta = () => respuesta()
vm.runInContext('var respuesta=this.respuesta; api=async (path,opt)=>{ llamadas.push({path, method:opt&&opt.method, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };', ctx)

ok(ctx.valoresRegla('3', '0') === null && ctx.valoresRegla('50', '100000') === null, 'reglas válidas: 3 % · 50 % y 100,000 de tope')
ok(ctx.valoresRegla('60', '0') && ctx.valoresRegla('-1', '0') && ctx.valoresRegla('x', '0') && ctx.valoresRegla('1', '-5'), 'fuera de rango o sin número: frena antes de mandar')
const rc = ctx.reglaCard({ id: 4, rol: 'vendedor', tipo_membresia: 'VIP <b>', tasa: 3, monto_fijo: 0, activo: true })
ok(rc.includes('Liner') && rc.includes('VIP &lt;b&gt;') && !rc.includes('VIP <b>'), 'la regla nombra el puesto y sale escapada')

ctx.el = { rt4: { value: '4.5' }, rm4: { value: '0' } }; vm.runInContext('el=this.el;', ctx)
await ctx.guardarRegla(4, null, { disabled: false })
ok(llamadas[0] && llamadas[0].method === 'PATCH' && JSON.stringify(llamadas[0].body) === '{"tasa":4.5,"monto_fijo":0}', 'guardar manda SOLO porcentaje y monto')
llamadas.length = 0; ctx.el.rt4.value = '70'
await ctx.guardarRegla(4, null, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('El porcentaje va de 0 a 50'), 'guardar 70 %: no llama a la base')
llamadas.length = 0; respuesta = () => ({ ok: true, status: 200, json: async () => ([]) })
await ctx.guardarRegla(4, { activo: false }, { disabled: false })
ok(ctx.toasts.some(t => /No se guardó/.test(t)), 'si la base no guardó (sin permiso), lo dice')
respuesta = () => ({ ok: true, status: 200, json: async () => ([{ id: 1 }]) })

const can = { id: 9, cliente: 'Ana <img src=x>', membresia: 'VIP', monto: 900, enganche: 200, reservas: 2, nota: '<b>no quiere</b>', cancelado_por: 'v@k', cancelado_en: '2026-09-19T18:00:00Z', se_puede_reabrir: true }
let cc = ctx.canceladoCard(can)
ok(cc.includes('Enganche a devolver: US$ 200.00') && cc.includes('Tiene 2 reservas'), 'cancelado: avisa enganche a devolver y reservas')
ok(!cc.includes('<img') && !cc.includes('<b>no quiere</b>'), 'cancelado: escapado')
ok(cc.includes('Reabrir (fue un error)…') && !cc.includes('Confirmar: reabrir'), 'reabrir pide abrir y confirmar')
ok(ctx.canceladoCard({ ...can, se_puede_reabrir: false }).includes('Ya tiene otro contrato vivo'), 'con otro contrato vivo no se ofrece reabrir')
llamadas.length = 0; ctx.el.rab9 = { value: '  ' }
await ctx.reabrir(9, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('Escribí por qué se reabre'), 'reabrir sin motivo: no llama a la base')

ctx.VNOTA[7] = 'arrepentido'
const va = ctx.verifCard({ id: 7, cliente: 'x', estado: 'por_verificar', enganche: 150, reservas: 1 })
ok(va.includes('Tiene 1 reserva') && va.includes('devolverle el enganche: US$ 150.00'), '«se arrepintió» avisa reservas y enganche antes de confirmar')

ctx.el.funTabs = { innerHTML: '' }
vm.runInContext("MIS_PERMISOS={ver_comisiones:true}; ROLE='gerente_tmk'; verTodo=true; esGerente=true;", ctx); ctx.funPintarTabs()
ok(!ctx.el.funTabs.innerHTML.includes('Reglas de comisión'), 'TMK no ve «Reglas de comisión»')
vm.runInContext("MIS_PERMISOS={gestionar_comisiones:true}; ROLE='gerente_ventas';", ctx); ctx.funPintarTabs()
ok(ctx.el.funTabs.innerHTML.includes('Reglas de comisión'), 'la gerencia de ventas ve «Reglas de comisión»')

// ── lente de diseño: dinero ──
ok(ctx.ganaRegla({ tasa: 3, monto_fijo: 0 }, 1080) === 32.4 && ctx.ganaRegla({ tasa: 2, monto_fijo: 30 }, 1000) === 50, 'cuánto gana: monto fijo + % (se suman)')
const rc2 = ctx.reglaCard({ id: 5, rol: 'vendedor', tipo_membresia: null, tasa: 3, monto_fijo: 0, activo: true })
ok(rc2.includes('En un contrato de US$ 1,080.00 gana') && rc2.includes('US$ 32.40'), 'cada regla dice cuánto gana en dólares')
ok(rc2.includes('Apagar…') && !rc2.includes('Confirmar: apagar'), 'apagar pide confirmar')
ctx.RAPAGA[5] = true
ok(ctx.reglaCard({ id: 5, rol: 'vendedor', tasa: 3, activo: true }).includes('Confirmar: apagar'), 'confirmación de apagar con aviso')
ctx.RAPAGA[5] = false
ok(ctx.reglaCard({ id: 6, rol: 'verificador', tasa: 0, monto_fijo: 30, activo: true }).includes('se verifiquen desde ahora'), 'la del verificador dice que aplica al verificar')
llamadas.length = 0; ctx.el.rt4 = { value: '30' }; ctx.el.rm4 = { value: '0' }
const bAlt = { disabled: false, dataset: {}, textContent: '' }
await ctx.guardarRegla(4, null, bAlt)
ok(llamadas.length === 0 && /¿Seguro\? 30 %/.test(bAlt.textContent), 'un % alto (30) pide confirmar mostrando los dólares')
await ctx.guardarRegla(4, null, bAlt)
ok(llamadas.length === 1, 'al tocar de nuevo, guarda')
vm.runInContext("REGLAS=[{id:1,rol:'vendedor',tipo_membresia:null,activo:true}];", ctx)
ctx.el.nrt = { value: '4' }; ctx.el.nrm = { value: '0' }; ctx.el.nrrol = { value: 'vendedor' }; ctx.el.nrmem = { value: '' }
llamadas.length = 0
await ctx.crearRegla({ disabled: false, dataset: {} })
ok(llamadas.length === 0 && ctx.toasts.some(t => /Ya hay una regla activa/.test(t)), 'no se crea una regla duplicada (se pagaría doble)')
vm.runInContext("CANCEL=[{id:9,enganche:200}];", ctx); ctx.el.rab9 = { value: 'error' }; ctx.el.rabe9 = { checked: false }
llamadas.length = 0
await ctx.reabrir(9, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('Confirmá que el enganche no se le devolvió'), 'con enganche, reabrir exige la casilla')
ctx.el.rabe9.checked = true
await ctx.reabrir(9, { disabled: false })
ok(llamadas[0] && llamadas[0].body.p_enganche_no_devuelto === true, 'con la casilla, reabre y lo manda')

// ── ronda 1 ciber ──
ok(await ctx.errRegla({ status: 409, json: async () => ({ code: '23505' }) }) === 'Ya hay una regla activa para ese puesto y membresía: editá esa', 'regla repetida: lo dice en palabras')
ok(/gerente general/.test(await ctx.errRegla({ status: 400, json: async () => ({ message: 'la comisión del gerente de ventas la fija el gerente general' }) })), 'la comisión del gerente de ventas: dice quién la fija')
ok(src.includes("const puedeGV=['admin','gerente_general'].includes(ROLE);"), 'asignar el gerente de ventas de un closer: solo admin o gerente general')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Comisiones y cancelados OK')
