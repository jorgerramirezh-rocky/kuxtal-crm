// Kuxtal · Edge Function `kuxtal-personas` — LA LÓGICA (bloque 1, paso 3 · 18/19-sep-2026).
//
// Calcada de MyDay `admin-usuarios` (lo que ya funciona allá, con sus lecciones), con los
// roles y el equipo de Kuxtal. Acá no hay nada de Deno: todo lo de afuera (dirección de
// Supabase, llaves, dirección del CRM, `fetch`, el azar, el correo) entra por parámetro,
// así la misma lógica que corre en el servidor se prueba con `deno test` y un Supabase
// simulado (logica_test.ts).
//
// EL ORDEN (es la mitad del diseño):
//   1. ¿Quién llama? Su token se valida contra Auth (`/user`). Sin sesión válida: 401.
//   2. ¿Puede? Se le pregunta a la base CON SU TOKEN (`funnel_personas_puedo`): lo decide
//      la matriz de la pestaña Roles (permiso «gestionar_personas»). Si no: 403 y no se toca nada.
//   3. La acción: primero Auth (crear la cuenta, cambiarle el rol, la clave o el bloqueo),
//      DESPUÉS la base (`funnel_personas_registrar`, solo el rol de servicio): ata o suelta
//      su agente, cierra sesiones y anota la bitácora en la misma transacción.
//
// REGLAS DE KUXTAL:
//   · Nada sobre uno mismo (te podrías quedar afuera).
//   · Quien no es admin no da un rol de su nivel o más alto, ni toca a alguien de su nivel
//     o más alto: un supervisor no se fabrica un gerente.
//   · Solo roles del equipo (staff, activos). Las cuentas de socios (cliente) no se tocan acá.
//
// EL CORREO: con `correo` configurado, el alta y «reenviar enlace» piden a Auth un enlace de
// un solo uso (`/admin/generate_link`, tipo recovery) y lo mandan por Resend. El enlace va a
// `<CRM>/crear-clave.html#t=<token>`: la página pide TOCAR un botón antes de gastarlo (un
// antivirus que abre enlaces no lo consume) y el token, detrás de `#`, no llega a ningún
// servidor. El token viaja SOLO en la llamada a Resend, nunca en una respuesta. Si el correo
// falla, se muestra UNA vez la clave temporal a quien administra y el mensaje lo dice.
//
// NADA FALLA EN SILENCIO: cada error contesta un código y un mensaje en humano que la
// pantalla muestra tal cual; si algo quedó a medias, dice qué quedó hecho y qué no.

export const ACCIONES = ['alta', 'restablecer', 'cambiar_rol', 'desactivar', 'activar'] as const
export type Accion = (typeof ACCIONES)[number]

/** Cien años: el bloqueo de Auth no tiene "para siempre", tiene una duración. */
export const BANEO = '876000h'

/** Cuánto hacia atrás cuenta como "la cuenta la acaba de crear ESTE alta" (para borrarla si el alta quedó a medias). */
export const VENTANA_CUENTA_NUEVA_MS = 2 * 60 * 1000

/** Clave temporal: legible (sin 0/O, 1/l/I), 12 signos al azar ≈ 69 bits, con guiones. */
export const ALFABETO_CLAVE = 'ABCDEFGHJKLMNPQRSTUVWXYZ' + 'abcdefghijkmnpqrstuvwxyz' + '23456789'
export const LARGO_CLAVE = 12

export function generarClaveTemporal(
  llenar: (lote: Uint32Array) => Uint32Array = (lote) => crypto.getRandomValues(lote),
): string {
  const n = ALFABETO_CLAVE.length
  const limite = Math.floor(0x1_0000_0000 / n) * n
  let lotes = 0
  for (;;) {
    const signos: string[] = []
    while (signos.length < LARGO_CLAVE) {
      if (++lotes > 1000) throw new Error('el azar no alcanzó para una clave temporal')
      for (const v of llenar(new Uint32Array(LARGO_CLAVE * 2))) {
        if (signos.length === LARGO_CLAVE) break
        if (v < limite) signos.push(ALFABETO_CLAVE[v % n]!)
      }
    }
    const clave = `${signos.slice(0, 4).join('')}-${signos.slice(4, 8).join('')}-${signos.slice(8).join('')}`
    if (/[A-Z]/.test(clave) && /[a-z]/.test(clave) && /[2-9]/.test(clave)) return clave
  }
}

export type ConfigCorreo = { llave: string, remitente: string, responderA: string }

/** Tiene que coincidir con «Email OTP Expiration» de Auth (el script de despliegue lo fija en 86400). */
export const HORAS_DEL_ENLACE = 24

export type Config = {
  urlBase: string
  llavePublica: string
  llaveServicio: string
  urlApp: string | undefined
  fetch: typeof fetch
  ahora?: () => number
  generarClave?: () => string
  correo?: ConfigCorreo | null
}

export function esc(texto: string): string {
  return texto.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)
}

/** El correo: quién es, qué hacer (un botón) y cuánto dura. Ninguna clave adentro. */
export function armarCorreo(q: { nombre: string, correo: string, enlace: string, nueva: boolean }):
  { asunto: string, html: string, texto: string } {
  const asunto = q.nueva ? 'Tu cuenta del CRM de Kuxtal' : 'Creá tu clave nueva del CRM de Kuxtal'
  const intro = q.nueva
    ? 'Ya tenés cuenta en el CRM de Kuxtal. Para entrar, creá tu clave con el botón de abajo.'
    : 'Te mandaron un enlace nuevo para el CRM de Kuxtal. Creá tu clave con el botón de abajo; la de antes ya no sirve.'
  const aviso = `El enlace sirve una sola vez y vence en ${HORAS_DEL_ENLACE} horas. Si venció, pedile a quien administra el CRM que te lo mande de nuevo.`
  const texto = [
    `Hola, ${q.nombre}:`, '', intro, '', `Tu usuario: ${q.correo}`, '', `Crear mi clave: ${q.enlace}`, '', aviso, '',
    'Si no esperabas este correo, no hagas nada.',
  ].join('\n')
  const html = `<!doctype html><html lang="es"><body style="margin:0;padding:24px;background:#f4f1ea;font-family:Arial,Helvetica,sans-serif;color:#1d1d1b">
<div style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:16px;padding:24px">
<p style="font-size:20px;font-weight:bold;margin:0 0 16px">Kuxtal Travels</p>
<p style="font-size:16px;margin:0 0 12px">Hola, ${esc(q.nombre)}:</p>
<p style="font-size:16px;margin:0 0 12px">${esc(intro)}</p>
<p style="font-size:16px;margin:0 0 20px">Tu usuario: <strong>${esc(q.correo)}</strong></p>
<p style="margin:0 0 20px"><a href="${esc(q.enlace)}" style="display:inline-block;background:#1b365d;color:#ffffff;text-decoration:none;font-weight:bold;font-size:16px;padding:14px 24px;border-radius:999px">Crear mi clave</a></p>
<p style="font-size:14px;margin:0 0 12px;color:#55524d">${esc(aviso)}</p>
<p style="font-size:14px;margin:0;color:#55524d">Si no esperabas este correo, no hagas nada.</p>
</div></body></html>`
  return { asunto, html, texto }
}

type Persona = {
  user_id: string
  correo: string
  nombre: string
  rol: string | null
  rol_nombre: string | null
  nivel: number | null
  activo: boolean
  agente_id: number | null
  jefe_id: number | null
}
type RolInfo = { clave: string, nombre: string, nivel: number | null, es_staff: boolean, activo: boolean }

export const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CLAVE_ROL = /^[a-z0-9_]{1,40}$/

export type Respuesta = { ok: boolean, codigo: string, mensaje: string, [extra: string]: unknown }

export function origenDeLaApp(urlApp: string | undefined): string | null {
  if (urlApp === undefined || urlApp.trim() === '') return null
  try {
    const u = new URL(urlApp.trim())
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null
    return u.origin
  } catch {
    return null
  }
}

/** Llaves viejas (JWT) o nuevas de Supabase (`{ "default": "sb_…" }`). Sin ninguna: vacío y la función se niega. */
export function elegirLlave(legado: string | undefined, nuevasJson: string | undefined): string {
  if (legado !== undefined && legado.trim() !== '') return legado.trim()
  try {
    const nuevas = JSON.parse(nuevasJson ?? '') as Record<string, unknown>
    const una = nuevas.default ?? Object.values(nuevas)[0]
    return typeof una === 'string' ? una : ''
  } catch {
    return ''
  }
}

export function validarAlta(cuerpo: Record<string, unknown>):
  { ok: true, correo: string, nombre: string, rol: string, jefe: number | null } | { ok: false, mensaje: string } {
  const correo = typeof cuerpo.correo === 'string' ? cuerpo.correo.trim().toLowerCase() : ''
  const nombre = typeof cuerpo.nombre === 'string' ? cuerpo.nombre.trim() : ''
  const rol = typeof cuerpo.rol === 'string' ? cuerpo.rol : ''
  const jefe = cuerpo.jefe_id === undefined || cuerpo.jefe_id === null || cuerpo.jefe_id === '' ? null : Number(cuerpo.jefe_id)
  if (!CORREO.test(correo) || correo.length > 254) return { ok: false, mensaje: 'Ese correo no parece un correo. Revisalo.' }
  if (nombre.length === 0 || nombre.length > 120) return { ok: false, mensaje: 'El nombre va de 1 a 120 letras.' }
  if (!CLAVE_ROL.test(rol)) return { ok: false, mensaje: 'Elegí un rol.' }
  if (jefe !== null && (!Number.isInteger(jefe) || jefe <= 0)) return { ok: false, mensaje: 'Ese jefe no existe. Elegilo de la lista.' }
  return { ok: true, correo, nombre, rol, jefe }
}

function codigoDeAuth(datos: Record<string, unknown>): string {
  const c = datos.error_code ?? datos.code
  return typeof c === 'string' ? c : ''
}

/** Los frenos de la base (migración 20260919_bloque1_paso3_personas), en palabras. */
const FRENOS: Record<string, string> = {
  KXP02: 'La cuenta no quedó con el rol que se pidió.',
  KXP03: 'Ese jefe no sirve: no es una persona activa del equipo, o es la misma persona.',
  KXP05: 'Hay más de una persona del equipo sin cuenta con ese correo: no adiviné cuál es. Revisalo en el organigrama.',
  KXP06: 'Esa persona está desactivada: primero se activa y después se le cambia el rol.',
  KXP04: 'Esa persona no existe.',
  '55000': 'Desde el panel no se hace nada sobre tu propia cuenta.',
}

export function crearAtender(cfg: Config): (peticion: Request) => Promise<Response> {
  const ahora = cfg.ahora ?? (() => Date.now())
  const nuevaClave = cfg.generarClave ?? (() => generarClaveTemporal())
  const origen = origenDeLaApp(cfg.urlApp)
  const base = cfg.urlBase.replace(/\/$/, '')

  const cabecerasCors = (): Record<string, string> => ({
    'Access-Control-Allow-Origin': origen ?? 'null',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  })
  // `no-store` en TODAS: una respuesta con una clave temporal no se guarda en ninguna caché.
  const responder = (estado: number, cuerpo: Respuesta): Response =>
    new Response(JSON.stringify(cuerpo), {
      status: estado,
      headers: { ...cabecerasCors(), 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    })
  const error = (estado: number, codigo: string, mensaje: string, extra: Record<string, unknown> = {}) =>
    responder(estado, { ok: false, codigo, mensaje, ...extra })

  // Una llave NUEVA (`sb_secret_…`) no es un JWT: va SOLO en `apikey`. Una VIEJA, también de Bearer.
  const servicio: Record<string, string> = cfg.llaveServicio.startsWith('sb_')
    ? { apikey: cfg.llaveServicio, 'Content-Type': 'application/json' }
    : { apikey: cfg.llaveServicio, Authorization: `Bearer ${cfg.llaveServicio}`, 'Content-Type': 'application/json' }
  const comoQuienLlama = (token: string) => ({
    apikey: cfg.llavePublica, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  })

  async function pedir(url: string, init: RequestInit):
    Promise<{ ok: boolean, estado: number, datos: unknown }> {
    try {
      const r = await cfg.fetch(url, init)
      const texto = await r.text()
      let datos: unknown = null
      try { datos = texto === '' ? null : JSON.parse(texto) } catch { datos = null }
      return { ok: r.ok, estado: r.status, datos }
    } catch {
      return { ok: false, estado: 0, datos: null }
    }
  }
  async function rpc(nombre: string, cabeceras: Record<string, string>, args: Record<string, unknown>):
    Promise<{ ok: true, datos: unknown } | { ok: false, estado: number, codigo: string }> {
    const r = await pedir(`${base}/rest/v1/rpc/${nombre}`, { method: 'POST', headers: cabeceras, body: JSON.stringify(args) })
    if (r.ok) return { ok: true, datos: r.datos }
    const d = r.datos
    const codigo = d !== null && typeof d === 'object' && 'code' in d ? String((d as { code: unknown }).code) : (r.estado === 0 ? 'sin_red' : String(r.estado))
    return { ok: false, estado: r.estado, codigo }
  }
  async function llamarAuth(ruta: string, metodo: string, cuerpo: unknown):
    Promise<{ ok: boolean, estado: number, datos: Record<string, unknown> }> {
    const r = await pedir(`${base}/auth/v1${ruta}`, {
      method: metodo, headers: servicio, body: cuerpo === undefined ? null : JSON.stringify(cuerpo),
    })
    const d = r.datos !== null && typeof r.datos === 'object' ? r.datos as Record<string, unknown> : {}
    return { ok: r.ok, estado: r.estado, datos: d }
  }

  /** El enlace de un solo uso y el correo. `true` si salió. Nunca tira. */
  async function mandarEnlace(persona: { nombre: string, correo: string }, nueva: boolean): Promise<boolean> {
    const correo = cfg.correo
    if (correo === undefined || correo === null || correo.llave === '' || origen === null) return false
    const pedido = await llamarAuth('/admin/generate_link', 'POST', { type: 'recovery', email: persona.correo })
    if (!pedido.ok) return false
    const propiedades = (pedido.datos.properties ?? pedido.datos) as Record<string, unknown>
    const token = propiedades.hashed_token
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{16,256}$/.test(token)) return false
    const enlace = `${origen}/crear-clave.html#t=${token}`
    const { asunto, html, texto } = armarCorreo({ nombre: persona.nombre, correo: persona.correo, enlace, nueva })
    try {
      const r = await cfg.fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${correo.llave}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: correo.remitente, to: [persona.correo], reply_to: correo.responderA, subject: asunto, html, text: texto }),
      })
      await r.text().catch(() => '')
      return r.ok
    } catch {
      return false
    }
  }

  return async function atender(peticion: Request): Promise<Response> {
    try {
      return await atenderAdentro(peticion)
    } catch {
      return error(500, 'inesperado',
        'Algo se rompió en el servidor a mitad de camino. Puede haber quedado a medias: mirá la lista antes de repetir.')
    }
  }

  async function atenderAdentro(peticion: Request): Promise<Response> {
    if (origen === null || base === '' || cfg.llavePublica === '' || cfg.llaveServicio === '') {
      return error(500, 'sin_configurar', 'La función no está configurada (falta la dirección del CRM o las llaves del servidor). No hice nada.')
    }
    if (peticion.method === 'OPTIONS') return new Response(null, { status: 204, headers: cabecerasCors() })
    if (peticion.method !== 'POST') return error(405, 'metodo', 'Solo se aceptan pedidos POST.')

    // ── 1. ¿Quién llama?
    const autorizacion = peticion.headers.get('Authorization') ?? ''
    const token = autorizacion.startsWith('Bearer ') ? autorizacion.slice(7).trim() : ''
    if (token === '' || token === cfg.llavePublica) {
      // `acciones`: lo que ESTA función sabe hacer, para que el despliegue compruebe que contesta la nuestra.
      return error(401, 'sin_sesion', 'Hace falta entrar con tu cuenta para administrar personas.', { acciones: [...ACCIONES] })
    }
    const yo = await pedir(`${base}/auth/v1/user`, { headers: comoQuienLlama(token) })
    if (yo.estado === 0) return error(503, 'sin_red', 'No pude comprobar tu sesión. Probá otra vez.')
    const idQuien = yo.ok && yo.datos !== null && typeof yo.datos === 'object' ? (yo.datos as { id?: unknown }).id : undefined
    if (typeof idQuien !== 'string' || !UUID.test(idQuien)) {
      return error(401, 'sesion_invalida', 'Tu sesión no es válida o venció. Volvé a entrar.')
    }

    // ── 2. ¿Puede? Con SU token: decide la matriz.
    const pregunta = await rpc('funnel_personas_puedo', comoQuienLlama(token), {})
    if (!pregunta.ok || pregunta.datos === null || typeof pregunta.datos !== 'object') {
      return error(503, 'no_pude_verificar', 'No pude comprobar tus permisos. No hice nada.')
    }
    const permiso = pregunta.datos as { puede?: unknown, nivel?: unknown, rol?: unknown }
    if (permiso.puede !== true) return error(403, 'sin_permiso', 'Tu rol no tiene «Gestionar personas» en la pestaña Roles.')
    const soyAdmin = permiso.rol === 'admin'
    const miNivel = typeof permiso.nivel === 'number' ? permiso.nivel : 0

    // ── 3. El pedido.
    let cuerpo: Record<string, unknown>
    try {
      const leido = await peticion.json()
      if (leido === null || typeof leido !== 'object' || Array.isArray(leido)) throw new Error('forma')
      cuerpo = leido as Record<string, unknown>
    } catch {
      return error(400, 'pedido_invalido', 'El pedido no se entiende.')
    }
    const accion = cuerpo.accion
    if (typeof accion !== 'string' || !(ACCIONES as readonly string[]).includes(accion)) {
      return error(400, 'accion_desconocida', 'Esa acción no existe.')
    }

    const listar = async (): Promise<Persona[] | null> => {
      const r = await rpc('funnel_personas_listar', comoQuienLlama(token), {})
      return r.ok && Array.isArray(r.datos) ? r.datos as Persona[] : null
    }
    /** El rol pedido: tiene que existir, estar activo, ser del equipo y (si no sos admin) estar por debajo tuyo. */
    const rolPermitido = async (clave: string): Promise<{ ok: true, rol: RolInfo } | { ok: false, resp: Response }> => {
      const r = await pedir(`${base}/rest/v1/funnel_roles?select=clave,nombre,nivel,es_staff,activo&clave=eq.${encodeURIComponent(clave)}`,
        { headers: comoQuienLlama(token) })
      if (!r.ok || !Array.isArray(r.datos)) return { ok: false, resp: error(503, 'no_pude_leer', 'No pude leer los roles. No hice nada.') }
      const rol = (r.datos as RolInfo[])[0]
      if (rol === undefined || !rol.activo || !rol.es_staff || rol.clave === 'cliente') {
        return { ok: false, resp: error(400, 'rol_invalido', 'Ese rol no existe o no es del equipo. Elegilo de la lista.') }
      }
      if (!soyAdmin && (rol.nivel ?? 0) >= miNivel) {
        return { ok: false, resp: error(403, 'rol_alto', `Solo quien administra puede dar el rol «${rol.nombre}»: es de tu nivel o más alto.`) }
      }
      return { ok: true, rol }
    }
    const frenoDeLaBase = (codigo: string, siNo: string) => FRENOS[codigo] ?? siNo
    /** Quien no es admin solo elige de jefe a alguien de SU equipo (si no, se colgaría gente ajena y vería sus prospectos). */
    const jefePermitido = async (jefe: number | null): Promise<Response | null> => {
      if (jefe === null || soyAdmin) return null
      const r = await rpc('funnel_ve_equipo', comoQuienLlama(token), {})
      if (!r.ok || !Array.isArray(r.datos)) return error(503, 'no_pude_leer', 'No pude revisar tu equipo. No hice nada.')
      const ids = (r.datos as unknown[]).map((x) => Number(x))
      return ids.includes(jefe) ? null : error(403, 'jefe_ajeno', 'Solo podés elegir de jefe a alguien de tu equipo.')
    }
    /** ¿La base anotó el alta? (la bitácora lo dice aunque la persona no tenga agente, p. ej. hostess) */
    const altaAnotada = async (id: string): Promise<boolean | null> => {
      const r = await pedir(`${base}/rest/v1/funnel_personas_bitacora?select=id&accion=eq.alta&persona=eq.${id}`, { headers: comoQuienLlama(token) })
      return r.ok && Array.isArray(r.datos) ? r.datos.length > 0 : null
    }

    // ── ALTA ────────────────────────────────────────────────────────────
    if (accion === 'alta') {
      const v = validarAlta(cuerpo)
      if (!v.ok) return error(400, 'datos_invalidos', v.mensaje)
      const permitido = await rolPermitido(v.rol)
      if (!permitido.ok) return permitido.resp
      const jefeMalo = await jefePermitido(v.jefe)
      if (jefeMalo !== null) return jefeMalo
      const personas = await listar()
      if (personas === null) return error(503, 'no_pude_leer', 'No pude revisar si ese correo ya existe. No creé nada.')
      const repetida = personas.find((p) => (p.correo ?? '').toLowerCase() === v.correo)
      if (repetida !== undefined) {
        return error(409, 'ya_existe', repetida.activo
          ? `Ya hay una persona con ese correo (${repetida.nombre}). Si no puede entrar, usá «Reenviar enlace».`
          : `Ya hay una persona con ese correo (${repetida.nombre}) y está desactivada: activala primero.`)
      }
      const antes = ahora()
      const clave = nuevaClave()
      // Nace confirmada y con su rol: Auth NO manda ningún correo por su cuenta.
      const creacion = await llamarAuth('/admin/users', 'POST', {
        email: v.correo, password: clave, email_confirm: true,
        app_metadata: { role: v.rol }, user_metadata: { nombre: v.nombre },
      })
      if (!creacion.ok) {
        const c = codigoDeAuth(creacion.datos)
        if (c === 'email_exists' || c === 'user_already_exists') {
          return error(409, 'cuenta_existente', 'Ese correo ya tiene una cuenta de acceso que no es del equipo (puede ser de un socio). No creé nada: usá otro correo o revisalo a mano.')
        }
        if (c === 'weak_password') return error(502, 'clave_rechazada', 'Auth rechazó la clave temporal por las reglas del proyecto. No creé nada. Avisá.')
        if (creacion.estado === 429) return error(429, 'demasiados_pedidos', 'Demasiados pedidos seguidos. Esperá un rato y probá otra vez.')
        return error(502, 'auth_fallo', `No pude crear la cuenta (Auth contestó ${creacion.estado}). No quedó nada creado.`)
      }
      const nuevaId = creacion.datos.id
      if (typeof nuevaId !== 'string' || !UUID.test(nuevaId)) {
        return error(502, 'auth_fallo', 'Auth no devolvió la cuenta creada. Revisá la lista antes de volver a dar de alta.')
      }
      const alta = await rpc('funnel_personas_registrar', servicio, {
        p_actor: idQuien, p_persona: nuevaId, p_accion: 'alta', p_nombre: v.nombre, p_rol: v.rol, p_jefe: v.jefe,
        p_cambiar_jefe: v.jefe !== null,
      })
      if (!alta.ok) {
        // La base no la registró. ANTES DE BORRAR SE MIRA (en la bitácora, que vale también para roles sin
        // agente): si sí quedó y se perdió la respuesta, borrar rompería un alta buena.
        const anotada = await altaAnotada(nuevaId)
        if (anotada !== false) {
          return error(500, 'confirmacion_perdida', anotada === null
            ? 'Creé la cuenta, pero no sé si quedó en el equipo y no pude revisarlo. No borré nada: mirá la lista.'
            : 'Creé la cuenta y quedó en el equipo, pero no me llegó la confirmación. Usá «Reenviar enlace» para mandarle su enlace.',
          { codigo_base: alta.codigo })
        }
        const creada = Date.parse(String(creacion.datos.created_at ?? ''))
        const esNueva = Number.isFinite(creada) && creada >= antes - VENTANA_CUENTA_NUEVA_MS
        const motivo = frenoDeLaBase(alta.codigo, 'La base no pudo registrarla.')
        if (esNueva) {
          const borrado = await llamarAuth(`/admin/users/${nuevaId}`, 'DELETE', undefined)
          return error(alta.codigo === 'KXP03' ? 400 : 500, 'alta_incompleta', borrado.ok
            ? `${motivo} Borré la cuenta nueva: no quedó nada, podés probar otra vez.`
            : `${motivo} Y NO pude borrar la cuenta nueva: avisá, hay que limpiarla a mano.`,
          { codigo_base: alta.codigo })
        }
        return error(500, 'alta_incompleta', `${motivo} La cuenta ya existía, así que no la toqué. Avisá.`, { codigo_base: alta.codigo })
      }
      if (await mandarEnlace({ nombre: v.nombre, correo: v.correo }, true)) {
        return responder(200, {
          ok: true, codigo: 'dada_de_alta', accion, user_id: nuevaId, correo_enviado: true,
          mensaje: `Listo: ${v.nombre} (${v.correo}) ya es ${permitido.rol.nombre}. Le mandé un correo con un enlace para crear su clave (vence en ${HORAS_DEL_ENLACE} horas).`,
        })
      }
      return responder(200, {
        ok: true, codigo: 'dada_de_alta', accion, user_id: nuevaId, correo_enviado: false, clave_temporal: clave,
        mensaje: `${v.nombre} (${v.correo}) ya es ${permitido.rol.nombre}, pero NO pude mandarle el correo. Esta es su clave temporal y se muestra UNA sola vez: pasásela en persona o por teléfono.`,
      })
    }

    // ── Las demás actúan sobre alguien que ya existe.
    const idPersona = typeof cuerpo.user_id === 'string' ? cuerpo.user_id : ''
    if (!UUID.test(idPersona)) return error(400, 'datos_invalidos', 'Falta a quién.')
    if (idPersona === idQuien) {
      return error(409, 'a_si_mismo', 'Desde el panel no se hace nada sobre tu propia cuenta: te podrías quedar afuera.')
    }
    const personas = await listar()
    if (personas === null) return error(503, 'no_pude_leer', 'No pude leer la lista de personas. No hice nada.')
    const persona = personas.find((p) => p.user_id === idPersona)
    if (persona === undefined) return error(404, 'no_existe', 'Esa persona no está en el equipo.')
    // Una cuenta SIN rol (o con uno que ya no existe) solo la toca quien administra: no es de nadie todavía.
    if (!soyAdmin && (persona.rol === null || persona.nivel === null)) {
      return error(403, 'sin_rol', `${persona.nombre} no tiene rol en el equipo: solo quien administra decide qué es.`)
    }
    if (!soyAdmin && (persona.nivel ?? 0) >= miNivel) {
      return error(403, 'nivel_alto', `${persona.nombre} es de tu nivel o más alto: solo quien administra puede cambiarle algo.`)
    }

    // ── CAMBIAR EL ROL (y/o el jefe) ──────────────────────────────────────
    if (accion === 'cambiar_rol') {
      const rolNuevo = typeof cuerpo.rol === 'string' ? cuerpo.rol : ''
      const jefe = cuerpo.jefe_id === undefined || cuerpo.jefe_id === null || cuerpo.jefe_id === '' ? null : Number(cuerpo.jefe_id)
      if (jefe !== null && (!Number.isInteger(jefe) || jefe <= 0)) return error(400, 'datos_invalidos', 'Ese jefe no existe. Elegilo de la lista.')
      if (!persona.activo) return error(409, 'de_baja', `${persona.nombre} está desactivada: primero se activa y después se le cambia el rol.`)
      const permitido = await rolPermitido(rolNuevo)
      if (!permitido.ok) return permitido.resp
      const jefeMalo = await jefePermitido(jefe)
      if (jefeMalo !== null) return jefeMalo
      const cambiarJefe = Object.prototype.hasOwnProperty.call(cuerpo, 'jefe_id')
      const rolViejo = persona.rol
      if (rolNuevo !== rolViejo) {
        const cambio = await llamarAuth(`/admin/users/${idPersona}`, 'PUT', { app_metadata: { role: rolNuevo } })
        if (!cambio.ok) return error(502, 'auth_fallo', `No pude cambiarle el rol (Auth contestó ${cambio.estado}). No cambió nada.`)
      }
      const registro = await rpc('funnel_personas_registrar', servicio, {
        p_actor: idQuien, p_persona: idPersona, p_accion: 'cambiar_rol', p_rol: rolNuevo, p_jefe: jefe, p_cambiar_jefe: cambiarJefe,
      })
      if (!registro.ok) {
        // Se le devuelve el rol de antes en Auth: si no, quedaría con un rol nuevo y el equipo viejo.
        const vuelta = rolNuevo === rolViejo ? { ok: true } : await llamarAuth(`/admin/users/${idPersona}`, 'PUT', { app_metadata: { role: rolViejo } })
        const motivo = frenoDeLaBase(registro.codigo, 'La base no pudo registrar el cambio.')
        return error(registro.codigo === 'KXP03' ? 400 : 500, 'rol_sin_cambiar', vuelta.ok
          ? `${motivo} Le dejé el rol de antes: no cambió nada.`
          : `${motivo} OJO: su cuenta quedó con el rol nuevo y no pude devolverle el de antes. Avisá.`,
        { codigo_base: registro.codigo })
      }
      const sesiones = typeof registro.datos === 'number' ? registro.datos : 0
      return responder(200, {
        ok: true, codigo: 'rol_cambiado', accion, user_id: idPersona, rol_nuevo: rolNuevo, sesiones_cerradas: sesiones,
        mensaje: `Listo: ${persona.nombre} ahora es ${permitido.rol.nombre}. Se cerraron sus sesiones: al volver a entrar ve lo de su rol nuevo (si tenía el CRM abierto, lo saca a más tardar en una hora).`,
      })
    }

    // ── REENVIAR ENLACE ───────────────────────────────────────────────────
    // NO TOCA LA CLAVE (revisión adversaria del 18-sep): antes se cambiaba primero y, si el correo
    // fallaba, la clave temporal le quedaba a quien pidió la acción — alguien con el permiso podía
    // quedarse con la cuenta de otro. Ahora solo sale el enlace; su clave de ahora sigue sirviendo
    // hasta que cree la nueva. Para cortarle la entrada está «Desactivar».
    if (accion === 'restablecer') {
      if (!persona.activo) return error(409, 'de_baja', `${persona.nombre} está desactivada. Primero se activa; después se le manda el enlace.`)
      if (cfg.correo === undefined || cfg.correo === null || cfg.correo.llave === '') {
        return error(503, 'sin_correo', 'La función no tiene correo de salida configurado: no puedo mandar enlaces. No cambié nada.')
      }
      if (!await mandarEnlace({ nombre: persona.nombre, correo: persona.correo }, false)) {
        return error(502, 'correo_no_salio', `No pude mandarle el enlace a ${persona.nombre}. No cambié nada: su clave de ahora sigue sirviendo. Probá otra vez en un rato.`)
      }
      const marca = await rpc('funnel_personas_registrar', servicio, { p_actor: idQuien, p_persona: idPersona, p_accion: 'restablecer' })
      return responder(200, {
        ok: true, codigo: 'enlace_enviado', accion, user_id: idPersona, correo_enviado: true,
        mensaje: `Listo: le mandé a ${persona.nombre} un enlace para crear una clave nueva (vence en ${HORAS_DEL_ENLACE} horas). Hasta que la cree, la de ahora sigue sirviendo.`
          + (marca.ok ? '' : ' (No quedó anotado en la bitácora.)'),
      })
    }

    // ── DESACTIVAR / ACTIVAR ──────────────────────────────────────────────
    const activar = accion === 'activar'
    const bloqueo = await llamarAuth(`/admin/users/${idPersona}`, 'PUT', { ban_duration: activar ? 'none' : BANEO })
    if (!bloqueo.ok) {
      return error(502, 'auth_fallo', `No pude ${activar ? 'desbloquearle' : 'bloquearle'} la entrada (Auth contestó ${bloqueo.estado}). No cambié nada.`)
    }
    const cambio = await rpc('funnel_personas_registrar', servicio, { p_actor: idQuien, p_persona: idPersona, p_accion: accion })
    if (!cambio.ok) {
      return error(500, activar ? 'activacion_incompleta' : 'baja_incompleta', activar
        ? `Le desbloqueé la entrada a ${persona.nombre}, pero no pude devolverle su lugar en el equipo. Volvé a intentar «Activar».`
        : `Le bloqueé la entrada a ${persona.nombre}, pero no pude sacarla del equipo ni cerrar sus sesiones. Volvé a intentar «Desactivar».`,
      { codigo_base: cambio.codigo })
    }
    const sesiones = typeof cambio.datos === 'number' ? cambio.datos : 0
    return responder(200, {
      ok: true, codigo: activar ? 'activada' : 'desactivada', accion, user_id: idPersona, sesiones_cerradas: sesiones,
      mensaje: activar
        ? `Listo: ${persona.nombre} puede volver a entrar.`
        : `Listo: ${persona.nombre} ya no puede entrar${sesiones > 0 ? ` y se cerraron sus sesiones abiertas` : ''}.`,
    })
  }
}
