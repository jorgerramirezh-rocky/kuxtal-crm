-- ─────────────────────────────────────────────────────────────────────────────
-- Reservas · Avisar al cliente al CONFIRMAR o CANCELAR  (2026-07-20)
-- Pendiente de George (feedback_lola 414f85aa).
--
-- SIN APLICAR AUTOMÁTICAMENTE. Lo revisa y lo corre un humano (George/Lola) aparte,
-- igual que las otras migraciones del repo:
--   source ~/.espiga-secrets.sh && curl -s -X POST \
--     "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260720_reservas_avisar_cliente.sql').read()}))")
--
-- POR QUÉ EXISTE
--   Hoy cuando el equipo confirma o cancela una reserva (campo `estado` en el
--   fólder del viaje, app.html → guardarExp()), el cliente no se entera por
--   ningún canal — tiene que volver a escribirle al bot para saber. El pendiente
--   pide avisarle automático por el bot de Telegram del cliente (@KuxtalBot,
--   supabase/functions/kuxtal-bot), que ya existe y ya tiene el KUXTAL_BOT_TOKEN.
--
-- QUÉ HACE
--   Un trigger AFTER UPDATE en funnel_reservas detecta la transición de `estado`
--   a 'confirmada' o 'cancelada' (scope mínimo del pendiente — no avisa en
--   'cotizada'/'pagada'/'viajó') y dispara — vía pg_net, ASÍNCRONO, sin bloquear
--   ni poder romper el UPDATE del staff — una llamada a la función kuxtal-bot
--   (?notificar=1) que ya sabe extraer el chat de `notas` (formato "chat:<id>",
--   escrito por el RPC funnel_reservar_cliente) y mandar el aviso por Telegram
--   con los mismos campos que ya son cara-al-cliente (destino/fecha/personas/
--   respuesta_socio) — NUNCA `notas` completo, que es el bloc interno del staff.
--
--   Reservas que NO nacieron del bot (creadas desde el botón "Crear reserva" del
--   CRM) no tienen "chat:" en `notas` → el endpoint las detecta y no avisa nada
--   (no hay a quién escribirle por este canal); no es un error, es best-effort.
--
-- REQUIERE (setup manual de George, UNA vez, fuera de esta migración):
--   1. Un secreto NUEVO y propio para este canal interno (Postgres → Edge
--      Function) — no reutilizar KUXTAL_WEBHOOK_SECRET (ese es de Telegram→bot):
--        select vault.create_secret('<valor-aleatorio-largo>', 'kuxtal_notify_secret');
--      (si ya existe, usar vault.update_secret en vez de create_secret).
--   2. El MISMO valor como env var KUXTAL_NOTIFY_SECRET del proyecto Kuxtal:
--        supabase secrets set KUXTAL_NOTIFY_SECRET=<el-mismo-valor> --project-ref tevzfdiumfekvapamovw
--   3. Desplegar la función con el código nuevo (yo NO despliego):
--        supabase functions deploy kuxtal-bot --project-ref tevzfdiumfekvapamovw --no-verify-jwt
--   Sin el secreto en el vault, el trigger no encuentra con qué autenticarse y
--   NO llama a nada (falla silenciosa a propósito — ver el bloque de abajo);
--   sin el mismo secreto en la Function, esta responde 403 (falla CERRADA, ver
--   el comentario de NOTIFY_SECRET en index.ts: a diferencia del webhook de
--   Telegram, este candado nunca arranca abierto).
--
-- NO toca RLS ni el schema de negocio: solo agrega el trigger + su función +
-- la extensión pg_net (estándar de Supabase para HTTP async desde Postgres).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- pg_net: extensión oficial de Supabase para llamadas HTTP async desde triggers
-- (no bloquea la transacción; la respuesta queda en net._http_response si hace
-- falta auditarla). Vive en su propio schema `net` (fijo, así lo instala
-- Supabase independiente del schema que se pida). Ya viene habilitada en la
-- mayoría de proyectos Supabase; el IF NOT EXISTS la deja no-op si ya está.
create extension if not exists pg_net;

create or replace function public.funnel_reservas_avisar_cliente()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'net', 'vault'
as $function$
declare
  v_secret text;
begin
  -- El secreto vive en Supabase Vault (nunca en el código ni en esta migración).
  -- Si todavía no lo creó George (setup manual, ver cabecera), no hay con qué
  -- autenticarse contra la Function → salimos silenciosos (best-effort, jamás
  -- rompemos el UPDATE del staff por falta de un secreto de un canal secundario).
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'kuxtal_notify_secret' limit 1;
  if v_secret is null then
    return new;
  end if;

  perform net.http_post(
    url := 'https://tevzfdiumfekvapamovw.supabase.co/functions/v1/kuxtal-bot?notificar=1',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    body := jsonb_build_object('id', new.id, 'estado', new.estado)
  );
  return new;
-- Cualquier error de red/DNS/lo-que-sea NUNCA debe tumbar el UPDATE de la
-- reserva que hace el staff: lo tragamos acá (best-effort real), no en el
-- llamador. El endpoint del otro lado ya es 200-siempre por el mismo motivo.
exception when others then
  raise warning 'funnel_reservas_avisar_cliente: % (reserva %)', sqlerrm, new.id;
  return new;
end;
$function$;

comment on function public.funnel_reservas_avisar_cliente is
  'Avisa al cliente por el bot de Telegram (kuxtal-bot ?notificar=1) cuando el equipo confirma o cancela su reserva. Best-effort: nunca revierte ni bloquea el UPDATE. Pendiente 414f85aa.';

drop trigger if exists trg_funnel_reservas_avisar_cliente on public.funnel_reservas;
create trigger trg_funnel_reservas_avisar_cliente
  after update of estado on public.funnel_reservas
  for each row
  when (new.estado is distinct from old.estado and new.estado in ('confirmada', 'cancelada'))
  execute function public.funnel_reservas_avisar_cliente();

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN sugerida DESPUÉS de aplicar + del setup manual (secreto + deploy):
--   -- (a) Confirmar una reserva de PRUEBA que tenga "chat:<id>" en notas (usar el
--   --     chat_id de un chat de prueba propio, NUNCA el de un cliente real):
--   UPDATE public.funnel_reservas SET estado='confirmada' WHERE id=<id_de_prueba>;
--   --     → debe llegar el mensaje "✅ ¡Tu reserva ... fue CONFIRMADA!" a ese chat.
--   -- (b) Cancelar la misma reserva de prueba:
--   UPDATE public.funnel_reservas SET estado='cancelada' WHERE id=<id_de_prueba>;
--   --     → debe llegar "❌ Tu reserva ... fue CANCELADA."
--   -- (c) Reintroducir el defecto: guardar el fólder SIN cambiar `estado` (ej.
--   --     solo tocar destino) NO debe disparar ningún mensaje (el WHEN exige
--   --     `is distinct from` + estado in (...) — si dispara con esto, el guard
--   --     del trigger está roto).
--   -- (d) Una reserva SIN "chat:" en notas (creada desde "Crear reserva" del CRM)
--   --     al confirmarse/cancelarse NO debe fallar el UPDATE ni mandar nada raro
--   --     (el endpoint la detecta sin chat y responde 200 sin avisar).
--   -- (e) Confirmar que sin el secreto en vault (antes del setup de George) el
--   --     UPDATE de estado sigue funcionando normal (el trigger sale silencioso).
-- ─────────────────────────────────────────────────────────────────────────────
