// Kuxtal Club — validación pública (API JSON + CORS). La UI la pinta validar.html.
//
// FUENTE DE VERDAD: este archivo en kuxtal-crm main. La copia local en
// ~/kuxtal-edge/supabase/functions/validar se sincroniza DESDE acá (mismo
// esquema que kuxtal-bot). Vive en el proyecto Supabase de KUXTAL
// (tevzfdiumfekvapamovw).
//
// Deploy (yo NO despliego — lo hace George):
//   supabase functions deploy validar --project-ref tevzfdiumfekvapamovw --no-verify-jwt
//
// --- Endurecimiento anti-enumeración (hallazgo 881a3070, OWASP API6) ---
// Antes, este endpoint era un ORÁCULO: devolvía razones distintas por estado
// (invalido/usado/vencido/membresia_vencida/cupos_agotados/ya_usado) + la fecha
// de uso, y entregaba PII (nombre + tipo del socio) a CUALQUIERA con un código
// válido, sin auth ni rate-limit. Eso permitía barrer códigos y cosechar nombres.
// Ahora:
//   (a) todo estado no canjeable responde IGUAL: {ok:false, reason:"no_valido"}
//       (ver logic.ts / NO_VALIDO). Nada de fechas ni motivos.
//   (b) rate-limit por IP en la función (logic.ts / rateLimited) → 429 genérico.
//   (c) el nombre y el tipo del socio (PII) SOLO se devuelven a un comercio
//       autenticado (Bearer de un usuario real de Supabase). La respuesta anónima
//       confirma el beneficio y muestra la oferta, pero NO la PII.
// El canje sigue verificando el insert en `usos` (trigger de cupos): si falla,
// LIBERA el código (usado=false) y responde no_valido igual que el resto.
import {
  NO_VALIDO,
  evaluar,
  exito,
  rateLimited,
  clientIp,
} from "./logic.ts";

const SB = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY") || "";
const H = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET,OPTIONS" };
const J = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS } });

// (c) ¿La petición trae credencial de un comercio autenticado?
// Un Bearer que sea el anon key NO cuenta (validar.html no manda ninguno; el anon
// key es público). Validamos el token contra GoTrue: solo un usuario real habilita PII.
async function comercioAutenticado(req: Request): Promise<boolean> {
  const auth = req.headers.get("authorization") || "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  if (!m) return false;
  const tok = m[1].trim();
  if (!tok || tok === ANON || tok === KEY) return false; // ni anon ni service-role = "usuario"
  try {
    const r = await fetch(`${SB}/auth/v1/user`, { headers: { apikey: KEY, Authorization: "Bearer " + tok } });
    if (!r.ok) return false;
    const u = await r.json();
    return !!(u && u.id);
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  // (b) rate-limit por IP — antes de tocar la DB.
  if (rateLimited(clientIp(req))) return J(NO_VALIDO, 429);

  const code = new URL(req.url).searchParams.get("c") || "";
  if (!code) return J({ ok: false, reason: "falta" });
  try {
    const r = await fetch(`${SB}/rest/v1/codigos?codigo=eq.${encodeURIComponent(code)}&select=*,socios(nombre,tipo_norm,vencimiento),ofertas(titulo,emoji,descuento)`, { headers: H });
    const d = await r.json();
    const c = Array.isArray(d) ? d[0] : null;

    // (a) Oráculo cerrado: inexistente/usado/vencido/membresía vencida → mismo cuerpo.
    if (!evaluar(c, new Date()).ok) return J(NO_VALIDO);

    // Canje atómico (CAS): solo si sigue sin usar.
    const pr = await fetch(`${SB}/rest/v1/codigos?id=eq.${c.id}&usado=eq.false`, { method: "PATCH", headers: { ...H, Prefer: "return=representation" }, body: JSON.stringify({ usado: true, usado_en: new Date().toISOString(), usado_por: "comercio" }) });
    const upd = await pr.json();
    if (!Array.isArray(upd) || !upd.length) return J(NO_VALIDO); // ya lo tomó otra petición

    const ur = await fetch(`${SB}/rest/v1/usos`, { method: "POST", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ socio_id: c.socio_id, oferta_id: c.oferta_id, tipo: "descuento", codigo: code, usuario: "comercio" }) });
    if (!ur.ok) {
      // El trigger de la base rechazó el canje (cupos agotados / cupón ya usado):
      // el canje NO ocurrió → liberar el código para que no quede consumido en falso.
      // El motivo se ABSORBE en no_valido (no revelar por qué falló).
      await fetch(`${SB}/rest/v1/codigos?id=eq.${c.id}`, { method: "PATCH", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ usado: false, usado_en: null, usado_por: null }) });
      return J(NO_VALIDO);
    }

    const of = c.ofertas || {};
    await fetch(`${SB}/rest/v1/interacciones`, { method: "POST", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ socio_id: c.socio_id, tipo: "uso", nota: "Usó beneficio en comercio" + (of.titulo ? ": " + of.titulo : "") + " (" + code + ")", usuario: "comercio" }) });

    // (c) PII solo para comercio autenticado; anónimo recibe confirmación + oferta.
    const auth = await comercioAutenticado(req);
    return J(exito(c, auth));
  } catch (_e) {
    return J(NO_VALIDO);
  }
});
