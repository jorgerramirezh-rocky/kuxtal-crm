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
  "var BORR={}, NOCAL={}, CAMBIO={};", linea('const horaGT='),
  ...['partesGT', 'enTurno', 'salaPartir', 'avisosSala', 'valB', 'opTurno', 'recepCard', 'salaCard'].map(extraer),
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

const lista = [{ id: 1, etapa: 'telemarketing', presenta_en: 'b' }, { id: 2, etapa: 'sala' }, { id: 3, etapa: 'presentacion', presenta_en: 'c', recepcion_en: 'x' },
  { id: 4, etapa: 'sala', cerrador_id: 9 }]
const pt = ctx.salaPartir(lista)
ok(pt.llegar.map(x => x.id).join() === '3,1', 'por llegar: primero el que ya llegó y falta calificar')
ok(pt.sala.map(x => x.id).join() === '2' && pt.completos.map(x => x.id).join() === '4', 'en sala (sin closer) / completos (con closer)')

const av = ctx.avisosSala([{ restaurante_id: 1 }, { restaurante_id: 2 }], ctx.TURNOS_HOY, ctx.LUGARES_TODOS)
ok(av.length === 1 && av[0].includes('El Portal no hay closer') && !av[0].includes('liner'),
   'avisos por lugar y por puesto (Tre Fratelli completo: sin aviso; El Portal: falta closer)')
ok(ctx.avisosSala([{ restaurante_id: 1 }], ctx.TURNOS_HOY.filter(t => t.rol !== 'cerrador'), ctx.LUGARES_TODOS)[0].includes('no hay closer'), 'sin closer en el lugar: avisa aunque haya liner y hostess')
ok(ctx.avisosSala([{ restaurante_id: 1 }], [{ restaurante_id: 1, rol: 'vendedor', disponible: false }, { restaurante_id: 1, rol: 'cerrador', disponible: true }], ctx.LUGARES_TODOS)[0].includes('no hay liner'), 'un liner fuera de la rueda no cuenta como disponible')

const malo = { id: 7, nombre: 'Ana <img src=x onerror=alert(1)>', telefono: '<b>55</b>', restaurante_id: 1,
  presenta_en: '2026-09-19T18:00:00Z', tipo_tarjetas: '"><script>x</script>', motivo_no: '</textarea><b>' }
const antes = ctx.recepCard(malo, false)
ok(antes.includes('>Llegó</button>') && !antes.includes('Califica'), 'antes de llegar: solo el botón «Llegó» (no se califica sin llegada)')
ok(!antes.includes('Tre') && ctx.recepCard(malo, true).includes('Tre &lt;b&gt;Fratelli&lt;/b&gt;'), 'el lugar solo se nombra cuando se ven varios')
ok(antes.includes('cita 12:00'), 'hora de Guatemala en 24 h')
const llego = { ...malo, recepcion_en: '2026-09-19T18:05:00Z' }
const rc = ctx.recepCard(llego, true)
ok(!rc.includes('<img') && !rc.includes('<script') && !rc.includes('</textarea><b>'), 'tarjeta de llegada: todo escapado')
ok(rc.includes('Llegó 12:05') && rc.includes('Califica → a sala') && rc.includes('No califica…') && !rc.includes('Confirmar: no califica'), 'llegó: datos + califica; «no califica» pide un paso más')
ctx.NOCAL[7] = true
const rcNo = ctx.recepCard(llego, true)
ok(rcNo.includes('Confirmar: no califica') && rcNo.includes('Cancelar') && !rcNo.includes('Califica → a sala'), 'no califica: pide motivo y confirmación')
ok(!rcNo.includes('</textarea><b>'), 'el motivo sale escapado')
ctx.NOCAL[7] = false
ctx.BORR[7] = { edad: '41', ttc: 'Amex <x>' }
const rcB = ctx.recepCard(llego, true)
ok(rcB.includes('value="41"') && rcB.includes('Amex &lt;x&gt;'), 'lo que la hostess ya escribió se conserva al repintar (y escapado)')
ctx.BORR = {}

const sinLiner = ctx.salaCard({ ...llego, etapa: 'sala' }, false)
ok(sinLiner.includes('Asignar liner') && !sinLiner.includes('Pasar a closer'), 'en sala sin liner: primero el liner, no hay closer')
const conLiner = ctx.salaCard({ ...llego, etapa: 'sala', vendedor_id: 21, vendedor: 'Liner <i>uno</i>' }, false)
ok(conLiner.includes('Pasar a closer') && !conLiner.includes('<i>uno</i>') && conLiner.includes('Liner &lt;i&gt;uno&lt;/i&gt;'), 'con liner: aparece «Pasar a closer» y el liner escapado (sin HTML crudo)')
ok(!conLiner.includes('Siguiente en la rueda') && conLiner.includes('Cambiar liner…'), 'con liner: cambiarlo pide abrir «Cambiar…» (no un toque suelto)')
ctx.CAMBIO['7vendedor'] = true
const abierto = ctx.salaCard({ ...llego, etapa: 'sala', vendedor_id: 21, vendedor: 'L' }, false)
ok(abierto.includes('Siguiente en la rueda') && abierto.includes('>Asignar</button>') && !/onchange=/.test(abierto), 'cambio abierto: rueda o a mano con botón «Asignar» (el select solo no asigna)')
ctx.CAMBIO = {}
ok(!sinLiner.includes('<img'), 'tarjeta de sala: escapada')

// Recepción no toca la tabla: ni lee funnel_prospectos ni la escribe con funPatchLead.
const bloque = src.slice(src.indexOf('// ── RECEPCIÓN (sala de ventas'), src.indexOf('// ── CIERRE (contrato + comisiones) ──'))
ok(bloque.includes("rpcSala('funnel_sala_hoy')") && !bloque.includes('funnel_prospectos?'), 'Recepción lee SOLO por funnel_sala_hoy')
ok(!bloque.includes('funPatchLead') && !/\bev\(/.test(bloque), 'Recepción escribe SOLO por funciones (sin PATCH ni bitácora a mano)')
ok(/MIS_PERMISOS\.recibir_sala\|\|MIS_PERMISOS\.armar_turnos\) defs\.push\(\['recepcion'/.test(src), 'la pestaña Recepción depende del permiso de la matriz')
ok(src.includes("verTodo=esGerente||(VENTAS.includes(ROLE)&&ROLE!=='recepcion')"), 'la hostess ya no «ve todo» en la pantalla')

// ── comportamiento (con la base simulada): lo que la revisión de QA pidió medir, no solo textos ──
const llamadas = []
let respuesta = { ok: true, status: 200, json: async () => ({ agente_id: 22, nombre: 'L2' }) }
const b2 = { console, TZ_GT: 'America/Guatemala' }
vm.createContext(b2)
vm.runInContext([
  "var BORR={}, NOCAL={}, CAMBIO={}, toasts=[], el={};",
  "function $(id){ return el[id]||null; } function toast(m){ toasts.push(m); } function pintarRecepcion(){} function guardarBorr(){}",
  "var api=async (path,opt)=>{ llamadas.push({path, body: opt&&opt.body?JSON.parse(opt.body):null}); return respuesta(); };",
  "var MIS_PERMISOS={}, ROLE='', verTodo=false, esGerente=false, funTab='', MIS=null; function funPintarTabsOut(){}",
  ...['rpcSala', 'recepcionar', 'salaAsignar', 'funPintarTabs'].map(extraer),
].join('\n'), b2)
b2.llamadas = llamadas; b2.respuesta = () => respuesta
b2.el.funTabs = { innerHTML: '' }

await b2.recepcionar(7, false, { disabled: false })
ok(llamadas.length === 0 && b2.toasts.includes('Escribí por qué no califica'), '«no califica» sin motivo: no llama a la base')

b2.window = { __REC: [{ id: 5, vendedor_id: 21, cerrador_id: null }] }
vm.runInContext('var window=this.window;', b2)
const boton = { disabled: false, tagName: 'BUTTON' }
const p1 = b2.salaAsignar(5, 'vendedor', null, boton), p2 = b2.salaAsignar(5, 'vendedor', null, boton)
await p1; await p2
ok(llamadas.length === 1, 'doble toque: una sola asignación')
ok(llamadas[0] && llamadas[0].body.p_esperado === 21, 'manda a quién ve la pantalla (p_esperado = liner actual)')
llamadas.length = 0
await b2.salaAsignar(5, 'cerrador', null, { disabled: false })
ok(llamadas[0] && llamadas[0].body.p_esperado === 0, 'sin closer todavía: p_esperado = 0')

respuesta = { ok: false, status: 500, json: async () => ({ message: 'relation "x" does not exist' }) }
let m1 = ''; try { await b2.rpcSala('funnel_sala_hoy') } catch (e) { m1 = e.message }
ok(m1 === 'No se pudo', 'un error 500 no se muestra crudo')
respuesta = { ok: false, status: 400, json: async () => ({ message: 'no autorizado' }) }
let m2 = ''; try { await b2.rpcSala('funnel_sala_hoy') } catch (e) { m2 = e.message }
ok(m2 === 'No autorizado: pedile acceso al gerente', '«no autorizado» dice qué hacer')
vm.runInContext("api=async()=>{ throw new TypeError('Failed to fetch'); };", b2)
let m3 = ''; try { await b2.rpcSala('funnel_sala_hoy') } catch (e) { m3 = e.message }
ok(m3 === 'Se cortó la conexión, probá de nuevo', 'sin red: el aviso sale en español')

vm.runInContext("MIS_PERMISOS={recibir_sala:true}; ROLE='recepcion'; verTodo=false; esGerente=false;", b2); b2.funPintarTabs()
ok(/>Recepción</.test(b2.el.funTabs.innerHTML) && !/Mi día|Turnos|Cierre|Todos/.test(b2.el.funTabs.innerHTML), 'la hostess ve SOLO Recepción')
vm.runInContext("MIS_PERMISOS={recibir_sala:true,armar_turnos:true}; ROLE='supervisor'; verTodo=true; esGerente=true;", b2); b2.funPintarTabs()
ok(/>Turnos</.test(b2.el.funTabs.innerHTML) && /Recepción/.test(b2.el.funTabs.innerHTML), 'quien arma turnos ve Turnos y Recepción')

if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Sala OK')
