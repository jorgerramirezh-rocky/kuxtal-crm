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
// Cambio 14-jul-2026 (junto a la migración 20260714_cupos_trigger.sql): el insert
// en usos ahora SE VERIFICA. Antes, si fallaba (p. ej. el trigger de cupos rechaza
// con CUPOS_AGOTADOS / YA_USADO), la función igual respondía ok:true con el código
// ya consumido: descuento regalado y canje sin registrar. Ahora, si el insert
// falla, se LIBERA el código (usado=false) y se responde
// {ok:false, reason:"cupos_agotados"|"ya_usado"|"error"} — validar.html no conoce
// esos reasons nuevos y cae en su pantalla de error genérica ("No se pudo validar
// / Algo salió mal"), legible sin tocar la UI.
const SB = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET,OPTIONS" };
const J = (o: unknown) => new Response(JSON.stringify(o), { headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const code = new URL(req.url).searchParams.get("c") || "";
  if (!code) return J({ ok: false, reason: "falta" });
  try {
    const r = await fetch(`${SB}/rest/v1/codigos?codigo=eq.${encodeURIComponent(code)}&select=*,socios(nombre,tipo_norm,vencimiento),ofertas(titulo,emoji,descuento)`, { headers: H });
    const d = await r.json();
    const c = Array.isArray(d) ? d[0] : null;
    if (!c) return J({ ok: false, reason: "invalido" });
    if (c.usado) return J({ ok: false, reason: "usado", detalle: c.usado_en });
    if (new Date(c.expira_en) < new Date()) return J({ ok: false, reason: "vencido" });
    const soc = c.socios || {}, of = c.ofertas || {};
    if (soc.vencimiento && new Date(soc.vencimiento) < new Date()) return J({ ok: false, reason: "membresia_vencida" });
    const pr = await fetch(`${SB}/rest/v1/codigos?id=eq.${c.id}&usado=eq.false`, { method: "PATCH", headers: { ...H, Prefer: "return=representation" }, body: JSON.stringify({ usado: true, usado_en: new Date().toISOString(), usado_por: "comercio" }) });
    const upd = await pr.json();
    if (!Array.isArray(upd) || !upd.length) return J({ ok: false, reason: "usado" });
    const ur = await fetch(`${SB}/rest/v1/usos`, { method: "POST", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ socio_id: c.socio_id, oferta_id: c.oferta_id, tipo: "descuento", codigo: code, usuario: "comercio" }) });
    if (!ur.ok) {
      // El trigger de la base rechazó el canje (cupos agotados / cupón ya usado):
      // el canje NO ocurrió → liberar el código para que no quede consumido en falso.
      const msg = await ur.text().catch(() => "");
      await fetch(`${SB}/rest/v1/codigos?id=eq.${c.id}`, { method: "PATCH", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ usado: false, usado_en: null, usado_por: null }) });
      if (msg.includes("CUPOS_AGOTADOS")) return J({ ok: false, reason: "cupos_agotados" });
      if (msg.includes("YA_USADO")) return J({ ok: false, reason: "ya_usado" });
      return J({ ok: false, reason: "error" });
    }
    await fetch(`${SB}/rest/v1/interacciones`, { method: "POST", headers: { ...H, Prefer: "return=minimal" }, body: JSON.stringify({ socio_id: c.socio_id, tipo: "uso", nota: "Usó beneficio en comercio" + (of.titulo ? ": " + of.titulo : "") + " (" + code + ")", usuario: "comercio" }) });
    return J({ ok: true, nombre: soc.nombre || "Socio", tipo: soc.tipo_norm || "Socio", promo: of.titulo ? { emoji: of.emoji, titulo: of.titulo, descuento: of.descuento } : null });
  } catch (e) {
    return J({ ok: false, reason: "error" });
  }
});
