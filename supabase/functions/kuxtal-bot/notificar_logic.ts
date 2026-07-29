// Lógica PURA del aviso al cliente cuando el equipo confirma/cancela su reserva
// (HALLAZGO/pendiente 414f85aa). Separada de index.ts (que tiene el fetch a Telegram
// y el cliente de Supabase) para poder probarla sin red — mismo patrón que
// supabase/functions/validar/logic.ts + oraculo_test.ts.

export interface ReservaAviso {
  destino: string | null;
  fecha_viaje: string | null;
  personas: number | null;
  respuesta_socio: string | null;
  notas: string | null;
}

// El RPC funnel_reservar_cliente escribe " chat:<chatId>" al final de `notas`
// (ver supabase/migrations/20260713_bot_ancla_socio.sql). Solo las reservas que
// nacieron por el bot tienen chat que avisar; las creadas desde el CRM (botón
// "Crear reserva") no traen chat:  → no hay a quién avisar por este canal.
export function extraerChatIdReserva(notas: string | null | undefined): string | null {
  const m = String(notas || "").match(/chat:(\S+)/);
  return m ? m[1] : null;
}

// Mensaje para el cliente. SOLO campos ya seguros/cara-al-cliente (los mismos que
// expone la vista funnel_reservas_cliente): nunca `notas` (bloc interno del staff).
export function mensajeAvisoReserva(estado: "confirmada" | "cancelada", r: ReservaAviso): string {
  const destino = r.destino || "tu viaje";
  const detalle = [
    `• Destino: ${destino}`,
    r.fecha_viaje ? `• Fecha: ${r.fecha_viaje}` : null,
    r.personas ? `• Personas: ${r.personas}` : null,
  ].filter(Boolean).join("\n");
  const nota = r.respuesta_socio ? `\n\n${r.respuesta_socio}` : "";
  if (estado === "confirmada") {
    return `✅ ¡Tu reserva a ${destino} fue CONFIRMADA! ✈\n\n${detalle}${nota}\n\nGracias por viajar con Kuxtal — cualquier duda, escribinos por acá.`;
  }
  return `❌ Tu reserva a ${destino} fue CANCELADA.\n\n${detalle}${nota}\n\nSi tenés dudas o querés reprogramar, escribinos por acá. 🙏`;
}

// Estados que disparan aviso al cliente (scope mínimo del pendiente 414f85aa).
export const ESTADOS_AVISABLES = ["confirmada", "cancelada"] as const;
export type EstadoAvisable = typeof ESTADOS_AVISABLES[number];
export function esEstadoAvisable(estado: unknown): estado is EstadoAvisable {
  return estado === "confirmada" || estado === "cancelada";
}
