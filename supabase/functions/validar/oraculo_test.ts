// Prueba ADVERSARIA del canje (hallazgo 881a3070, OWASP API6).
// Corre: deno test supabase/functions/validar/oraculo_test.ts
//
// Demuestra que el endpoint YA NO es un oráculo de enumeración:
//   (a) todo estado no canjeable produce EL MISMO cuerpo (byte a byte);
//   (b) el rate-limit por IP corta el barrido;
//   (c) la PII (nombre + tipo) NO sale sin autenticación.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  NO_VALIDO,
  evaluar,
  exito,
  rateLimited,
  clientIp,
  MAX_HITS,
  WINDOW_MS,
  _resetRateLimit,
} from "./logic.ts";

const AHORA = new Date("2026-07-19T12:00:00Z");
const j = (o: unknown) => JSON.stringify(o);

// Un código válido y canjeable, con socio (PII) y oferta.
const codigoValido = () => ({
  id: 42,
  codigo: "ABC123",
  usado: false,
  expira_en: "2027-01-01T00:00:00Z",
  socio_id: 7,
  oferta_id: 3,
  socios: { nombre: "María Jelavianská", tipo_norm: "Premium", vencimiento: "2027-01-01T00:00:00Z" },
  ofertas: { titulo: "2x1 en café", emoji: "☕", descuento: "50%" },
});

// ---------- (a) ORÁCULO CERRADO ----------
Deno.test("(a) todo estado no canjeable devuelve el MISMO cuerpo — nada distingue el motivo", () => {
  const inexistente = evaluar(null, AHORA);
  const usado = evaluar({ ...codigoValido(), usado: true }, AHORA);
  const vencido = evaluar({ ...codigoValido(), expira_en: "2020-01-01T00:00:00Z" }, AHORA);
  const membresiaVencida = evaluar(
    { ...codigoValido(), socios: { ...codigoValido().socios, vencimiento: "2020-01-01T00:00:00Z" } },
    AHORA,
  );

  const cuerpos = [inexistente, usado, vencido, membresiaVencida].map(j);
  // Los cuatro motivos colapsan al mismo string exacto → no hay señal para enumerar.
  for (const cuerpo of cuerpos) assertEquals(cuerpo, j(NO_VALIDO));
  assertEquals(new Set(cuerpos).size, 1, "los estados de falla deben ser INDISTINGUIBLES");
});

Deno.test("(a) el cuerpo genérico no filtra estado, fecha de uso ni existencia", () => {
  const s = j(NO_VALIDO);
  for (const fuga of ["usado", "vencido", "invalido", "membresia", "cupos", "usado_en", "expira", "detalle"]) {
    assert(!s.includes(fuga), `el cuerpo NO debe contener "${fuga}" — filtra estado`);
  }
  assertEquals(s, j({ ok: false, reason: "no_valido" }));
});

Deno.test("(a) un código canjeable SÍ pasa (no rompimos la función legítima)", () => {
  assertEquals(evaluar(codigoValido(), AHORA).ok, true);
});

// ---------- (c) PII SOLO CON AUTH ----------
Deno.test("(c) sin autenticar: NO devuelve nombre ni tipo (PII)", () => {
  const r = exito(codigoValido(), false) as Record<string, unknown>;
  assertEquals(r.ok, true);
  assert(!("nombre" in r), "no debe incluir nombre sin auth");
  assert(!("tipo" in r), "no debe incluir tipo sin auth");
  // La oferta NO es PII → se puede mostrar.
  assertEquals((r.promo as Record<string, unknown>).titulo, "2x1 en café");
  // El nombre real del socio NO aparece por ningún lado del cuerpo.
  assert(!j(r).includes("Jelavianská"), "el nombre del socio se filtró sin auth");
});

Deno.test("(c) autenticado: SÍ devuelve nombre y tipo", () => {
  const r = exito(codigoValido(), true) as Record<string, unknown>;
  assertEquals(r.nombre, "María Jelavianská");
  assertEquals(r.tipo, "Premium");
});

// ---------- (b) RATE-LIMIT ----------
Deno.test("(b) el rate-limit corta el barrido tras MAX_HITS en la ventana", () => {
  _resetRateLimit();
  const ip = "203.0.113.7";
  let bloqueos = 0;
  for (let i = 0; i < MAX_HITS + 5; i++) if (rateLimited(ip)) bloqueos++;
  assert(bloqueos > 0, "el barrido debe ser bloqueado dentro de la ventana");
  // La hit número MAX_HITS+1 ya cae.
  _resetRateLimit();
  for (let i = 0; i < MAX_HITS; i++) assertEquals(rateLimited(ip), false, `hit ${i + 1} no debe bloquear`);
  assertEquals(rateLimited(ip), true, "el hit que excede MAX_HITS debe bloquear");
});

Deno.test("(b) IPs distintas no se pisan; la ventana se libera con el tiempo", () => {
  _resetRateLimit();
  const t0 = 1_000_000;
  for (let i = 0; i < MAX_HITS; i++) assertEquals(rateLimited("10.0.0.1", t0), false);
  assertEquals(rateLimited("10.0.0.1", t0), true);       // 10.0.0.1 bloqueada
  assertEquals(rateLimited("10.0.0.2", t0), false);      // otra IP, limpia
  // Pasada la ventana, 10.0.0.1 vuelve a poder.
  assertEquals(rateLimited("10.0.0.1", t0 + WINDOW_MS + 1), false);
});

Deno.test("(b) clientIp toma la primera IP de x-forwarded-for", () => {
  const req = new Request("https://x/validar?c=1", { headers: { "x-forwarded-for": "198.51.100.9, 10.0.0.1" } });
  assertEquals(clientIp(req), "198.51.100.9");
  assertEquals(clientIp(new Request("https://x/")), "anon");
});
