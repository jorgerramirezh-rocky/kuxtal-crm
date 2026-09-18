// Pruebas de `kuxtal-personas` contra un Supabase SIMULADO (sin red, sin desplegar).
// Correr:  deno test supabase/functions/kuxtal-personas/
import { assert, assertEquals, assertMatch } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { armarCorreo, crearAtender, generarClaveTemporal, type Config } from './logica.ts'

const BASE = 'https://proyecto.supabase.co'
const APP = 'https://crm.kuxtal.autofix.solutions'
const PUB = 'sb_publishable_PRUEBA'
const SERV = 'sb_secret_SERVICIO_NO_SE_MUESTRA'
const RESEND = 're_LLAVE_DE_ENVIO'
const HASH = 'hashtoken_de_un_solo_uso_1234567890'

const ADMIN = '00000000-0000-4000-8000-000000000001'
const SUPER = '00000000-0000-4000-8000-000000000002'
const TMK = '00000000-0000-4000-8000-000000000003'
const GERENTE = '00000000-0000-4000-8000-000000000004'
const NUEVA = '00000000-0000-4000-8000-0000000000aa'
const SINROL = '00000000-0000-4000-8000-0000000000bb'
const BAJA = '00000000-0000-4000-8000-0000000000cc'

type Llamada = { url: string, metodo: string, headers: Record<string, string>, cuerpo: string }

const ROLES = [
  { clave: 'admin', nombre: 'Administrador', nivel: 100, es_staff: true, activo: true },
  { clave: 'gerente_ventas', nombre: 'Gerente de Ventas', nivel: 80, es_staff: true, activo: true },
  { clave: 'supervisor_tmk', nombre: 'Supervisor de TMK', nivel: 70, es_staff: true, activo: true },
  { clave: 'telemarketing', nombre: 'Telemarketing', nivel: 50, es_staff: true, activo: true },
  { clave: 'vendedor', nombre: 'Liner (vendedor)', nivel: 40, es_staff: true, activo: true },
  { clave: 'cliente', nombre: 'Cliente', nivel: 0, es_staff: false, activo: true },
  { clave: 'viejo', nombre: 'Rol apagado', nivel: 10, es_staff: true, activo: false },
]

function simulado(op: {
  permisos?: Record<string, { puede: boolean, nivel: number, rol: string }>
  crearFalla?: { estado: number, code: string }
  registrarFalla?: string
  registrarFallaSoloAlta?: boolean
  listarTrasFalla?: 'en_equipo' | 'sin_equipo' | 'error'
  correoFalla?: boolean
  borrarFalla?: boolean
} = {}) {
  const llamadas: Llamada[] = []
  const tokens: Record<string, string> = { t_admin: ADMIN, t_super: SUPER, t_tmk: TMK }
  const permisos = op.permisos ?? {
    t_admin: { puede: true, nivel: 100, rol: 'admin' },
    t_super: { puede: true, nivel: 70, rol: 'supervisor_tmk' },
    t_tmk: { puede: false, nivel: 50, rol: 'telemarketing' },
  }
  const personas = [
    { user_id: ADMIN, correo: 'admin@kx.gt', nombre: 'Admin', rol: 'admin', rol_nombre: 'Administrador', nivel: 100, activo: true, agente_id: null, jefe_id: null },
    { user_id: SUPER, correo: 'super@kx.gt', nombre: 'Super', rol: 'supervisor_tmk', rol_nombre: 'Supervisor de TMK', nivel: 70, activo: true, agente_id: 1, jefe_id: null },
    { user_id: TMK, correo: 'tmk@kx.gt', nombre: 'Tele', rol: 'telemarketing', rol_nombre: 'Telemarketing', nivel: 50, activo: true, agente_id: 2, jefe_id: 1 },
    { user_id: GERENTE, correo: 'gerente@kx.gt', nombre: 'Gerente', rol: 'gerente_ventas', rol_nombre: 'Gerente de Ventas', nivel: 80, activo: false, agente_id: null, jefe_id: null },
    { user_id: SINROL, correo: 'sinrol@kx.gt', nombre: 'Sin rol', rol: null, rol_nombre: null, nivel: null, activo: true, agente_id: null, jefe_id: null },
    { user_id: BAJA, correo: 'baja@kx.gt', nombre: 'De baja', rol: 'telemarketing', rol_nombre: 'Telemarketing', nivel: 50, activo: false, agente_id: null, jefe_id: null },
  ]
  let fallóRegistrar = false
  const json = (estado: number, d: unknown) => new Response(d === null ? '' : JSON.stringify(d), { status: estado })
  const f: typeof fetch = async (entrada, init) => {
    const url = String(entrada)
    const metodo = (init?.method ?? 'GET').toUpperCase()
    const headers = (init?.headers ?? {}) as Record<string, string>
    const cuerpo = typeof init?.body === 'string' ? init.body : ''
    llamadas.push({ url, metodo, headers, cuerpo })
    const bearer = (headers.Authorization ?? '').replace('Bearer ', '')
    if (url === 'https://api.resend.com/emails') return op.correoFalla ? json(500, { message: 'no' }) : json(200, { id: 'm1' })
    if (!url.startsWith(BASE)) return json(404, null)
    const ruta = url.slice(BASE.length)
    if (ruta === '/auth/v1/user') return tokens[bearer] ? json(200, { id: tokens[bearer] }) : json(401, { msg: 'jwt' })
    if (ruta === '/rest/v1/rpc/funnel_personas_puedo') return json(200, permisos[bearer] ?? { puede: false, nivel: 0, rol: '' })
    if (ruta === '/rest/v1/rpc/funnel_personas_listar') {
      if (fallóRegistrar && op.listarTrasFalla === 'error') return json(500, { code: 'x' })
      const extra = fallóRegistrar && op.listarTrasFalla === 'en_equipo'
        ? [{ user_id: NUEVA, correo: 'nueva@kx.gt', nombre: 'Nueva', rol: 'telemarketing', rol_nombre: 'Telemarketing', nivel: 50, activo: true, agente_id: 9, jefe_id: null }]
        : []
      return json(200, [...personas, ...extra])
    }
    if (ruta.startsWith('/rest/v1/funnel_personas_bitacora?')) {
      if (fallóRegistrar && op.listarTrasFalla === 'error') return json(500, { code: 'x' })
      return json(200, fallóRegistrar && op.listarTrasFalla === 'en_equipo' ? [{ id: 1 }] : [])
    }
    if (ruta === '/rest/v1/rpc/funnel_ve_equipo') return json(200, bearer === 't_super' ? [1, 2] : [])
    if (ruta.startsWith('/rest/v1/funnel_roles?')) {
      const clave = decodeURIComponent(ruta.split('clave=eq.')[1] ?? '')
      return json(200, ROLES.filter((r) => r.clave === clave))
    }
    if (ruta === '/rest/v1/rpc/funnel_personas_registrar') {
      const args = JSON.parse(cuerpo)
      if (op.registrarFalla && (!op.registrarFallaSoloAlta || args.p_accion === 'alta')) {
        fallóRegistrar = true
        return json(400, { code: op.registrarFalla })
      }
      return json(200, args.p_accion === 'alta' ? 0 : 2)
    }
    if (ruta === '/auth/v1/admin/users' && metodo === 'POST') {
      if (op.crearFalla) return json(op.crearFalla.estado, { error_code: op.crearFalla.code })
      return json(200, { id: NUEVA, created_at: new Date().toISOString() })
    }
    if (ruta.startsWith('/auth/v1/admin/users/') && metodo === 'PUT') return json(200, { id: ruta.split('/').pop() })
    if (ruta.startsWith('/auth/v1/admin/users/') && metodo === 'DELETE') return op.borrarFalla ? json(500, {}) : json(200, {})
    if (ruta === '/auth/v1/admin/generate_link') return json(200, { properties: { hashed_token: HASH } })
    return json(404, null)
  }
  const cfg: Config = {
    urlBase: BASE, llavePublica: PUB, llaveServicio: SERV, urlApp: APP, fetch: f,
    generarClave: () => 'Abcd-Efgh-2345',
    correo: { llave: RESEND, remitente: 'Kuxtal Travels <kuxtal@autofix.solutions>', responderA: 'soporte@autofix.solutions' },
  }
  return { llamadas, cfg }
}

async function pedir(cfg: Config, token: string | null, cuerpo: unknown, metodo = 'POST') {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (token !== null) headers.Authorization = `Bearer ${token}`
  const r = await crearAtender(cfg)(new Request(`${BASE}/functions/v1/kuxtal-personas`, {
    method: metodo, headers, body: metodo === 'POST' ? JSON.stringify(cuerpo) : undefined,
  }))
  const texto = await r.text()
  return { estado: r.status, texto, d: texto ? JSON.parse(texto) : null, r }
}
const aAuth = (ll: Llamada[]) => ll.filter((l) => l.url.includes('/auth/v1/admin'))
const registros = (ll: Llamada[]) => ll.filter((l) => l.url.endsWith('/rpc/funnel_personas_registrar'))
const ALTA = { accion: 'alta', correo: 'Nueva@KX.gt', nombre: 'Nueva Persona', rol: 'telemarketing', jefe_id: 1 }

Deno.test('sin sesión: 401 y dice qué acciones sabe (para el despliegue)', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, null, ALTA)
  assertEquals(r.estado, 401); assertEquals(r.d.codigo, 'sin_sesion'); assertEquals(r.d.acciones.length, 5)
  assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('con la llave pública como token: 401', async () => {
  const { cfg } = simulado()
  assertEquals((await pedir(cfg, PUB, ALTA)).estado, 401)
})
Deno.test('token inválido: 401 sesion_invalida', async () => {
  const { cfg } = simulado()
  const r = await pedir(cfg, 't_inventado', ALTA)
  assertEquals(r.estado, 401); assertEquals(r.d.codigo, 'sesion_invalida')
})
Deno.test('sin «gestionar personas»: 403 y no toca Auth ni la base', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_tmk', ALTA)
  assertEquals(r.estado, 403); assertEquals(r.d.codigo, 'sin_permiso')
  assertEquals(aAuth(llamadas).length, 0); assertEquals(registros(llamadas).length, 0)
})
Deno.test('alta con correo: cuenta con su rol, registro con la llave de servicio, enlace SOLO en el correo', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', ALTA)
  assertEquals(r.estado, 200); assertEquals(r.d.codigo, 'dada_de_alta'); assertEquals(r.d.correo_enviado, true)
  assertEquals(r.d.clave_temporal, undefined)
  const crear = aAuth(llamadas).find((l) => l.metodo === 'POST' && l.url.endsWith('/admin/users'))!
  const c = JSON.parse(crear.cuerpo)
  assertEquals(c.email, 'nueva@kx.gt'); assertEquals(c.app_metadata.role, 'telemarketing'); assertEquals(c.email_confirm, true)
  const reg = registros(llamadas)[0]!
  assertEquals(reg.headers.apikey, SERV); assertEquals(JSON.parse(reg.cuerpo).p_jefe, 1); assertEquals(JSON.parse(reg.cuerpo).p_actor, ADMIN)
  const conHash = llamadas.filter((l) => l.cuerpo.includes(HASH) || l.url.includes(HASH))
  assertEquals(conHash.length, 1); assertEquals(conHash[0]!.url, 'https://api.resend.com/emails')
  assert(conHash[0]!.cuerpo.includes(`${APP}/crear-clave.html#t=${HASH}`))
  assert(!r.texto.includes(HASH)); assert(!r.texto.includes(SERV)); assert(!r.texto.includes(RESEND))
  assertEquals(r.r.headers.get('Cache-Control'), 'no-store'); assertEquals(r.r.headers.get('Access-Control-Allow-Origin'), APP)
})
Deno.test('alta cuando el correo no sale: muestra la clave temporal UNA vez y lo dice', async () => {
  const { cfg } = simulado({ correoFalla: true })
  const r = await pedir(cfg, 't_admin', ALTA)
  assertEquals(r.estado, 200); assertEquals(r.d.correo_enviado, false); assertEquals(r.d.clave_temporal, 'Abcd-Efgh-2345')
  assertMatch(r.d.mensaje, /NO pude mandarle el correo/)
})
Deno.test('un supervisor no fabrica un gerente (rol de su nivel o más alto): 403 sin tocar Auth', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_super', { ...ALTA, rol: 'gerente_ventas' })
  assertEquals(r.estado, 403); assertEquals(r.d.codigo, 'rol_alto'); assertEquals(aAuth(llamadas).length, 0)
  assertEquals((await pedir(cfg, 't_super', { ...ALTA, rol: 'supervisor_tmk' })).d.codigo, 'rol_alto')
})
Deno.test('un supervisor sí da de alta a alguien por debajo', async () => {
  const { cfg } = simulado()
  assertEquals((await pedir(cfg, 't_super', ALTA)).estado, 200)
})
Deno.test('roles que no son del equipo o están apagados: 400', async () => {
  const { cfg, llamadas } = simulado()
  for (const rol of ['cliente', 'viejo', 'inventado', 'DROP TABLE']) {
    assertEquals((await pedir(cfg, 't_admin', { ...ALTA, rol })).estado, 400)
  }
  assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('correo que ya está en el equipo: 409 sin crear nada', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', { ...ALTA, correo: 'TMK@kx.gt' })
  assertEquals(r.estado, 409); assertEquals(r.d.codigo, 'ya_existe'); assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('correo con cuenta fuera del equipo (socio): 409 cuenta_existente', async () => {
  const { cfg } = simulado({ crearFalla: { estado: 422, code: 'email_exists' } })
  assertEquals((await pedir(cfg, 't_admin', ALTA)).d.codigo, 'cuenta_existente')
})
Deno.test('datos malos: 400', async () => {
  const { cfg } = simulado()
  assertEquals((await pedir(cfg, 't_admin', { ...ALTA, correo: 'no-es-correo' })).estado, 400)
  assertEquals((await pedir(cfg, 't_admin', { ...ALTA, nombre: '' })).estado, 400)
  assertEquals((await pedir(cfg, 't_admin', { ...ALTA, jefe_id: 'uno' })).estado, 400)
  assertEquals((await pedir(cfg, 't_admin', { accion: 'borrar_todo' })).d.codigo, 'accion_desconocida')
})
Deno.test('la base no registra el alta (jefe inválido): se borra la cuenta NUEVA y lo dice', async () => {
  const { cfg, llamadas } = simulado({ registrarFalla: 'KXP03', listarTrasFalla: 'sin_equipo' })
  const r = await pedir(cfg, 't_admin', ALTA)
  assertEquals(r.estado, 400); assertEquals(r.d.codigo, 'alta_incompleta'); assertMatch(r.d.mensaje, /jefe/)
  assertEquals(aAuth(llamadas).filter((l) => l.metodo === 'DELETE').length, 1)
  assertEquals(r.d.clave_temporal, undefined)
})
Deno.test('si se perdió solo la confirmación y la persona SÍ quedó: no se borra nada', async () => {
  const { cfg, llamadas } = simulado({ registrarFalla: '57014', listarTrasFalla: 'en_equipo' })
  const r = await pedir(cfg, 't_admin', ALTA)
  assertEquals(r.d.codigo, 'confirmacion_perdida'); assertEquals(aAuth(llamadas).filter((l) => l.metodo === 'DELETE').length, 0)
})
Deno.test('si no se puede revisar tras el fallo: no se borra nada', async () => {
  const { cfg, llamadas } = simulado({ registrarFalla: '57014', listarTrasFalla: 'error' })
  assertEquals((await pedir(cfg, 't_admin', ALTA)).d.codigo, 'confirmacion_perdida')
  assertEquals(aAuth(llamadas).filter((l) => l.metodo === 'DELETE').length, 0)
})
Deno.test('nada sobre uno mismo', async () => {
  const { cfg, llamadas } = simulado()
  for (const accion of ['desactivar', 'restablecer', 'cambiar_rol']) {
    const r = await pedir(cfg, 't_admin', { accion, user_id: ADMIN, rol: 'telemarketing' })
    assertEquals(r.estado, 409); assertEquals(r.d.codigo, 'a_si_mismo')
  }
  assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('un supervisor no toca a alguien de su nivel o más alto', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_super', { accion: 'desactivar', user_id: GERENTE })
  assertEquals(r.estado, 403); assertEquals(r.d.codigo, 'nivel_alto'); assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('cambiar el rol: Auth primero, después la base; cierra sesiones', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: TMK, rol: 'vendedor' })
  assertEquals(r.estado, 200); assertEquals(r.d.codigo, 'rol_cambiado'); assertEquals(r.d.sesiones_cerradas, 2)
  const put = aAuth(llamadas).find((l) => l.metodo === 'PUT')!
  assertEquals(JSON.parse(put.cuerpo).app_metadata.role, 'vendedor')
  assert(llamadas.indexOf(put) < llamadas.indexOf(registros(llamadas)[0]!))
})
Deno.test('cambiar el rol y la base falla: le devuelve el rol de antes', async () => {
  const { cfg, llamadas } = simulado({ registrarFalla: 'KXP03' })
  const r = await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: TMK, rol: 'vendedor', jefe_id: 77 })
  assertEquals(r.d.codigo, 'rol_sin_cambiar'); assertMatch(r.d.mensaje, /rol de antes/)
  const puts = aAuth(llamadas).filter((l) => l.metodo === 'PUT').map((l) => JSON.parse(l.cuerpo).app_metadata.role)
  assertEquals(puts, ['vendedor', 'telemarketing'])
})
Deno.test('desactivar: bloqueo largo en Auth; activar: lo quita', async () => {
  const { cfg, llamadas } = simulado()
  assertEquals((await pedir(cfg, 't_admin', { accion: 'desactivar', user_id: TMK })).d.codigo, 'desactivada')
  assertEquals((await pedir(cfg, 't_admin', { accion: 'activar', user_id: GERENTE })).d.codigo, 'activada')
  const bans = aAuth(llamadas).filter((l) => l.metodo === 'PUT').map((l) => JSON.parse(l.cuerpo).ban_duration)
  assertEquals(bans, ['876000h', 'none'])
})
Deno.test('reenviar enlace a alguien desactivado: 409 sin tocar su clave', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', { accion: 'restablecer', user_id: GERENTE })
  assertEquals(r.d.codigo, 'de_baja'); assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('reenviar enlace: NO toca la clave; el enlace solo en el correo', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', { accion: 'restablecer', user_id: TMK })
  assertEquals(r.d.codigo, 'enlace_enviado'); assert(!r.texto.includes(HASH)); assertEquals(r.d.clave_temporal, undefined)
  assertEquals(aAuth(llamadas).filter((l) => l.metodo === 'PUT').length, 0)
  assertEquals(llamadas.filter((l) => l.cuerpo.includes(HASH) || l.url.includes(HASH)).length, 1)
})
Deno.test('reenviar enlace con el correo caído: error, sin clave para nadie y sin tocar la cuenta', async () => {
  const { cfg, llamadas } = simulado({ correoFalla: true })
  const r = await pedir(cfg, 't_super', { accion: 'restablecer', user_id: TMK })
  assertEquals(r.estado, 502); assertEquals(r.d.codigo, 'correo_no_salio'); assertEquals(r.d.clave_temporal, undefined)
  assertEquals(aAuth(llamadas).filter((l) => l.metodo === 'PUT').length, 0); assertEquals(registros(llamadas).length, 0)
})
Deno.test('reenviar enlace sin correo configurado: 503, no hace nada', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir({ ...cfg, correo: null }, 't_admin', { accion: 'restablecer', user_id: TMK })
  assertEquals(r.d.codigo, 'sin_correo'); assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('cambiar el rol a alguien desactivado: 409, no vuelve al reparto', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: BAJA, rol: 'vendedor' })
  assertEquals(r.d.codigo, 'de_baja'); assertEquals(aAuth(llamadas).length, 0)
})
Deno.test('una cuenta sin rol solo la toca quien administra', async () => {
  const { cfg } = simulado()
  assertEquals((await pedir(cfg, 't_super', { accion: 'cambiar_rol', user_id: SINROL, rol: 'telemarketing' })).d.codigo, 'sin_rol')
  assertEquals((await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: SINROL, rol: 'telemarketing' })).estado, 200)
})
Deno.test('quien no es admin solo elige jefe de SU equipo', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir(cfg, 't_super', { ...ALTA, jefe_id: 99 })
  assertEquals(r.estado, 403); assertEquals(r.d.codigo, 'jefe_ajeno'); assertEquals(aAuth(llamadas).length, 0)
  assertEquals((await pedir(cfg, 't_super', { ...ALTA, jefe_id: 2 })).estado, 200)
})
Deno.test('cambiar el rol manda si hay que cambiar el jefe (quitarlo = jefe_id null)', async () => {
  const { cfg, llamadas } = simulado()
  await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: TMK, rol: 'vendedor', jefe_id: null })
  await pedir(cfg, 't_admin', { accion: 'cambiar_rol', user_id: TMK, rol: 'vendedor' })
  const a = registros(llamadas).map((l) => JSON.parse(l.cuerpo))
  assertEquals([a[0].p_cambiar_jefe, a[0].p_jefe], [true, null]); assertEquals(a[1].p_cambiar_jefe, false)
})
Deno.test('persona que no está en el equipo: 404', async () => {
  const { cfg } = simulado()
  assertEquals((await pedir(cfg, 't_admin', { accion: 'desactivar', user_id: NUEVA })).estado, 404)
})
Deno.test('sin configurar (sin dirección del CRM): 500 y no hace nada', async () => {
  const { cfg, llamadas } = simulado()
  const r = await pedir({ ...cfg, urlApp: undefined }, 't_admin', ALTA)
  assertEquals(r.estado, 500); assertEquals(r.d.codigo, 'sin_configurar'); assertEquals(llamadas.length, 0)
})
Deno.test('OPTIONS: 204 con CORS solo para el CRM', async () => {
  const { cfg } = simulado()
  const r = await crearAtender(cfg)(new Request(`${BASE}/x`, { method: 'OPTIONS' }))
  assertEquals(r.status, 204); assertEquals(r.headers.get('Access-Control-Allow-Origin'), APP)
})
Deno.test('ninguna respuesta de ningún camino lleva la llave del servidor ni la de correo', async () => {
  const casos: [Parameters<typeof simulado>[0], string | null, unknown][] = [
    [{}, 't_admin', ALTA], [{ correoFalla: true }, 't_admin', ALTA], [{ registrarFalla: 'KXP03' }, 't_admin', ALTA],
    [{}, 't_tmk', ALTA], [{}, null, ALTA], [{}, 't_admin', { accion: 'cambiar_rol', user_id: TMK, rol: 'vendedor' }],
  ]
  for (const [op, tok, cuerpo] of casos) {
    const { cfg } = simulado(op)
    const r = await pedir(cfg, tok, cuerpo)
    assert(!r.texto.includes(SERV) && !r.texto.includes(RESEND), `se filtró una llave en ${r.texto}`)
  }
})
Deno.test('clave temporal: formato legible, con mayúscula, minúscula y dígito', () => {
  for (let i = 0; i < 50; i++) assertMatch(generarClaveTemporal(), /^[A-HJ-NP-Za-km-z2-9]{4}-[A-HJ-NP-Za-km-z2-9]{4}-[A-HJ-NP-Za-km-z2-9]{4}$/)
})
Deno.test('el correo escapa el nombre (un nombre con < no arma HTML)', () => {
  const c = armarCorreo({ nombre: '<img src=x onerror=alert(1)>', correo: 'a@b.gt', enlace: `${APP}/crear-clave.html#t=x`, nueva: true })
  assert(!c.html.includes('<img')); assert(c.html.includes('&lt;img'))
})
