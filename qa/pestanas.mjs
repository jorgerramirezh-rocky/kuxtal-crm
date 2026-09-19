// QA bloque 8.1: la pestaña «Embudo» la ve TODO puesto que trabaja en él, con la regla REAL de app.html.
// (En vivo, desde la v2.11, liner, closer, digitador, verificador y hostess entraban y no tenían pestaña.)
// node qa/pestanas.mjs
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
const src = readFileSync(new URL('../app.html', import.meta.url), 'utf8')
const linea = (ini) => { const i = src.indexOf(ini); if (i < 0) throw new Error('no encontré ' + ini); return src.slice(i, src.indexOf('\n', i)) }
let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }
const ctx = {}; vm.createContext(ctx)
vm.runInContext('var ROLE="", verTodo=false;\n' + linea('const PUESTOS_EMBUDO=') + '\n' + linea('const puedeEmbudo=') + '\nthis.puedeEmbudo=puedeEmbudo; this.set=(r,v)=>{ROLE=r;verTodo=v};', ctx)
for (const r of ['telemarketing', 'tmk', 'supervisor_tmk', 'supervisor', 'recepcion', 'vendedor', 'cerrador', 'digitador', 'verificador']) {
  ctx.set(r, false); ok(ctx.puedeEmbudo(), `${r} ve la pestaña Embudo`)
}
ctx.set('gerente_ventas', true); ok(ctx.puedeEmbudo(), 'la gerencia (ve todo) ve la pestaña Embudo')
ctx.set('cliente', false); ok(!ctx.puedeEmbudo(), 'un socio (cliente) NO ve el Embudo')
if (fallas) { console.log(`🔴 ${fallas} fallas`); process.exit(1) }
console.log('✅ Pestañas OK')
