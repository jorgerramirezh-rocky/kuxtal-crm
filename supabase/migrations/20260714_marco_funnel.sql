-- M1 · MARCO del hilo conductor (embudo) — SIN APLICAR: la aplica George.
-- Comando exacto:
--   source ~/.espiga-secrets.sh && curl -s -X POST "https://api.supabase.com/v1/projects/tevzfdiumfekvapamovw/database/query" \
--     -H "Authorization: Bearer $KUXTAL_SUPA_PAT" -H "Content-Type: application/json" \
--     --data-binary @<(python3 -c "import json;print(json.dumps({'query':open('supabase/migrations/20260714_marco_funnel.sql').read()}))")
--
-- Qué agrega: la columna 'enganche' (pago inicial) en funnel_contratos.
-- El CRM ya es tolerante a su ausencia: probeContratosExt() detecta la columna; mientras
-- no exista, el enganche queda registrado en funnel_eventos (tipo 'enganche').
-- NO toca policies (fcon_wr ALL con funnel_ve_todo() ya cubre el UPDATE del CRM).

alter table public.funnel_contratos
  add column if not exists enganche numeric;

comment on column public.funnel_contratos.enganche is
  'Pago inicial (enganche) acordado al firmar. Default sugerido: funnel_membresias.enganche del tipo elegido; el cerrador lo puede ajustar en Cierre.';
