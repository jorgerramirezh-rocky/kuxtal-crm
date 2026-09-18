// QA de «Mi día» (bloque 2, telemarketing) SIN navegador: saca de app.html las funciones
// REALES de la tarjeta y las corre con datos de prueba. Mide lo que la pantalla promete:
// todo escapado, solo lo mínimo a la vista, los paneles correctos según el resultado, y
// que ya no quedan caminos que editen la fila directo. node qa/mi-dia.mjs
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

const ctx = { console, TZ_GT: 'America/Guatemala' }
vm.createContext(ctx)
vm.runInContext([
  linea('const esc='), linea('const telDig='), linea('const waHref='), linea('const telHref='),
  "var WA='<svg></svg>', TEL='<svg></svg>';",
  "var ESTADOS=[{clave:'nuevo',etiqueta:'Nuevo',color:'#8a94a6'},{clave:'interesado',etiqueta:'Interesado',color:'#6f9e12'},{clave:'asistira',etiqueta:'Asistirá',color:'#1b365d'},{clave:'recontactar',etiqueta:'Recontactar',color:'#c28b00'},{clave:'no_contesta',etiqueta:'No contesta',color:'#999'}];",
  "var RESTAS=[{id:1,nombre:'Rest <script>'}], leads=[], todos=[], sub='pend';",
  "var ABIERTO={}, SOCIO={}, ENVIANDO=new Set(), TOPE_INTENTOS=3, RECIEN=new Set(), BORRADOR={}, CONFIRMA={}, HORARIOS=[{restaurante_id:1,dia_semana:1,hora:'19:00:00',activo:true}];",
  linea('const estDe='),
  ...['partesGT', 'tsGT', 'hoyStr', 'fechaCorta', 'borrador', 'valB', 'diaSemana', 'horasDe', 'hora12', 'btnRes', 'funCardHTML', 'pasa'].map(extraer),
].join('\n'), ctx)

let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }
const malo = '<img src=x onerror=alert(1)>'
const base = { id: 7, nombre: malo, telefono: '5541-2233', estado: 'nuevo', intentos: 0, es_socio: null, comentario: malo }

let h = ctx.funCardHTML(base)
ok(!h.includes('<img'), 'nombre y nota con <img> salen escapados')
ok(!h.includes('<script>'), 'el nombre del restaurante sale escapado')
ok(/Contestó<\/button>/.test(h) && /No contestó<\/button>/.test(h) && /Reprogramar<\/button>/.test(h), 'los 3 botones de resultado están')
ok(!/class="sub show"/.test(h), 'sin tocar nada: ningún panel abierto')
ok(h.includes('noContesto(7)') && !h.includes("anotar(7,'no_contesta')"), '«No contestó» no anota al primer toque (pide confirmar)')
ctx.CONFIRMA[7] = Date.now()
ok(ctx.funCardHTML(base).includes('¿Seguro? Tocá otra vez'), 'tras el primer toque: pide el segundo')
ctx.CONFIRMA = {}; vm.runInContext('CONFIRMA={}', ctx)
ok(!h.includes('sin contestar'), 'sin intentos: no muestra el contador')

ctx.ABIERTO[7] = 'contesto'
h = ctx.funCardHTML(base)
ok(h.includes('¿Ya es socio de Kuxtal?') && h.includes('Interesado</button>') && h.includes('No interesado</button>'), '«Contestó» abre: socio sí/no + interesado/no interesado')
ctx.ABIERTO[7] = 'reprog'
h = ctx.funCardHTML(base)
ok(h.includes('Guardar y volver a llamar'), '«Reprogramar» abre día + hora')
ctx.ABIERTO[7] = null

h = ctx.funCardHTML({ ...base, estado: 'interesado' })
ok(h.includes('Citar a presentación'), 'interesado: aparece citar a presentación')
h = ctx.funCardHTML({ ...base, estado: 'no_contesta', intentos: 2 })
ok(h.includes('sin contestar 2 de 3'), 'muestra cuántas veces no contestó')
h = ctx.funCardHTML({ ...base, estado: 'asistira', restaurante_id: 1, presenta_en: '2026-09-21T01:00:00+00:00' })
ok(h.includes('Citado · 20/09 7:00 p. m.'), 'la cita se ve en hora de Guatemala (01:00 UTC = 19:00 del día anterior)')
ok(h.includes('Cambiar la cita'), 'ya citado: el botón dice «Cambiar la cita»')

ctx.ENVIANDO.add(7)
h = ctx.funCardHTML(base)
ok((h.match(/class="res[^"]*"[^>]*disabled/g) || []).length >= 3, 'mientras guarda: los botones quedan apagados (no hay doble toque)')
ctx.ENVIANDO.delete(7)

// Lo escrito en fecha/hora/restaurante sobrevive a un repintado.
ctx.borrador(3, 'prd', '2026-10-01'); ctx.borrador(3, 'rst', '1')
h = ctx.funCardHTML({ ...base, id: 3, estado: 'interesado' })
ok(h.includes('value="2026-10-01"') && /<option value="1" selected>/.test(h), 'el día y el restaurante elegidos no se borran al repintar')
ctx.borrador(3, 'prd', '2026-09-21')
h = ctx.funCardHTML({ ...base, id: 3, estado: 'interesado' })
ok(h.includes('<option value="19:00"') && !h.includes('type="time" id="prh3"'), 'la hora de la cita se elige de los horarios del lugar (lunes 19:00), no libre')
ctx.borrador(3, 'prd', '2026-09-22')
ok(ctx.funCardHTML({ ...base, id: 3, estado: 'interesado' }).includes('Sin horarios ese día'), 'día sin horarios: lo dice')
ctx.borrador(3, 'prh', '"><img src=x>')
ok(!ctx.funCardHTML({ ...base, id: 3, estado: 'interesado' }).includes('<img'), 'lo guardado en borrador sale escapado')
vm.runInContext('RECIEN.add(9)', ctx)
ok((() => { ctx.sub = 'pend'; return ctx.pasa({ id: 9, estado: 'interesado' }) })(), 'recién anotado como interesado: se queda a la vista para citarlo')
vm.runInContext('RECIEN.clear()', ctx)

// Las pestañas de Mi día.
const pas = (s, l) => { ctx.sub = s; return ctx.pasa(l) }
ok(pas('pend', { estado: 'nuevo' }) && pas('pend', { estado: 'no_contesta' }) && !pas('pend', { estado: 'interesado' }), '«Por llamar»: nuevos y los que llegaron sin contestar')
ok(pas('cont', { estado: 'no_interesado' }) && !pas('cont', { estado: 'recontactar' }), '«Contestaron»: interesados y no interesados')
ok(pas('prog', { estado: 'recontactar', recontacto_en: '2099-01-01T15:00:00Z' }) && !pas('hoy', { estado: 'recontactar', recontacto_en: '2099-01-01T15:00:00Z' }), 'reprogramado a futuro: en «Reprogramados», no en «hoy»')
ok(pas('hoy', { estado: 'recontactar', recontacto_en: '2000-01-01T15:00:00Z' }), 'reprogramado vencido: en «Volver a llamar hoy»')

// Ya no quedan caminos que editen la fila del prospecto desde Mi día.
const seccion = src.slice(src.indexOf('async function cargarMiDia'), src.indexOf('// ── TODOS (gerencia) ──'))
ok(!/funPatchLead\(/.test(seccion.replace(/async function funPatchLead[\s\S]*?\n}\n/, '')), 'Mi día no usa funPatchLead (todo pasa por funnel_tmk_resultado)')
ok(!/funnel_prospectos\?/.test(seccion.replace(/async function funPatchLead[\s\S]*?\n}\n/, '')), 'Mi día no lee la tabla funnel_prospectos directo')
ok(seccion.includes('rpc/funnel_tmk_mi_lista'), 'la lista sale de funnel_tmk_mi_lista()')

console.log(fallas ? `🔴 ${fallas} falla(s)` : '✅ Mi día OK')
process.exit(fallas ? 1 : 0)
