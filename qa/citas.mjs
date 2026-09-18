// QA del bloque 3 (la cita y la carta) SIN navegador: saca de app.html las funciones REALES
// y las corre con datos de prueba. Mide: horarios por día (sin depender de la zona del
// navegador), la carta, que solo se manda por el canal aceptado, y que todo sale escapado.
// node qa/citas.mjs
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
  linea('const esc='), linea('const telDig='), linea('const DIAS='),
  "var RESTAS=[{id:1,nombre:'Hotel <b>Real</b>',direccion:'6a av 12-00 z10',mapa_url:'https://maps.app/x'},{id:2,nombre:'Sin mapa',mapa_url:'javascript:alert(1)'}];",
  "var HORARIOS=[{restaurante_id:1,dia_semana:1,hora:'19:00:00',activo:true},{restaurante_id:1,dia_semana:1,hora:'10:30:00',activo:true},{restaurante_id:1,dia_semana:1,hora:'15:00:00',activo:false},{restaurante_id:2,dia_semana:1,hora:'09:00:00',activo:true}];",
  "var CITAS=[], CITA_B={}; function hoyStr(){return '2026-09-18';}",
  ...['partesGT', 'fechaCorta', 'diaSemana', 'horasDe', 'fechaLarga', 'hora12', 'cartaTexto', 'correoValido', 'enlaceCarta', 'valC', 'citaPendHTML', 'citaConfHTML'].map(extraer),
].join('\n'), ctx)

let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }

ok(ctx.diaSemana('2026-09-21') === 1, '21-sep-2026 es lunes')
ok(JSON.stringify(ctx.horasDe(ctx.HORARIOS, 1, '2026-09-21')) === '["10:30","19:00"]', 'horarios del lunes, ordenados y sin los apagados')
ok(ctx.horasDe(ctx.HORARIOS, 1, '2026-09-22').length === 0, 'martes: sin horarios')
ok(ctx.horasDe(ctx.HORARIOS, '', '2026-09-21').length === 0, 'sin lugar: nada')
ok(ctx.hora12('19:00') === '7:00 p. m.' && ctx.hora12('00:15') === '12:15 a. m.' && ctx.hora12('12:00') === '12:00 p. m.', 'hora en formato de 12 h')
ok(ctx.fechaLarga('2026-09-22T01:00:00Z') === 'lunes 21 de septiembre de 2026', '01:00 UTC del 22 = lunes 21 en Guatemala')

const cita = { id: 5, nombre: 'Ana <img src=x onerror=alert(1)>', telefono: '5541-2233', email: 'ana@correo.gt',
  presenta_en: '2026-09-22T01:00:00Z', restaurante_id: 1, carta_whatsapp: true, carta_correo: false, tmk_nombre: 'T <i>x</i>' }
const t = ctx.cartaTexto(cita, ctx.RESTAS[0])
ok(t.includes('Estimado(a) Ana') && t.includes('lunes 21 de septiembre de 2026') && t.includes('7:00 p. m.') && t.includes('6a av 12-00 z10'), 'la carta lleva nombre, lugar, dirección, fecha larga y hora')
ok(t.includes('Cómo llegar: https://maps.app/x'), 'con mapa https: lo incluye')
ok(!ctx.cartaTexto(cita, ctx.RESTAS[1]).includes('javascript:'), 'un mapa que no es https no entra a la carta')

const wa = ctx.enlaceCarta(cita, ctx.RESTAS[0], 'whatsapp')
ok(wa && wa.startsWith('https://wa.me/50255412233?text='), 'WhatsApp aceptado: enlace al número del cliente')
ok(ctx.enlaceCarta(cita, ctx.RESTAS[0], 'correo') === null, 'correo NO aceptado: no hay enlace')
ok(ctx.enlaceCarta({ ...cita, carta_whatsapp: false }, ctx.RESTAS[0], 'whatsapp') === null, 'WhatsApp no aceptado: no hay enlace')
const ml = ctx.enlaceCarta({ ...cita, carta_correo: true }, ctx.RESTAS[0], 'correo')
ok(ml && ml.startsWith('mailto:ana%40correo.gt?subject='), 'correo aceptado: mailto al correo del cliente')
ok(ctx.enlaceCarta({ ...cita, carta_correo: true, email: 'x@y.z?bcc=otro@mal.com' }, ctx.RESTAS[0], 'correo') === null
   || !ctx.enlaceCarta({ ...cita, carta_correo: true, email: 'x@y.z?bcc=otro@mal.com' }, ctx.RESTAS[0], 'correo').includes('?bcc='), 'un correo con «?bcc=» no agrega destinatarios')

let h = ctx.citaPendHTML(cita)
ok(!h.includes('<img') && !h.includes('<i>x</i>') && !h.includes('<b>Real</b>'), 'tarjeta por confirmar: nombre, telemarketer y lugar escapados')
ok(h.includes('<option value="19:00" selected>'), 'sin tocar nada: vienen elegidos el día y la hora que puso el telemarketer (lunes 7 p. m.)')
h = ctx.citaPendHTML({ ...cita, email: 'no-es-correo' })
ok(h.includes('no tiene correo válido') && /type="checkbox" disabled/.test(h), 'sin correo válido: la casilla de correo está apagada')
h = ctx.citaConfHTML({ ...cita, cita_confirmada_en: '2026-09-18T20:00:00Z', cita_confirmada_por: '<b>sup</b>' })
ok(!h.includes('<b>sup</b>'), 'quién confirmó sale escapado')
ok(h.includes('Mandar por WhatsApp') && !h.includes('Mandar por correo'), 'confirmada: solo el botón del canal aceptado')

console.log(fallas ? `🔴 ${fallas} falla(s)` : '✅ Citas y carta OK')
process.exit(fallas ? 1 : 0)
