// Corre: deno test supabase/functions/kuxtal-bot/fecha_test.ts
// Prueba que el bot mida el día en la hora de GUATEMALA (UTC-6) y no en UTC.
// Cada caso REPRODUCE el defecto viejo: con Date.UTC(), a las 8 de la noche el bot
// le decía "VENCIDA hace 1 día" a un socio cuya membresía vence HOY.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { diasHasta, estadoMembresia, fechaGT } from "./fecha_logic.ts";

const NOCHE = new Date("2026-08-12T02:00:00Z");   // 11-ago 20:00 en Guatemala
const MANANA = new Date("2026-08-11T16:00:00Z");  // 11-ago 10:00 en Guatemala

Deno.test("fechaGT: a las 8 de la noche en Guatemala TODAVÍA es el mismo día", () => {
  assertEquals(fechaGT(NOCHE), "2026-08-11");
  assertEquals(fechaGT(MANANA), "2026-08-11");
  assertEquals(fechaGT(new Date("2026-08-12T06:00:00Z")), "2026-08-12"); // medianoche GT
});

Deno.test("diasHasta: 0 = vence hoy, aunque sean las 8 de la noche", () => {
  assertEquals(diasHasta("2026-08-11", NOCHE), 0);
  assertEquals(diasHasta("2026-08-11", MANANA), 0);
  assertEquals(diasHasta("2026-08-12", NOCHE), 1);
  assertEquals(diasHasta("2026-08-10", NOCHE), -1);
});

Deno.test("estadoMembresia: la que vence HOY no se anuncia como vencida", () => {
  const hoy = estadoMembresia("2026-08-11", NOCHE);
  assertEquals(hoy.emoji, "🟡");
  assertEquals(hoy.txt.includes("VENCIDA"), false, "una membresía que vence hoy NO está vencida");
  assertEquals(hoy.txt, "vigente, vence HOY (2026-08-11)");
});

Deno.test("estadoMembresia: vigente, por vencer y vencida siguen distinguiéndose", () => {
  assertEquals(estadoMembresia("2026-08-25", NOCHE).emoji, "🟡"); // 14 días
  assertEquals(estadoMembresia("2027-01-01", NOCHE).emoji, "🟢");
  const vencida = estadoMembresia("2026-08-09", NOCHE);
  assertEquals(vencida.emoji, "🔴");
  assertEquals(vencida.txt, "VENCIDA hace 2 día(s) — venció el 2026-08-09");
});

Deno.test("estadoMembresia: dato ausente o sucio se avisa, no se inventa", () => {
  assertEquals(estadoMembresia(null, NOCHE).txt, "sin fecha de vencimiento registrada");
  assertEquals(estadoMembresia("ayer", NOCHE).txt, "vencimiento no reconocido (ayer)");
  // Timestamp completo: se usa el día, no revienta.
  assertEquals(estadoMembresia("2026-08-11T00:00:00Z", NOCHE).txt, "vigente, vence HOY (2026-08-11)");
});
