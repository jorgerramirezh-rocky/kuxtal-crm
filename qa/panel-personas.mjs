// QA del panel «Personas del equipo» (bloque 1, paso 3) SIN navegador: saca de app.html las
// funciones del panel y las corre con datos de prueba. Mide lo que la pantalla promete:
// todo escapado (nombre, correo, jefe, id), nada sobre uno mismo, y que nunca se ofrece un
// rol que no corresponde. El servidor igual lo frena; esto evita que la pantalla mienta.
import { readFileSync } from 'node:fs'
const s = readFileSync(new URL('../app.html', import.meta.url), 'utf8')
const i = s.indexOf('// ── Bloque 1 · paso 3 · PERSONAS DEL EQUIPO')
const j = s.indexOf('const rolNombre=clave=>', i)
const k = s.indexOf('\n', j)
const e = s.indexOf('const esc=')
if (i < 0 || j < 0 || e < 0) { console.log('🔴 no encontré el panel de personas en app.html'); process.exit(1) }
const codigo = `let ROLE="admin", UID="u-admin", ROLDATA, SES={access_token:"t"}, SB_URL="x", SB_PUB="y";
const esAdmin=()=>ROLE==="admin"; const $=()=>({}); const toast=()=>{}; const api=async()=>({ok:false});
const refrescar=async()=>false; const cargarRoles=()=>{}; const cerrarRol=()=>{};
${s.slice(e, s.indexOf('\n', e))}
${s.slice(i, k + 1)}
return { personasHTML, opcionesJefe, rolesAsignables, fijar:(r,d)=>{ ROLE=r; ROLDATA=d; } };`
const p = new Function(codigo)()
let fallas = 0
const ok = (c, m) => { console.log((c ? '✅ ' : '🔴 ') + m); if (!c) fallas++ }
const datos = {
  roles: [{ clave: 'admin', nombre: 'Administrador', nivel: 100, activo: true, es_staff: true },
    { clave: 'telemarketing', nombre: 'Telemarketing', nivel: 50, activo: true, es_staff: true, rol_operativo: 'tmk' },
    { clave: 'cliente', nombre: 'Cliente', nivel: 0, activo: true, es_staff: false }],
  agentes: [{ id: 4, nombre: 'Ana <b>jefa</b>', rol: 'tmk', activo: true }],
}
p.fijar('admin', datos)
const malo = '<img src=x onerror=alert(1)>'
const h = p.personasHTML([
  { user_id: 'u-admin', correo: 'a@k.gt', nombre: 'Admin', rol: 'admin', rol_nombre: 'Administrador', activo: true, jefe_id: null },
  { user_id: "u2')+alert(1)+('", correo: malo, nombre: malo, rol: 'telemarketing', rol_nombre: 'Telemarketing', activo: false, jefe_id: 4 }])
ok(!h.includes('<img'), 'el nombre y el correo con <img> salen escapados')
ok(!h.includes("u2')+alert(1)"), 'un id raro no rompe el onclick')
ok(h.includes('Vos') && (h.match(/Cambiar rol/g) || []).length === 1, 'sobre uno mismo no hay botones')
ok(h.includes('>Activar<') && !h.includes('Reenviar enlace'), 'desactivada: solo «Activar»')
ok(h.includes('Ana &lt;b&gt;jefa'), 'el jefe sale escapado')
ok(p.personasHTML(undefined) === '', 'sin permiso: no se muestra nada')
ok(p.personasHTML(null).includes('No pude leer'), 'si no se pudo leer: lo avisa')
ok(p.opcionesJefe('').includes('Telemarketing'), 'el jefe se muestra con el nombre visible de su rol')
p.fijar('telemarketing', datos); ok(p.rolesAsignables().every((r) => r.nivel < 50), 'quien no es admin solo ve roles por debajo')
p.fijar('admin', datos); ok(!p.rolesAsignables().some((r) => r.clave === 'cliente'), 'nunca se ofrece «cliente»')
console.log(fallas ? `🔴 ${fallas} falla(s)` : '✅ panel de personas OK')
process.exit(fallas ? 1 : 0)
