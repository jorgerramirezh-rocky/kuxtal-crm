// QA del bloque 8 (digitación antes de imprimir) SIN navegador: funciones REALES de app.html con la base
// simulada. Mide: qué hace falta para validar, que el cierre ya no imprime, que validar guarda + valida +
// imprime con los datos, que devolver exige nota, el escapado, las pestañas y que TODO el JS de app.html compila.
// node qa/digitacion.mjs
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
// Todo el JavaScript de app.html compila (un comentario de línea mal puesto rompía la app entera).
const scripts = [...src.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)]
let roto = null; for (const x of scripts) { try { new Function(x[1]) } catch (e) { roto = e.message } }
ok(scripts.length > 0 && roto === null, 'todo el JavaScript de app.html compila' + (roto ? ' → ' + roto : ''))

const llamadas = []; const impresos = []
let respuesta = () => ({ ok: true, status: 200, json: async () => ({}) })
const ctx = { console, TZ_GT: 'America/Guatemala', llamadas, impresos }
vm.createContext(ctx)
vm.runInContext([
  linea('const esc='), linea('const usd='), linea('const DPI_OK='),
  "var toasts=[], el={}, MIS_PERMISOS={}, ROLE='', verTodo=false, esGerente=false, funTab='', AGENTES=[{id:61,nombre:'Dora <b>',rol:'digitador',activo:true}], DIGIT=[], DBEN={}, DDEV={}, DDRAFT={}, DCONF={}, ventanaOk=true;",
  "function $(id){ return el[id]||null; } function toast(m){ toasts.push(m); } async function vistaDigitacion(){} function imprimirContrato(d,w){ impresos.push({d,w}); return true; }",
  "var window={open:()=>ventanaOk?{close(){},document:{}}:null};",
  "var api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };",
  ...['rpcSala', 'puedeValidar', 'leerDigit', 'guardarBorrDigit', 'faltaDigit', 'avisarFalta', 'pintarDigit', 'digitCard', 'pedirValidar', 'validarDigit', 'devolverDigit', 'reimprimir', 'funPintarTabs', 'avisoCierre'].map(extraer),
].join('\n'), ctx)
ctx.respuesta = () => respuesta()
vm.runInContext('var respuesta=this.respuesta; api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };', ctx)

const ok3 = [true, true, true]
ok(ctx.puedeValidar({ dpi: '1234 56789 0123', fecha_nacimiento: '1980-01-01', direccion: 'z10' }, ok3), 'con DPI de 13 dígitos, nacimiento, dirección y las revisiones: se valida')
ok(!ctx.puedeValidar({ dpi: '123', fecha_nacimiento: '1980-01-01', direccion: 'z10' }, ok3) && !ctx.puedeValidar({ dpi: '1234567890123', direccion: 'z10' }, ok3)
   && !ctx.puedeValidar({ dpi: '1234567890123', fecha_nacimiento: '1980-01-01', direccion: ' ' }, ok3), 'sin DPI válido, nacimiento o dirección: no')
ok(!ctx.puedeValidar({ dpi: '1234567890123', fecha_nacimiento: '1980-01-01', direccion: 'z10' }, [true, false, true]), 'sin las tres revisiones: no')

const c = { id: 5, cliente: 'Ana <img src=x>', membresia: 'VIP', plan_pago: 'Contado', monto: 900, precio_lista: 1000, descuento: 100, enganche: 100, liner: 'L', closer: 'C', digitador_id: 61, digitador: 'Dora <b>', no_socio: '3907', anios: 4, beneficiarios: [] }
vm.runInContext("MIS_PERMISOS={digitar_contratos:true}; ROLE='digitador';", ctx)
let h = ctx.digitCard(c)
ok(h.includes('Validar e imprimir…') && h.includes('id="dgdpi5"') && h.includes('obligatorio') && !h.includes('id="asd5"'), 'el digitador ve el formulario (con obligatorios marcados); no asigna')
ok(!h.includes('<img') && !h.includes('Dora <b>'), 'digitación: escapado')
vm.runInContext("MIS_PERMISOS={digitar_contratos:true,corregir_sala:true}; ROLE='gerente_ventas';", ctx)
ok(ctx.digitCard({ ...c, digitador_id: null, digitador: null }).includes('Sin digitador') && ctx.digitCard({ ...c, digitador_id: null }).includes('id="asd5"'), 'la gerencia ve y asigna lo que no tiene digitador')

vm.runInContext("MIS_PERMISOS={digitar_contratos:true}; ROLE='digitador';", ctx)
ctx.DIGIT.push(c); ctx.DBEN[5] = [{ nombre: 'Luis', parentesco: 'hijo' }]
ctx.el = { dgdpi5: { value: '123' }, dgfn5: { value: '1980-05-01' }, dgdir5: { value: 'z10' }, dgk05: { checked: true }, dgk15: { checked: true }, dgk25: { checked: true } }
vm.runInContext('el=this.el;', ctx)
await ctx.validarDigit(5, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('El DPI tiene que tener 13 dígitos'), 'DPI malo: no llama a la base')
ctx.el.dgdpi5.value = '1234567890123'; ctx.el.dgk15.checked = false
await ctx.validarDigit(5, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('Marcá las tres revisiones antes de validar'), 'sin revisiones: no llama a la base')
ctx.el.dgk15.checked = true
await ctx.validarDigit(5, { disabled: false })
ok(llamadas.length === 2 && /funnel_contrato_digitar/.test(llamadas[0].path) && /funnel_contrato_validar/.test(llamadas[1].path), 'validar: guarda los datos y valida')
ok(impresos.length === 1 && impresos[0].d.dpi === '1234567890123' && impresos[0].d.beneficiarios.length === 1 && impresos[0].d.no_socio === '3907' && impresos[0].w, 'y recién ahí imprime (en la ventana abierta desde el toque), con DPI, beneficiarios y número de socio')

llamadas.length = 0; ctx.el.dgdev5 = { value: '  ' }
await ctx.devolverDigit(5, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.includes('Escribí qué no cuadra'), 'devolver sin nota: no llama a la base')

const cierre = src.slice(src.indexOf('async function cerrarContrato('), src.indexOf('async function cerrarContrato(') + 2500)
ok(!/imprimirContrato\(/.test(cierre.slice(0, cierre.indexOf('\n}\n'))) && /toast\(avisoCierre\(/.test(cierre) && /pasa a digitación/.test(ctx.avisoCierre('1', true)), 'el cierre ya NO imprime: pasa a digitación')

ctx.el.funTabs = { innerHTML: '' }
vm.runInContext("MIS_PERMISOS={digitar_contratos:true}; ROLE='digitador'; verTodo=false; esGerente=false;", ctx); ctx.funPintarTabs()
ok(ctx.el.funTabs.innerHTML.includes('>Digitación<') && !ctx.el.funTabs.innerHTML.includes('Mi día'), 'el digitador ve Digitación (y ya no «Mi día»)')

// ── lente de diseño ──
ok(ctx.faltaDigit({ dpi: '123456789' }, [true, false, true]).join(', ') === 'DPI (9 de 13 dígitos), fecha de nacimiento, dirección, revisión 2', '«Falta:» dice exactamente qué falta')
ctx.DIGIT.length = 0; ctx.DIGIT.push({ ...c, id: 6, dpi: null, direccion: null }); ctx.DBEN[6] = []
ctx.el = { funCont: { innerHTML: '' }, dgdpi6: { value: '1234567890123' }, dgfn6: { value: '1980-01-01' }, dgdir6: { value: 'z10 escrita' }, dgk06: { checked: true }, dgk16: { checked: false }, dgk26: { checked: true } }
vm.runInContext('el=this.el;', ctx); vm.runInContext("MIS_PERMISOS={digitar_contratos:true}; ROLE='digitador';", ctx)
ctx.pintarDigit()
const rep = ctx.el.funCont.innerHTML
ok(rep.includes('value="1234567890123"') && rep.includes('value="z10 escrita"') && /id="dgk06" checked/.test(rep), 'lo escrito y las revisiones marcadas sobreviven al repintar')
llamadas.length = 0; vm.runInContext('ventanaOk=false; DCONF={};', ctx); ctx.el.dgk16.checked = true
await ctx.validarDigit(6, { disabled: false })
ok(llamadas.length === 0 && ctx.toasts.some(t => /no se validó nada/.test(t)), 'si el navegador bloquea la ventana: no se valida nada')
vm.runInContext('ventanaOk=true;', ctx)
ctx.el.dgk16.checked = false; ctx.pedirValidar(6)
ok(!vm.runInContext('DCONF[6]', ctx) && ctx.toasts.some(t => /Falta: revisión 2/.test(t)), 'validar con algo pendiente: no abre la confirmación y dice qué falta')
ctx.el.dgk16.checked = true; ctx.pedirValidar(6)
ok(vm.runInContext('DCONF[6]', ctx) === true, 'con todo completo: pide confirmar antes de validar')
llamadas.length = 0; impresos.length = 0
respuesta = () => ({ ok: true, status: 200, json: async () => ({ nombre: 'Ana', dpi: '1234567890123', fecha: '2026-09-18' }) })
await ctx.reimprimir(9, { disabled: false })
ok(/funnel_contrato_impresion/.test((llamadas[0] || {}).path) && impresos.length === 1 && impresos[0].d.fecha === '2026-09-18', 'reimprimir trae los datos (con la fecha del cierre) e imprime')

// Lente r2: si el enganche no se guardó, el aviso que QUEDA en pantalla lo dice (antes lo pisaba el de éxito).
ok(/enganche NO se guardó/.test(ctx.avisoCierre('123', false)), 'cierre con enganche perdido: el único aviso lo dice')
ok(!/enganche/.test(ctx.avisoCierre('123', true)), 'cierre normal: sin alarma de enganche')
ok((src.match(/toast\([^)]*pasa a digitación/g) || []).length === 0 && src.includes('toast(avisoCierre('), 'cerrarContrato muestra UN solo aviso (avisoCierre)')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Digitación OK')
