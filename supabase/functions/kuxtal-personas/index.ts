// Kuxtal · Edge Function `kuxtal-personas` — el cableado con Deno (bloque 1, paso 3).
//
// Todo lo que decide vive en `logica.ts` y se prueba sin desplegar (logica_test.ts).
// Acá solo se leen las variables del servidor. La llave de servicio la pone Supabase:
// NO está en el repo ni llega al navegador.
//
// Variables:
//   SUPABASE_URL, SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY (o las nuevas
//     SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS) — las pone Supabase.
//   KUXTAL_URL_APP — la dirección del CRM (https://crm.kuxtal.autofix.solutions). Es el
//     ÚNICO origen al que se le abre CORS y adonde vuelven los enlaces. SIN ELLA NO HACE NADA.
//   KUXTAL_RESEND_KEY — llave de Resend SOLO de envío. Sin ella no manda correos y el alta
//     muestra la clave temporal una vez.
//   KUXTAL_CORREO_REMITENTE — `Kuxtal Travels <kuxtal@autofix.solutions>`.
//   KUXTAL_CORREO_RESPUESTAS — `soporte@autofix.solutions`.
//
// `verify_jwt = false` al desplegar, a propósito: la función valida la sesión ella misma.
// Desplegar es de George: ~/firmas-pr/kuxtal-paso3-desplegar.sh.

import { crearAtender, elegirLlave } from './logica.ts'

const leer = (nombre: string): string | undefined => Deno.env.get(nombre)
const llaveCorreo = (leer('KUXTAL_RESEND_KEY') ?? '').trim()

Deno.serve(crearAtender({
  urlBase: leer('SUPABASE_URL') ?? '',
  llavePublica: elegirLlave(leer('SUPABASE_ANON_KEY'), leer('SUPABASE_PUBLISHABLE_KEYS')),
  llaveServicio: elegirLlave(leer('SUPABASE_SERVICE_ROLE_KEY'), leer('SUPABASE_SECRET_KEYS')),
  urlApp: leer('KUXTAL_URL_APP'),
  fetch: (entrada, opciones) => fetch(entrada, opciones),
  correo: llaveCorreo === '' ? null : {
    llave: llaveCorreo,
    remitente: leer('KUXTAL_CORREO_REMITENTE') ?? 'Kuxtal Travels <kuxtal@autofix.solutions>',
    responderA: leer('KUXTAL_CORREO_RESPUESTAS') ?? 'soporte@autofix.solutions',
  },
}))
