// ✈ kuxtal-bot — Bot de reservas del CLIENTE de Kuxtal (Telegram).
// Máquina de estados simple: un paso por turno. El estado vive por chat_id en la
// tabla kuxtal_bot_sesiones. Al confirmar, llama al RPC funnel_reservar_cliente
// (service role) y responde con el # de reserva.
//
// Vive en el proyecto Supabase de KUXTAL (tevzfdiumfekvapamovw), NO en el de Rocky:
// ahí están el RPC funnel_reservar_cliente y las tablas del CRM. Al desplegar en ese
// proyecto, SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY se inyectan solos apuntando a él.
//
// Deploy (yo NO despliego — lo hace George):
//   supabase functions deploy kuxtal-bot --project-ref tevzfdiumfekvapamovw --no-verify-jwt
//
// Secrets que hace falta setear en el proyecto de Kuxtal:
//   - KUXTAL_BOT_TOKEN         → token del bot de Telegram del cliente (@KuxtalBot).
//       ⚠️ OJO: en el cofre existe KUXTAL_BOT_TEST (bot de pruebas). El token de
//       PRODUCCIÓN del bot del cliente es KUXTAL_BOT_TOKEN y hay que crearlo/setearlo.
//   - KUXTAL_WEBHOOK_SECRET    → (opcional pero recomendado) secreto anti-suplantación.
//       Si está seteado, se registra con Telegram y se exige en cada update.
//   SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los inyecta Supabase automáticamente.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const BOT_TOKEN = Deno.env.get("KUXTAL_BOT_TOKEN");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
// Secreto anti-suplantación (Telegram lo reenvía en el header). Opcional: si está
// vacío, el bot funciona igual (para arrancar rápido) pero AVISA en el log. Con él
// seteado, se hace cumplir (falla cerrado ante header ausente/incorrecto).
const WEBHOOK_SECRET = Deno.env.get("KUXTAL_WEBHOOK_SECRET") || "";
// Setup del webhook: gateado por un secreto SEPARADO, por header (no en la URL).
const SETUP_SECRET = Deno.env.get("KUXTAL_SETUP_SECRET") || "";
if (!BOT_TOKEN) console.warn("⚠️ KUXTAL_BOT_TOKEN vacío: el bot no puede hablar con Telegram hasta setearlo.");
if (!WEBHOOK_SECRET) console.warn("⚠️ KUXTAL_WEBHOOK_SECRET vacío: webhook SIN candado anti-suplantación (seteá el secreto para blindarlo).");
const db = createClient(SUPABASE_URL!, SERVICE_KEY!);
// Nunca filtrar un secreto en un mensaje de error o log.
function scrub(x: unknown) {
  let s = String(x);
  for (const sec of [
    BOT_TOKEN,
    SERVICE_KEY,
    WEBHOOK_SECRET,
    SETUP_SECRET
  ]){
    if (sec) s = s.split(sec).join("***");
  }
  return s;
}
async function reply(chatId: number, text: string) {
  await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      chat_id: chatId,
      text
    })
  });
}
async function leerSesion(chatId: string) {
  const { data } = await db.from("kuxtal_bot_sesiones").select("chat_id, paso, datos").eq("chat_id", chatId).maybeSingle();
  if (data) return {
    chat_id: chatId,
    paso: data.paso || "inicio",
    datos: data.datos || {}
  };
  return {
    chat_id: chatId,
    paso: "inicio",
    datos: {}
  };
}
async function guardarSesion(chatId: string, paso: string, datos: Record<string, unknown>) {
  await db.from("kuxtal_bot_sesiones").upsert({
    chat_id: chatId,
    paso,
    datos,
    updated_at: new Date().toISOString()
  }, {
    onConflict: "chat_id"
  });
}
async function borrarSesion(chatId: string) {
  await db.from("kuxtal_bot_sesiones").delete().eq("chat_id", chatId);
}
// ── Validaciones ─────────────────────────────────────────────────────────────
// Fecha AAAA-MM-DD que además sea una fecha real (rechaza 2026-13-40).
function fechaValida(s: string) {
  const m = (s || "").trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return false;
  const [_, y, mo, d] = m;
  const dt = new Date(`${y}-${mo}-${d}T00:00:00Z`);
  return dt.getUTCFullYear() === Number(y) && dt.getUTCMonth() + 1 === Number(mo) && dt.getUTCDate() === Number(d);
}
const SI_RE = /^(s[ií]|sip|sale|dale|ok|okay|listo|correcto|confirmo|de una|👍|✅)$/i;
const NO_RE = /^(no|nop|nel|cancel[aá]r?|cancelalo|mejor no|❌)$/i;
// ── Motor de reglas (FAQ-first, editable como DATO) ──────────────────────────
// El contenido del bot vive en la tabla kuxtal_bot_reglas: se edita sin deploy.
// Este código solo NORMALIZA el texto del cliente, busca la primera regla activa
// (por prioridad) cuyo disparador matchee, manda su `respuesta` y —si tiene—
// ejecuta su `accion`. Fail-safe: si la lectura falla, el bot NO se rompe.
// Réplica de la función SQL kuxtal_bot_norm(): minúsculas + sin acentos. Se
// mantiene idéntica para que el match del bot y el de la DB coincidan.
function norm(t: string) {
  return (t || "").toLowerCase().replace(/[áàäâ]/g, "a").replace(/[éèëê]/g, "e").replace(/[íìïî]/g, "i").replace(/[óòöô]/g, "o").replace(/[úùüû]/g, "u").replace(/ñ/g, "n").replace(/ç/g, "c").trim();
}
// Busca la PRIMERA regla activa (orden por prioridad) cuyo disparador esté
// contenido en el texto normalizado. Si ninguna matchea, devuelve la regla
// tipo='fallback'. Lanza si la lectura de la DB falla (lo maneja el llamador).
async function buscarRegla(texto: string) {
  const n = norm(texto);
  const { data, error } = await db.from("kuxtal_bot_reglas").select("id, tipo, disparadores, respuesta, accion, prioridad").eq("activo", true).order("prioridad", {
    ascending: true
  }).order("id", {
    ascending: true
  });
  if (error) throw error;
  const reglas = data || [];
  let fallback = null;
  for (const r of reglas){
    if (r.tipo === "fallback") {
      if (!fallback) fallback = r;
      continue;
    }
    for (const d of r.disparadores || []){
      const dn = norm(String(d));
      if (dn && n.includes(dn)) return r;
    }
  }
  return fallback;
}
// Registra/actualiza la conversación (captación + seguimiento en el CRM). Sin
// ON CONFLICT porque chat_id NO tiene índice único todavía: leo y luego escribo.
// Nunca rompe el flujo del cliente si la DB falla (best-effort).
async function registrarConversacion(chatId: string, contacto: string) {
  try {
    const { data } = await db.from("kuxtal_bot_conversaciones").select("id").eq("chat_id", chatId).order("id", {
      ascending: true
    }).limit(1).maybeSingle();
    const ahora = new Date().toISOString();
    if (data && data.id) {
      await db.from("kuxtal_bot_conversaciones").update({
        ultima_actividad: ahora,
        ...contacto ? {
          contacto
        } : {}
      }).eq("id", data.id);
      return data.id;
    }
    const { data: ins } = await db.from("kuxtal_bot_conversaciones").insert({
      chat_id: chatId,
      canal: "telegram",
      contacto: contacto || null,
      estado: "abierta",
      ultima_actividad: ahora
    }).select("id").maybeSingle();
    return ins ? ins.id : null;
  } catch (e) {
    console.error("registrarConversacion:", scrub(e));
    return null;
  }
}
// Handoff a humano: crea un lead (origen='bot') + una interacción para que el
// equipo lo vea en el CRM, y marca la conversación en curso. Best-effort.
async function escalarHumano(chatId: string, contacto: string, texto: string, convId: number | null) {
  try {
    const { data: lead } = await db.from("leads").insert({
      nombre: contacto || "Cliente Telegram " + chatId,
      origen: "bot",
      estado: "nuevo",
      nota: "Escalado a humano por el bot (Telegram chat " + chatId + "). Mensaje: " + texto
    }).select("id").maybeSingle();
    const leadId = lead ? lead.id : null;
    await db.from("interacciones").insert({
      socio_id: null,
      tipo: "bot",
      usuario: "bot",
      nota: "Handoff a humano desde el bot. Contacto: " + (contacto || "?") + ". Texto: " + texto
    });
    if (convId) {
      await db.from("kuxtal_bot_conversaciones").update({
        estado: "en_curso",
        lead_id: leadId,
        tags: [
          "lead nuevo",
          "handoff"
        ]
      }).eq("id", convId);
    }
    return leadId;
  } catch (e) {
    console.error("escalarHumano:", scrub(e));
    return null;
  }
}
// Responder por reglas: núcleo del motor. Fail-safe con mensaje neutro.
async function responderPorReglas(chatId: string, chatIdNum: number, texto: string, contacto: string, convId: number | null) {
  let regla = null;
  try {
    regla = await buscarRegla(texto);
  } catch (e) {
    console.error("buscarRegla falló (fail-safe):", scrub(e));
    await reply(chatIdNum, "Gracias por escribir a Kuxtal ✈. En un momento te atiende una persona del equipo.");
    return;
  }
  if (!regla) {
    await reply(chatIdNum, "Gracias por escribir a Kuxtal ✈. En un momento te atiende una persona del equipo.");
    return;
  }
  if (regla.respuesta) await reply(chatIdNum, regla.respuesta);
  switch(regla.accion){
    case "iniciar_reserva":
      {
        // Arranca el wizard de reservas que YA existe (intacto).
        await guardarSesion(chatId, "nombre", {});
        await reply(chatIdNum, "Para empezar, ¿a nombre de quién va la reserva? (nombre del socio) ✈");
        break;
      }
    case "escalar_humano":
      {
        await escalarHumano(chatId, contacto, texto, convId);
        break;
      }
    case "validar_codigo":
      {
        break;
      }
    default:
      break;
  }
}
// ── Máquina de estados: un paso por turno ────────────────────────────────────
async function manejar(chatId: string, chatIdNum: number, texto: string, contacto: string) {
  const t = (texto || "").trim();
  const tl = t.toLowerCase();
  // Comandos globales: reiniciar / cancelar en cualquier punto.
  if (tl === "/cancelar" || tl === "/salir") {
    await borrarSesion(chatId);
    await reply(chatIdNum, "Listo, cancelé lo que teníamos en curso. Cuando quieras seguimos. ✈");
    return;
  }
  const s = await leerSesion(chatId);
  // Captación/seguimiento: toda conversación queda registrada en el CRM.
  const convId = await registrarConversacion(chatId, contacto);
  // El wizard de reservas manda SOLO cuando hay una reserva en curso.
  const PASOS_WIZARD = [
    "nombre",
    "destino",
    "fecha",
    "personas",
    "confirmar"
  ];
  const wizardActivo = PASOS_WIZARD.includes(s.paso);
  // /start reinicia limpio y saluda por reglas (ya NO fuerza el wizard).
  if (tl === "/start") {
    await borrarSesion(chatId);
    await responderPorReglas(chatId, chatIdNum, "hola", contacto, convId);
    return;
  }
  // Sin reserva en curso → motor de reglas (FAQ-first, editable como dato).
  if (!wizardActivo) {
    await responderPorReglas(chatId, chatIdNum, t, contacto, convId);
    return;
  }
  // Reserva en curso → seguí el wizard existente, sin interrumpir con reglas.
  switch(s.paso){
    case "nombre":
      {
        if (t.length < 2 || t.length > 80) {
          await reply(chatIdNum, "Decime el nombre completo del socio (hasta 80 letras), porfa. 🙏");
          return;
        }
        s.datos.socio = t;
        await guardarSesion(chatId, "destino", s.datos);
        await reply(chatIdNum, `Un gusto, ${t}. ✈\n¿A qué destino querés viajar?`);
        return;
      }
    case "destino":
      {
        if (t.length < 2 || t.length > 80) {
          await reply(chatIdNum, "¿Cuál es el destino? Escribime el nombre del lugar (hasta 80 letras). 🌎");
          return;
        }
        s.datos.destino = t;
        await guardarSesion(chatId, "fecha", s.datos);
        await reply(chatIdNum, `¡${t}, qué buen plan! 🗺️\n¿Para qué fecha? Escribila así: AAAA-MM-DD (ej: 2026-08-15).`);
        return;
      }
    case "fecha":
      {
        if (!fechaValida(t)) {
          await reply(chatIdNum, "Esa fecha no la entendí. Escribila con el formato AAAA-MM-DD (ej: 2026-08-15). 📅");
          return;
        }
        s.datos.fecha = t;
        await guardarSesion(chatId, "personas", s.datos);
        await reply(chatIdNum, "Perfecto. 📅\n¿Para cuántas personas? (solo el número)");
        return;
      }
    case "personas":
      {
        const n = parseInt(t.replace(/\D+/g, ""), 10);
        if (!Number.isInteger(n) || n < 1 || n > 100) {
          await reply(chatIdNum, "Decime cuántas personas van, con un número (ej: 2). 👥");
          return;
        }
        s.datos.personas = n;
        await guardarSesion(chatId, "confirmar", s.datos);
        await reply(chatIdNum, "Reviso tu reserva antes de apartarla ✈\n\n" + `• Socio: ${s.datos.socio}\n` + `• Destino: ${s.datos.destino}\n` + `• Fecha: ${s.datos.fecha}\n` + `• Personas: ${s.datos.personas}\n\n` + "¿Confirmo? (sí / no)");
        return;
      }
    case "confirmar":
      {
        if (NO_RE.test(tl)) {
          await borrarSesion(chatId);
          await reply(chatIdNum, "Sin problema, no aparté nada. Cuando quieras empezamos de nuevo con /start. ✈");
          return;
        }
        if (!SI_RE.test(tl)) {
          await reply(chatIdNum, "¿Confirmo la reserva? Respondeme «sí» para apartarla o «no» para cancelar. 🙏");
          return;
        }
        // Confirmado → llamar al RPC con service role.
        try {
          const { data, error } = await db.rpc("funnel_reservar_cliente", {
            p_socio: String(s.datos.socio || ""),
            p_destino: String(s.datos.destino || ""),
            p_fecha: String(s.datos.fecha || ""),
            p_personas: Number(s.datos.personas || 1),
            p_notas: null,
            p_prospecto: null,
            p_fuente: chatId
          });
          if (error && String(error.message || "").includes("limite")) {
            await reply(chatIdNum, "Ya hiciste varias reservas hoy ✈. Probá mañana o escribile al equipo de Kuxtal. 🙏");
            return;
          }
          if (error) throw error;
          const idReserva = data; // bigint (id de reserva)
          await borrarSesion(chatId);
          await reply(chatIdNum, `¡Reserva confirmada! ✈🎉\n\n` + `Tu número de reserva es #${idReserva}.\n` + `Guardalo. En breve el equipo de Kuxtal se pone en contacto para los detalles.\n\n` + `Gracias por viajar con nosotros — cada destino, una historia. 🌎`);
        } catch (e) {
          console.error("funnel_reservar_cliente error:", scrub(e));
          // NO borramos la sesión: el cliente puede reintentar el «sí» sin recargar datos.
          await reply(chatIdNum, "Uf, algo se me trabó al apartar la reserva. Reintentá en un momento con «sí», o escribí /cancelar para empezar de nuevo. 🙏");
        }
        return;
      }
    default:
      {
        // Estado desconocido: reiniciar limpio.
        await borrarSesion(chatId);
        await reply(chatIdNum, "Empecemos de nuevo ✈. Escribí /start para apartar tu reserva.");
        return;
      }
  }
}
// ── HTTP ─────────────────────────────────────────────────────────────────────
Deno.serve(async (req)=>{
  try {
    const url = new URL(req.url);
    // 🛠️ Setup (una vez): registra el secret_token del webhook usando el bot token
    // del runtime. Gateado por SETUP_SECRET en HEADER. ?setup=1 muestra el estado;
    // &apply=1 lo aplica sobre la URL de webhook ya registrada.
    if (url.searchParams.get("setup") === "1") {
      const json = (obj: unknown)=>new Response(JSON.stringify(obj), {
          headers: {
            "content-type": "application/json"
          }
        });
      if (!SETUP_SECRET || req.headers.get("x-setup-secret") !== SETUP_SECRET) {
        return new Response("no", {
          status: 403
        });
      }
      const info = await (await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo`)).json();
      if (url.searchParams.get("apply") !== "1") return json({
        paso: "revisar",
        webhook: info?.result
      });
      const cur = info?.result || {};
      if (!cur.url) return json({
        error: "no hay URL de webhook registrada; NO aplico para no dejar el bot sordo."
      });
      const body: Record<string, unknown> = {
        url: cur.url,
        secret_token: WEBHOOK_SECRET
      };
      if (Array.isArray(cur.allowed_updates) && cur.allowed_updates.length) body.allowed_updates = cur.allowed_updates;
      const set = await (await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/setWebhook`, {
        method: "POST",
        headers: {
          "content-type": "application/json"
        },
        body: JSON.stringify(body)
      })).json();
      const info2 = await (await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo`)).json();
      return json({
        paso: "aplicado",
        set,
        despues: info2?.result
      });
    }
    // 🔒 Anti-suplantación: si hay secreto configurado, exigirlo (falla cerrado ante
    // header ausente/incorrecto). Si NO hay secreto, dejamos pasar pero avisamos en log
    // (modo arranque). Telegram siempre responde 200, así no reintenta en loop.
    if (WEBHOOK_SECRET && req.headers.get("x-telegram-bot-api-secret-token") !== WEBHOOK_SECRET) {
      console.error("webhook rechazado: header de Telegram ausente o incorrecto (¿falta correr setup tras el deploy?).");
      return new Response("ok");
    }
    const update = await req.json();
    const msg = update.message;
    if (!msg || !msg.chat) return new Response("ok");
    const chatIdNum = Number(msg.chat.id);
    const chatId = String(msg.chat.id);
    const from = msg.from || {};
    const contacto = (String(from.first_name || "") + " " + String(from.last_name || "")).trim() || (from.username ? "@" + String(from.username) : "");
    const texto = typeof msg.text === "string" ? msg.text : "";
    if (!texto) {
      // El bot solo maneja texto (no voz ni adjuntos) en este flujo.
      await reply(chatIdNum, "Por ahora te entiendo por texto ✈. Escribime tu consulta (membresía, destinos, reservas o descuentos) y con gusto te ayudo.");
      return new Response("ok");
    }
    // 🎯 F2 Kaizen (08-jul): todo el que le escribe al bot queda como lead en el CRM.
    // Fire-and-forget: sin await ni throw — registrar JAMÁS rompe la conversación.
    db.from("leads").upsert({
      chat_id: chatId,
      nombre: contacto || "(sin nombre)",
      origen: "bot",
      estado: "nuevo",
      nota: "Primer contacto por el bot de Telegram"
    }, {
      onConflict: "chat_id",
      ignoreDuplicates: true
    }).then(({ error })=>{
      if (error) console.warn("lead upsert:", scrub(error.message || error));
    });
    await manejar(chatId, chatIdNum, texto, contacto);
    return new Response("ok");
  } catch (e) {
    console.error("kuxtal-bot error:", scrub(e));
    // 200 para que Telegram no reintente en loop.
    return new Response("ok");
  }
});
