-- ============================================================================
-- Patch: Completude de Instalação — indicador de prazo (2026-08-11)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS de
-- patch-completude-instalacao.sql (que cria a tabela e a view). Idempotente:
-- pode rodar de novo sem quebrar nada.
--
-- Contexto / pedido do Luiz (2026-08-11): antes, um deal que já tivesse
-- passado do prazo (90 dias Onboarding / 60 dias ICP-SMB, contados da data
-- de início de assinatura) simplesmente parava de contar na soma da empresa
-- -- e se TODOS os deals dela tivessem passado do prazo, a empresa sumia por
-- completo do dashboard. O Luiz pediu duas coisas:
--   1. O dado de completude deve continuar aparecendo mesmo depois do prazo
--      vencer (isso já foi resolvido só na query, sem precisar de patch de
--      banco -- ver queries/query-completude-instalacao-sync.sql: agora a
--      soma da empresa usa só a elegibilidade por TIPO de deal, sem corte de
--      dias).
--   2. Só precisa existir ALGO visível indicando se a empresa ainda está
--      dentro do prazo pra completar, ou se o prazo já encerrou -- é isso
--      que este patch adiciona.
--
-- O que este patch faz:
--   1. Adiciona a coluna `dentro_do_prazo` (boolean) em
--      completude_instalacao_snapshot -- true se pelo menos um dos deals
--      elegíveis da empresa ainda está dentro do prazo (90/60 dias), false
--      se todos já passaram do prazo.
--   2. Recria v_dashboard incluindo esse campo novo (join por company_id),
--      aliasado como completude_dentro_do_prazo -- é o nome que
--      index.html já espera (função completudeInstalacaoHtml).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Nova coluna em completude_instalacao_snapshot
-- ----------------------------------------------------------------------------
alter table completude_instalacao_snapshot
  add column if not exists dentro_do_prazo boolean;

comment on column completude_instalacao_snapshot.dentro_do_prazo is
  'true = a empresa ainda tem pelo menos um deal elegível dentro do prazo (90 dias Onboarding / 60 dias ICP-SMB, contados da assinatura); false = todos os deals elegíveis dela já passaram do prazo. O dado de completude (qtd_completude/qtd_instalada/pct) continua sendo exibido nos dois casos -- este campo é só o indicador visual de prazo, não afeta o que entra na soma.';

-- ----------------------------------------------------------------------------
-- 2. v_dashboard: recriar incluindo o campo novo (join por company_id).
--    drop + create pelo mesmo motivo de sempre -- Postgres não deixa mudar
--    nome/posição de coluna existente via CREATE OR REPLACE VIEW.
-- ----------------------------------------------------------------------------
drop view if exists v_dashboard;
create view v_dashboard
with (security_invoker = true) as
select
  t.ticket_id,
  t.display_name,
  t.subject_raw,
  t.pipeline_stage_label,
  t.in_agendar_instalacao,
  t.classe_instalacao,
  t.owner_name,
  t.owner_hubspot_id,
  owner_tm.squad as owner_squad,
  t.createdate,
  t.synced_at,
  extract(epoch from (now() - t.createdate)) / 86400.0 as dias_aberto,
  t.esn_count,
  t.hubspot_url,
  t.company_id,
  bv.company_name,
  bv.basic_value_score,
  bv.instalation_completeness_grade,
  bv.mrr,
  case when bv.basic_value_score < 3 then 'em_risco' else 'ok' end as mrr_status,
  fs.status        as field_status,
  fs.prestador,
  fs.consultor,
  fs.data_agendada,
  tc.status_tratativa,
  tc.observacao,
  tc.updated_at    as tratativa_updated_at,
  -- ---- Completude de Instalação (por empresa) ----
  ci.time_segmento     as completude_time_segmento,
  ci.qtd_completude    as completude_qtd_completude,
  ci.qtd_instalada     as completude_qtd_instalada,
  ci.pct_completude    as completude_pct,
  ci.qtd_falta_meta_80 as completude_qtd_falta,
  -- ---- NOVO (2026-08-11): indicador de prazo ----
  ci.dentro_do_prazo   as completude_dentro_do_prazo
from tickets_sync t
left join team_members owner_tm
  on owner_tm.hubspot_owner_id = t.owner_hubspot_id
left join basic_value_snapshot bv
  on bv.company_id = t.company_id
left join field_status_snapshot fs
  on fs.ticket_id = t.ticket_id and fs.suffix_num is null
left join completude_instalacao_snapshot ci
  on ci.company_id = t.company_id
left join lateral (
  select status_tratativa, observacao, updated_at
  from ticket_checks
  where ticket_id = t.ticket_id
  order by updated_at desc
  limit 1
) tc on true;

comment on view v_dashboard is
  'View principal do dashboard. security_invoker=true faz ela respeitar o RLS de tickets_sync do usuário que está consultando — não precisa de policy própria. Inclui a Completude de Instalação (completude_*) desde 2026-08-11, e o indicador de prazo (completude_dentro_do_prazo) desde 2026-08-11 (Rodada 7).';

-- ============================================================================
-- Fim do patch. Depois de rodar: a próxima sincronização (que já publica a
-- chave "dentro_do_prazo" dentro de cada item de completude_instalacao no
-- JSON -- ver queries/query-completude-instalacao-sync.sql e
-- sync-runbook.md) popula esta coluna de verdade. Até lá, ela aparece como
-- null no v_dashboard (index.html já trata null como "sem badge", só mostra
-- o % de completude sem indicar prazo).
-- ============================================================================
