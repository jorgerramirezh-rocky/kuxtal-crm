// Kuxtal Club — validación pública: LÓGICA PURA (testeable, sin red ni Deno.serve).
//
// Aquí viven las tres decisiones de seguridad del canje (hallazgo 881a3070,
// OWASP API6 — enumeración/broken object level authorization):
//   (a) ORÁCULO CERRADO: todo estado no canjeable devuelve EXACTAMENTE el mismo
//       cuerpo (NO_VALIDO). Nunca revelamos si un código existe ni su estado
//       (invalido / usado / vencido / membresía vencida / cupos / error) — eso
//       dejaba enumerar códigos válidos.
//   (b) RATE-LIMIT por IP (ventana deslizante en memoria) para frenar el barrido.
//   (c) PII (nombre + tipo del socio) SOLO se entrega a un comercio autenticado;
//       la respuesta anónima jamás la incluye.
//
// index.ts orquesta la red (fetch a PostgREST/GoTrue) y llama a estas funciones.
// oraculo_test.ts las prueba en aislamiento (deno test).

// Cuerpo genérico de falla. Congelado para que nadie lo mute por accidente.
export const NO_VALIDO = Object.freeze({ ok: false as const, reason: "no_valido" as const });
export type NoValido = typeof NO_VALIDO;
export type Exito = { ok: true; promo: unknown; nombre?: string; tipo?: string };

// deno-lint-ignore no-explicit-any
type Row = any;

// (a) Clasificación de estado. Devuelve {ok:true} SOLO si el código es canjeable;
// en cualquier otro caso NO_VALIDO — sin distinguir el motivo (oráculo cerrado).
export function evaluar(c: Row, now: Date = new Date()): { ok: true } | NoValido {
  if (!c) return NO_VALIDO;                                        // inexistente
  if (c.usado) return NO_VALIDO;                                   // ya usado
  if (new Date(c.expira_en) < now) return NO_VALIDO;              // vencido
  const soc = c.socios || {};
  if (soc.vencimiento && new Date(soc.vencimiento) < now) return NO_VALIDO; // membresía vencida
  return { ok: true };
}

// (c) Respuesta de éxito. La PII (nombre + tipo) se agrega SOLO si `autenticado`.
// La oferta (promo) NO es PII: es el beneficio público del comercio.
export function exito(c: Row, autenticado: boolean): Exito {
  const soc = c.socios || {}, of = c.ofertas || {};
  const out: Exito = {
    ok: true,
    promo: of.titulo ? { emoji: of.emoji, titulo: of.titulo, descuento: of.descuento } : null,
  };
  if (autenticado) {
    out.nombre = soc.nombre || "Socio";
    out.tipo = soc.tipo_norm || "Socio";
  }
  return out;
}

// (b) Rate-limit por IP: ventana deslizante en memoria del isolate.
// Best-effort (varios isolates no comparten estado, y un cold start la reinicia),
// pero frena el barrido masivo desde una IP sin tocar esquema ni escribir en la DB.
// Para un tope duro y global, migrar a una tabla `intentos_validar` (follow-up).
// 20 canjes/min por IP: holgado para un comercio ocupado, pero corta el barrido
// (miles de intentos) de raíz. Tunable — subir/bajar según tráfico real.
export const WINDOW_MS = 60_000;
export const MAX_HITS = 20;
const hits = new Map<string, number[]>();

export function rateLimited(ip: string, now: number = Date.now()): boolean {
  const prev = (hits.get(ip) || []).filter((t) => now - t < WINDOW_MS);
  prev.push(now);
  hits.set(ip, prev);
  // Limpieza perezosa: si el mapa crece mucho, soltar IPs sin actividad reciente.
  if (hits.size > 5000) {
    for (const [k, v] of hits) {
      if (!v.some((t) => now - t < WINDOW_MS)) hits.delete(k);
    }
  }
  return prev.length > MAX_HITS;
}

// Solo para tests: reiniciar el contador entre casos.
export function _resetRateLimit(): void {
  hits.clear();
}

// IP del cliente detrás del proxy de Supabase.
export function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for") || "";
  const first = xff.split(",")[0].trim();
  return first || req.headers.get("x-real-ip") || "anon";
}
