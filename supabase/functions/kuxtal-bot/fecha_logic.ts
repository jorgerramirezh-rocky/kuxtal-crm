// kuxtal-bot — LÓGICA PURA de fechas (testeable, sin red ni Deno.serve).
//
// Kuxtal opera en Guatemala (UTC-6) y `socios.vencimiento` es una FECHA de
// calendario (AAAA-MM-DD), no un instante. Medir "hoy" con Date.UTC() hacía que,
// a partir de las 6 de la tarde hora de Guatemala, el bot ya creyera que era el
// día siguiente: a un socio cuya membresía vence HOY le respondía
// "🔴 VENCIDA hace 1 día(s)" esa misma noche, y le corría un día todos los avisos
// de "vence pronto". Acá el día se calcula SIEMPRE en la hora del país.
//
// fecha_test.ts lo prueba en aislamiento (deno test).
export const TZ_GT = "America/Guatemala";

// Fecha de calendario (AAAA-MM-DD) del instante `now` en Guatemala.
export function fechaGT(now: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ_GT,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

// Días enteros entre hoy (en Guatemala) y una fecha de calendario.
// 0 = vence hoy · negativo = ya venció · positivo = le quedan días.
export function diasHasta(fecha: string, now: Date = new Date()): number {
  const d = Date.parse(fecha + "T00:00:00Z");
  const hoy = Date.parse(fechaGT(now) + "T00:00:00Z");
  return Math.round((d - hoy) / 86400000);
}

// Traduce la fecha de vencimiento a un estado humano (vigente / por vencer / vencida).
export function estadoMembresia(venc: string | null, now: Date = new Date()) {
  if (!venc) return { emoji: "⚠️", txt: "sin fecha de vencimiento registrada" };
  const dia = String(venc).slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dia) || isNaN(Date.parse(dia + "T00:00:00Z"))) {
    return { emoji: "⚠️", txt: `vencimiento no reconocido (${venc})` };
  }
  const dias = diasHasta(dia, now);
  if (dias < 0) return { emoji: "🔴", txt: `VENCIDA hace ${-dias} día(s) — venció el ${dia}` };
  if (dias === 0) return { emoji: "🟡", txt: `vigente, vence HOY (${dia})` };
  if (dias <= 30) return { emoji: "🟡", txt: `vigente pero vence pronto: en ${dias} día(s) (el ${dia})` };
  return { emoji: "🟢", txt: `vigente hasta el ${dia}` };
}
