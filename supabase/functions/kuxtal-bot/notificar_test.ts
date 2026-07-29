// Corre: deno test supabase/functions/kuxtal-bot/notificar_test.ts
// Prueba la lógica del aviso al cliente (pendiente 414f85aa): extracción del chat
// desde `notas` y que el mensaje NUNCA filtre el bloc interno del staff.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  esEstadoAvisable,
  extraerChatIdReserva,
  mensajeAvisoReserva,
  type ReservaAviso,
} from "./notificar_logic.ts";

Deno.test("extraerChatIdReserva: encuentra el chat: al final de notas (formato real del RPC)", () => {
  assertEquals(extraerChatIdReserva("chat:123456789"), "123456789");
  assertEquals(extraerChatIdReserva("algo de nota  chat:987654321"), "987654321");
  assertEquals(extraerChatIdReserva(" chat:sin-fuente"), "sin-fuente");
});

Deno.test("extraerChatIdReserva: null cuando no hay chat (reserva creada desde el CRM)", () => {
  assertEquals(extraerChatIdReserva(null), null);
  assertEquals(extraerChatIdReserva(undefined), null);
  assertEquals(extraerChatIdReserva("nota libre del staff sin marca"), null);
});

const RESERVA: ReservaAviso = {
  destino: "Roatán",
  fecha_viaje: "2026-08-15",
  personas: 2,
  respuesta_socio: "Ya coordinamos el hotel, te llamamos mañana.",
  notas: "info interna: cliente difícil, ya llamó 3 veces chat:123",
};

Deno.test("mensajeAvisoReserva: NUNCA incluye el contenido de `notas` (bloc interno)", () => {
  const conf = mensajeAvisoReserva("confirmada", RESERVA);
  const canc = mensajeAvisoReserva("cancelada", RESERVA);
  for (const msg of [conf, canc]) {
    assert(!msg.includes("cliente difícil"), "el aviso no debe filtrar notas internas");
    assert(!msg.includes("ya llamó 3 veces"), "el aviso no debe filtrar notas internas");
  }
});

Deno.test("mensajeAvisoReserva: SÍ incluye destino/fecha/personas y la respuesta_socio (cara al cliente)", () => {
  const msg = mensajeAvisoReserva("confirmada", RESERVA);
  assert(msg.includes("Roatán"));
  assert(msg.includes("2026-08-15"));
  assert(msg.includes("2"));
  assert(msg.includes("Ya coordinamos el hotel"));
  assert(msg.includes("CONFIRMADA"));
});

Deno.test("mensajeAvisoReserva: cancelada dice CANCELADA, no CONFIRMADA", () => {
  const msg = mensajeAvisoReserva("cancelada", RESERVA);
  assert(msg.includes("CANCELADA"));
  assert(!msg.includes("CONFIRMADA"));
});

Deno.test("mensajeAvisoReserva: sin respuesta_socio no rompe (nota vacía)", () => {
  const sinNota: ReservaAviso = { ...RESERVA, respuesta_socio: null };
  const msg = mensajeAvisoReserva("confirmada", sinNota);
  assert(msg.includes("Roatán"));
});

Deno.test("esEstadoAvisable: solo confirmada/cancelada avisan (scope mínimo del pendiente)", () => {
  assertEquals(esEstadoAvisable("confirmada"), true);
  assertEquals(esEstadoAvisable("cancelada"), true);
  for (const otro of ["solicitada", "cotizada", "pagada", "viajó", "", null, undefined, 42]) {
    assertEquals(esEstadoAvisable(otro), false, `"${otro}" no debe ser avisable`);
  }
});
