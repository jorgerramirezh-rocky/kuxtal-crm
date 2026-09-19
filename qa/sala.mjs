// QA del bloque 4 (la sala: hostess, liner, closer por turno) SIN navegador: saca de app.html las
// funciones REALES y las corre con datos de prueba. Mide: quién aparece para cada puesto (solo los de
// turno en ESE lugar y con ESE rol), la partición «por llegar / en sala», que todo sale escapado, y
// que Recepción lee y escribe SOLO por las funciones de la base (nunca la tabla directo).
// node qa/sala.mjs
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
  linea('const esc='),
  "var LUGARES_TODOS=[{id:1,nombre:'Tre <b>Fratelli</b>'},{id:2,nombre:'El Portal'}];",
  "var TURNOS_HOY=[{id:1,restaurante_id:1,agente_id:21,nombre:'Liner <i>uno</i>',rol:'vendedor',disponible:true},{id:2,restaurante_id:1,agente_id:22,nombre:'L2',rol:'vendedor',disponible:false},{id:3,restaurante_id:2,agente_id:23,nombre:'L3 otro lugar',rol:'vendedor',disponible:true},{id:4,restaurante_id:1,agente_id:31,nombre:'C1',rol:'cerrador',disponible:true},{id:5,restaurante_id:1,agente_id:11,nombre:'H1',rol:'recepcion',disponible:true}];",
  ...['partesGT', 'enTurno', 'salaPartir', 'opTurno', 'recepCard', 'salaCard'].map(extraer),
].join('\n'), ctx)

let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }

const ids = (l) => l.map(t => t.agente_id).join(',')
ok(ids(ctx.enTurno(ctx.TURNOS_HOY, 1, 'vendedor')) === '21,22', 'liners: solo los de turno en ESE lugar')
ok(ids(ctx.enTurno(ctx.TURNOS_HOY, 1, 'cerrador')) === '31', 'closers: solo closers (ni liners ni hostess)')
ok(ctx.enTurno([], 1, 'vendedor').length === 0 && ctx.enTurno(null, 1, 'vendedor').length === 0, 'sin turno: nadie')
const op = ctx.opTurno(1, 'vendedor', 22)
ok(op.includes('value="22" selected') && op.includes('(no disponible)'), 'a mano: marca al elegido y avisa quién no está disponible')
ok(!op.includes('L3 otro lugar'), 'a mano: nunca ofrece a alguien de otra sala')
ok(op.includes('Liner &lt;i&gt;uno&lt;/i&gt;'), 'los nombres salen escapados')

const lista = [{ id: 1, etapa: 'telemarketing' }, { id: 2, etapa: 'sala' }, { id: 3, etapa: 'presentacion' }]
const pt = ctx.salaPartir(lista)
ok(pt.llegar.map(x => x.id).join() === '1,3' && pt.sala.map(x => x.id).join() === '2', 'por llegar / en sala')

const malo = { id: 7, nombre: 'Ana <img src=x onerror=alert(1)>', telefono: '<b>55</b>', restaurante_id: 1,
  presenta_en: '2026-09-19T18:00:00Z', tipo_tarjetas: '"><script>x</script>', motivo_no: '</textarea><b>' }
const rc = ctx.recepCard(malo)
ok(!rc.includes('<img') && !rc.includes('<script') && !rc.includes('</textarea><b>'), 'tarjeta de llegada: todo escapado')
ok(rc.includes('Tre &lt;b&gt;Fratelli&lt;/b&gt;') && rc.includes('12:00'), 'dice el lugar y la hora de Guatemala')
ok(rc.includes('Marcar llegada'), 'sin llegada: botón para marcarla')

const sinLiner = ctx.salaCard({ ...malo, etapa: 'sala', recepcion_en: '2026-09-19T18:05:00Z' })
ok(sinLiner.includes('Asignar liner') && !sinLiner.includes('Pasar a closer'), 'en sala sin liner: primero el liner, no hay closer')
const conLiner = ctx.salaCard({ ...malo, etapa: 'sala', vendedor_id: 21, vendedor: 'Liner <i>uno</i>' })
ok(conLiner.includes('Pasar a closer') && !conLiner.includes('<i>uno</i>') && conLiner.includes('Liner &lt;i&gt;uno&lt;/i&gt;'), 'con liner: aparece «Pasar a closer» y el liner escapado (sin HTML crudo)')
const conCloser = ctx.salaCard({ ...malo, etapa: 'sala', vendedor_id: 21, vendedor: 'L', cerrador_id: 31, cerrador: 'C1' })
ok(!conCloser.includes('Pasar a closer') && conCloser.includes('Siguiente en la rueda'), 'con closer: se puede pasar al siguiente de la rueda')
ok(!sinLiner.includes('<img'), 'tarjeta de sala: escapada')

// Recepción no toca la tabla: ni lee funnel_prospectos ni la escribe con funPatchLead.
const bloque = src.slice(src.indexOf('// ── RECEPCIÓN (sala de ventas'), src.indexOf('// ── CIERRE (contrato + comisiones) ──'))
ok(bloque.includes("rpcSala('funnel_sala_hoy')") && !bloque.includes('funnel_prospectos?'), 'Recepción lee SOLO por funnel_sala_hoy')
ok(!bloque.includes('funPatchLead') && !/\bev\(/.test(bloque), 'Recepción escribe SOLO por funciones (sin PATCH ni bitácora a mano)')
ok(/MIS_PERMISOS\.recibir_sala\|\|MIS_PERMISOS\.armar_turnos\) defs\.push\(\['recepcion'/.test(src), 'la pestaña Recepción depende del permiso de la matriz')
ok(src.includes("verTodo=esGerente||(VENTAS.includes(ROLE)&&ROLE!=='recepcion')"), 'la hostess ya no «ve todo» en la pantalla')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Sala OK')
