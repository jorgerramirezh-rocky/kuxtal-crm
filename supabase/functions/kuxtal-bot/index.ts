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
import { esEstadoAvisable, extraerChatIdReserva, mensajeAvisoReserva } from "./notificar_logic.ts";
const BOT_TOKEN = Deno.env.get("KUXTAL_BOT_TOKEN");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
// Secreto anti-suplantación (Telegram lo reenvía en el header). Opcional: si está
// vacío, el bot funciona igual (para arrancar rápido) pero AVISA en el log. Con él
// seteado, se hace cumplir (falla cerrado ante header ausente/incorrecto).
const WEBHOOK_SECRET = Deno.env.get("KUXTAL_WEBHOOK_SECRET") || "";
// Setup del webhook: gateado por un secreto SEPARADO, por header (no en la URL).
const SETUP_SECRET = Deno.env.get("KUXTAL_SETUP_SECRET") || "";
// Secreto del trigger interno (Postgres → este endpoint) que avisa al cliente
// cuando el equipo confirma/cancela su reserva (pendiente 414f85aa). A diferencia
// del WEBHOOK_SECRET de Telegram, ESTE candado es SIEMPRE obligatorio (falla
// CERRADO si falta): un abuso acá manda mensajes reales a chats reales de clientes
// suplantando a Kuxtal, no es un simple update de estado de conversación.
const NOTIFY_SECRET = Deno.env.get("KUXTAL_NOTIFY_SECRET") || "";
if (!BOT_TOKEN) console.warn("⚠️ KUXTAL_BOT_TOKEN vacío: el bot no puede hablar con Telegram hasta setearlo.");
if (!WEBHOOK_SECRET) console.warn("⚠️ KUXTAL_WEBHOOK_SECRET vacío: webhook SIN candado anti-suplantación (seteá el secreto para blindarlo).");
if (!NOTIFY_SECRET) console.warn("⚠️ KUXTAL_NOTIFY_SECRET vacío: el aviso de confirmar/cancelar reserva queda DESACTIVADO (falla cerrado a propósito).");
const db = createClient(SUPABASE_URL!, SERVICE_KEY!);
// Nunca filtrar un secreto en un mensaje de error o log.
function scrub(x: unknown) {
  let s = String(x);
  for (const sec of [
    BOT_TOKEN,
    SERVICE_KEY,
    WEBHOOK_SECRET,
    SETUP_SECRET,
    NOTIFY_SECRET
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
// ── Búsqueda de socio — CANDADO DE PRIVACIDAD (12-jul) ───────────────────────
// Solo DPI EXACTO (13 díg.). El número de socio (secuencial 1..~3172) y el nombre
// (apellidos comunes) son ENUMERABLES: permitían sacar el padrón entero → PROHIBIDO.
// Divulgación mínima: solo traemos/mostramos estado de membresía + tipo; NUNCA
// nombre, No. de socio, DPI, copropietario ni notas del CRM (serían datos de
// terceros ante un DPI ajeno). El bot corre con SERVICE_ROLE; el candado es la lógica.
// `id` es solo para ANCLAR la conversación al socio (uso interno); jamás se muestra.
const COLS_SOCIO = "id, tipo, tipo_norm, vencimiento";
// Extrae un DPI (13 dígitos) de un texto libre, si lo hay. Tolerante a espacios,
// puntos y guiones («1234 56789 0123», «1234.5678.90123»): se buscan los 13 dígitos
// sobre el texto SIN esos separadores, manteniendo el candado de DPI exacto.
function extraerDPI(texto: string): string | null {
  const limpio = (texto || "").replace(/[\s.\-]/g, "");
  const m = limpio.match(/(?<!\d)(\d{13})(?!\d)/);
  return m ? m[1] : null;
}
// Traduce la fecha de vencimiento a un estado humano (vigente / por vencer / vencida).
function estadoMembresia(venc: string | null) {
  if (!venc) return { emoji: "⚠️", txt: "sin fecha de vencimiento registrada" };
  const d = new Date(String(venc) + "T00:00:00Z");
  if (isNaN(d.getTime())) return { emoji: "⚠️", txt: `vencimiento no reconocido (${venc})` };
  const hoy = new Date();
  const hoyUTC = Date.UTC(hoy.getUTCFullYear(), hoy.getUTCMonth(), hoy.getUTCDate());
  const dias = Math.round((d.getTime() - hoyUTC) / 86400000);
  if (dias < 0) return { emoji: "🔴", txt: `VENCIDA hace ${-dias} día(s) — venció el ${venc}` };
  if (dias <= 30) return { emoji: "🟡", txt: `vigente pero vence pronto: en ${dias} día(s) (el ${venc})` };
  return { emoji: "🟢", txt: `vigente hasta el ${venc}` };
}
// Ficha MÍNIMA (candado): solo estado de membresía + tipo. Sin nombre, No. de
// socio, DPI ni copropietario — nada que identifique a la persona o a terceros.
function fichaSocioSegura(s: Record<string, unknown>): string {
  const tipo = String((s.tipo_norm || s.tipo || "sin dato"));
  const em = estadoMembresia((s.vencimiento as string) ?? null);
  return `${em.emoji} Membresía ${em.txt}\n• Tipo: ${tipo}`;
}
// CANDADO: reviso membresía SOLO con DPI exacto (13 díg.). No busca por número de
// socio ni por nombre (ambos enumerables). Devuelve mensaje humano; fail-safe.
// Si `convId` viene, ANCLA la conversación al socio encontrado (socio_id) — dato
// interno del CRM, jamás divulgado al chat.
async function buscarSocio(termino: string, convId: number | null = null): Promise<string> {
  const clean = (termino || "").replace(/[\s.\-]/g, "");
  if (!/^\d{13}$/.test(clean)) {
    return "Para cuidar los datos de la comunidad, reviso la membresía solo con el DPI completo (13 dígitos) del titular ✈. Pasame el DPI, o escribime «hablar con una persona» y te paso con el equipo. 🙏";
  }
  try {
    const { data, error } = await db.from("socios").select(COLS_SOCIO).eq("dpi", clean).limit(2);
    if (error) throw error;
    const filas = data || [];
    if (!filas.length) {
      return "No encontré una membresía con ese DPI 🤔. Verificá que estén los 13 dígitos completos, o escribime «hablar con una persona» y te ayudo. ✈";
    }
    // Ancla conversación → socio (best-effort: si la columna aún no existe o la
    // escritura falla, la consulta del cliente sale igual).
    if (convId && filas[0].id) {
      const { error: eAncla } = await db.from("kuxtal_bot_conversaciones").update({
        socio_id: filas[0].id
      }).eq("id", convId);
      if (eAncla) console.warn("ancla socio_id:", scrub(eAncla.message || eAncla));
    }
    // Uno o varios (copropietarios comparten DPI): damos el estado, sin listar personas.
    return `Esto es lo que tengo de esa membresía ✈\n\n${fichaSocioSegura(filas[0])}\n\nEs la info que la comunidad Kuxtal tiene registrada, no un documento oficial. Si algo no cuadra, avisale al equipo. 🙏`;
  } catch (e) {
    console.error("buscarSocio:", scrub(e));
    return "Uf, no pude revisar el registro ahora mismo ✈. Reintentá en un momento, o escribime «hablar con una persona» y te paso con el equipo. 🙏";
  }
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
// 🎯 F2 Kaizen (08-jul) + ancla (13-jul): todo el que le escribe al bot queda como
// lead en el CRM y la conversación queda ANCLADA a ese lead (lead_id) — cierra
// hz_248731fe: antes el upsert de primer contacto no seteaba lead_id nunca.
// Se llama SIN await (fire-and-forget): registrar JAMÁS rompe la conversación.
async function vincularLead(chatId: string, contacto: string, convId: number | null) {
  try {
    const { data: up, error } = await db.from("leads").upsert({
      chat_id: chatId,
      nombre: contacto || "(sin nombre)",
      origen: "bot",
      estado: "nuevo",
      nota: "Primer contacto por el bot de Telegram"
    }, {
      onConflict: "chat_id",
      ignoreDuplicates: true
    }).select("id").maybeSingle();
    if (error) console.warn("lead upsert:", scrub(error.message || error));
    // Con ignoreDuplicates, el upsert no devuelve fila si el lead ya existía:
    // en ese caso lo leemos por chat_id (único) para poder anclar igual.
    let leadId = up ? up.id : null;
    if (!leadId) {
      const { data: ex } = await db.from("leads").select("id").eq("chat_id", chatId).limit(1).maybeSingle();
      leadId = ex ? ex.id : null;
    }
    if (leadId && convId) {
      await db.from("kuxtal_bot_conversaciones").update({
        lead_id: leadId
      }).eq("id", convId).is("lead_id", null);
    }
  } catch (e) {
    console.error("vincularLead:", scrub(e));
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
  // Atajo de alta señal: si el mensaje trae un DPI (13 dígitos), es inequívoco
  // que quiere consultar su membresía → lo resolvemos directo, sin pedir rol a
  // ninguna regla. Funciona aunque todavía no exista la fila de regla en la DB.
  const dpi = extraerDPI(texto);
  if (dpi) {
    await reply(chatIdNum, await buscarSocio(dpi, convId));
    return;
  }
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
    case "buscar_socio":
      {
        // Mini-wizard de 1 paso: pedimos el identificador y lo resolvemos al
        // siguiente turno (consistente con "un paso por turno"). El estado
        // "buscar_socio" está en PASOS_WIZARD, así lo agarra la máquina de estados.
        await guardarSesion(chatId, "buscar_socio", {});
        await reply(chatIdNum, "Con gusto reviso tu membresía ✈. Por privacidad, la reviso solo con el DPI completo (13 dígitos) del titular. Pasámelo, porfa. 🙏");
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
  // Lead de primer contacto + ancla conversación→lead. Fire-and-forget (sin await).
  vincularLead(chatId, contacto, convId);
  // El wizard de reservas manda SOLO cuando hay una reserva en curso.
  const PASOS_WIZARD = [
    "nombre",
    "destino",
    "fecha",
    "personas",
    "confirmar",
    "buscar_socio"
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
    case "buscar_socio":
      {
        // El usuario respondió → buscarSocio exige DPI exacto (candado de privacidad).
        const msg = await buscarSocio(t, convId);
        await borrarSesion(chatId);
        await reply(chatIdNum, msg);
        return;
      }
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
          // Ancla al socio real: si la conversación quedó anclada por DPI, pasamos
          // ese socio_id al RPC. Best-effort: si la columna aún no existe o la
          // lectura falla, la solicitud sale igual (p_socio_id = null).
          let socioId: number | null = null;
          if (convId) {
            const { data: conv, error: eConv } = await db.from("kuxtal_bot_conversaciones").select("socio_id").eq("id", convId).maybeSingle();
            if (eConv) console.warn("leer socio_id de conversación:", scrub(eConv.message || eConv));
            else if (conv && conv.socio_id) socioId = Number(conv.socio_id);
          }
          const { data, error } = await db.rpc("funnel_reservar_cliente", {
            p_socio: String(s.datos.socio || ""),
            p_destino: String(s.datos.destino || ""),
            p_fecha: String(s.datos.fecha || ""),
            p_personas: Number(s.datos.personas || 1),
            p_notas: null,
            p_prospecto: null,
            p_fuente: chatId,
            p_socio_id: socioId
          });
          if (error && String(error.message || "").includes("limite")) {
            await reply(chatIdNum, "Ya hiciste varias reservas hoy ✈. Probá mañana o escribile al equipo de Kuxtal. 🙏");
            return;
          }
          if (error) throw error;
          const idReserva = data; // bigint (id de reserva)
          await borrarSesion(chatId);
          // Es una SOLICITUD (nace 'solicitada' en el CRM): el equipo la confirma
          // después. No prometemos «confirmada» — eso lo decide una persona.
          await reply(chatIdNum, `¡Solicitud de reserva recibida! ✈\n\n` + `Tu número de solicitud es #${idReserva}.\n` + `Guardalo. El equipo de Kuxtal la revisa y se pone en contacto para confirmarla y coordinar los detalles.\n\n` + `Gracias por viajar con nosotros — cada destino, una historia. 🌎`);
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
// ── Aviso al cliente: confirmar/cancelar reserva (pendiente 414f85aa) ────────
// Lo dispara un trigger de Postgres (AFTER UPDATE en funnel_reservas, ver
// supabase/migrations/20260720_reservas_avisar_cliente.sql) vía pg_net cuando el
// equipo cambia `estado` a 'confirmada' o 'cancelada'. Candado SIEMPRE cerrado:
// sin NOTIFY_SECRET configurado, o si no matchea, 403 — a diferencia del webhook
// de Telegram (que arranca abierto a propósito para no dejar el bot sordo), acá
// un abuso manda mensajes reales a chats reales de clientes suplantando a Kuxtal.
async function avisarReserva(req: Request): Promise<Response> {
  if (!NOTIFY_SECRET || req.headers.get("x-notify-secret") !== NOTIFY_SECRET) {
    return new Response("no", {
      status: 403
    });
  }
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch  {
    return new Response("bad request", {
      status: 400
    });
  }
  const id = Number(body.id);
  if (!Number.isInteger(id) || id <= 0) return new Response("bad request", {
    status: 400
  });
  try {
    const { data: r, error } = await db.from("funnel_reservas").select("estado, destino, fecha_viaje, personas, respuesta_socio, notas").eq("id", id).maybeSingle();
    if (error) throw error;
    // Fuente de verdad = la fila AHORA, no lo que mandó el trigger: si volvió a
    // cambiar de estado entre el UPDATE y esta llamada, avisamos lo REAL vigente.
    if (!r || !esEstadoAvisable(r.estado)) return new Response("ok"); // nada que avisar
    const chatId = extraerChatIdReserva(r.notas as string | null);
    const chatIdNum = Number(chatId);
    if (!chatId || !Number.isFinite(chatIdNum)) return new Response("ok"); // reserva sin chat (no vino del bot) — nada que avisar por acá
    await reply(chatIdNum, mensajeAvisoReserva(r.estado, {
      destino: r.destino,
      fecha_viaje: r.fecha_viaje,
      personas: r.personas,
      respuesta_socio: r.respuesta_socio,
      notas: r.notas
    }));
    return new Response("ok");
  } catch (e) {
    console.error("avisarReserva:", scrub(e));
    return new Response("ok"); // 200: best-effort, nunca rompe al trigger que lo llama (fire-and-forget)
  }
}
// ── HTTP ─────────────────────────────────────────────────────────────────────
Deno.serve(async (req)=>{
  try {
    const url = new URL(req.url);
    // ✉️ Aviso de confirmar/cancelar reserva — ver avisarReserva() arriba.
    if (url.searchParams.get("notificar") === "1") {
      return await avisarReserva(req);
    }
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
    // 🎯 El lead de primer contacto + ancla al lead ahora viven en vincularLead()
    // (se dispara dentro de manejar, ya con el id de la conversación a mano).
    await manejar(chatId, chatIdNum, texto, contacto);
    return new Response("ok");
  } catch (e) {
    console.error("kuxtal-bot error:", scrub(e));
    // 200 para que Telegram no reintente en loop.
    return new Response("ok");
  }
});
