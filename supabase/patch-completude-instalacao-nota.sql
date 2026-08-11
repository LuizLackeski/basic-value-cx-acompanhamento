-- ============================================================================
-- Patch: Completude de Instalação — nota (0-4) e gap p/ nota 3 (Rodada 8, 2026-08-11)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS de
-- patch-completude-instalacao.sql e patch-completude-instalacao-prazo.sql.
-- Idempotente: pode rodar de novo sem quebrar nada.
--
-- Contexto / pedido do Luiz (2026-08-11): no Basic Value (aba SMB/ICP/
-- Onboarding), a coluna "Geral" (basic_value_score) some para SMB e ICP --
-- fica só a Instalação, mais um comparativo de "quanto falta pra bater nota
-- 3". Onboarding mantém as duas (Geral + Instalação) mais o mesmo
-- comparativo. A "nota" de instalação passa a ser calculada do zero (0 a 4)
-- a partir do % de completude (qtd_instalada / qtd_completude), usando uma
-- escala diferente por segmento -- e não mais o instalation_completeness_grade
-- vindo do Databricks, que tinha muita empresa sem dado. Onboarding usa a
-- escala de SMB ou de ICP conforme o potencial da empresa (<=50 = SMB, >50 =
-- ICP). Ver queries/query-completude-instalacao-sync.sql (CTEs
-- empresa_resumo/empresa_escala) para a lógica completa das duas escalas:
--   SMB:  0%=0   até 75%=1   76-89%=2   90-95%=3   acima de 95%=4
--   ICP:  0%=0   até 75%=1   76-79%=2   80-85%=3   acima de 85%=4
--
-- O Luiz também confirmou (via pergunta de esclarecimento nesta sessão):
--   a. Recalcular a nota do zero a partir da Completude de Instalação (não
--      reaproveitar o instalation_completeness_grade do Databricks) --
--      resolve o problema de empresas sem dado.
--   b. O gap mostrado é "faltam N instalações p/ nota 3" (quantidade, não %).
--   c. O badge "em risco" (mrr_status) passa a ser baseado na nota NOVA
--      (nota_instalacao < 3) para TODOS os segmentos -- antes só considerava
--      basic_value_score, e só fazia sentido de fato pra Onboarding.
--
-- O que este patch faz:
--   1. Adiciona nota_instalacao (int, 0-4) e qtd_falta_nota_3 (int) em
--      completude_instalacao_snapshot.
--   2. Recria v_dashboard (drop + create -- Postgres não deixa adicionar
--      coluna no meio de uma view via CREATE OR REPLACE) expondo os dois
--      campos novos como completude_nota_instalacao / completude_qtd_falta_nota_3.
--   3. Muda mrr_status de "bv.basic_value_score < 3" para
--      "ci.nota_instalacao < 3", valendo para todos os segmentos.
--      Comportamento quando não há dado de completude para a empresa (ci
--      nulo / nota_instalacao nulo): a comparação "null < 3" é desconhecida
--      em SQL, então cai no ELSE -> mrr_status = 'ok' (empresa sem dado de
--      instalação não é marcada como em risco por omissão, não por decisão
--      explícita de negócio -- revisitar se isso gerar falso "ok").
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Novas colunas em completude_instalacao_snapshot
-- ----------------------------------------------------------------------------
alter table completude_instalacao_snapshot
  add column if not exists nota_instalacao int,
  add column if not exists qtd_falta_nota_3 int;

comment on column completude_instalacao_snapshot.nota_instalacao is
  'Nota de 0 a 4 calculada a partir de pct_completude (qtd_instalada/qtd_completude), com escala por segmento (SMB, ICP, ou Onboarding usando a escala de SMB/ICP conforme potencial da empresa). Substitui basic_value_score/instalation_completeness_grade (Databricks) como fonte da nota de instalação a partir da Rodada 8 (2026-08-11) -- ver queries/query-completude-instalacao-sync.sql.';

comment on column completude_instalacao_snapshot.qtd_falta_nota_3 is
  'Quantas instalações faltam para a empresa bater nota 3 na escala de instalação (0 se já bateu ou passou). Calculado como max(ceil(limiar_nota_3 * qtd_completude) - qtd_instalada, 0), onde limiar_nota_3 é 90% (SMB) ou 80% (ICP), conforme a escala aplicada.';

-- ----------------------------------------------------------------------------
-- 2. v_dashboard: recriar incluindo os 2 campos novos + mrr_status baseado na
--    nota nova (Rodada 8).
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
  -- ---- Rodada 8 (2026-08-11): mrr_status agora usa a nota nova de
  -- instalação (ci.nota_instalacao), pra todos os segmentos -- antes usava
  -- só bv.basic_value_score. Empresa sem dado de completude (nota_instalacao
  -- null) cai no else -> 'ok' (ver comentário no cabeçalho do patch).
  case when ci.nota_instalacao < 3 then 'em_risco' else 'ok' end as mrr_status,
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
  ci.dentro_do_prazo   as completude_dentro_do_prazo,
  -- ---- NOVO (Rodada 8, 2026-08-11): nota de instalação (0-4) e gap p/ nota 3 ----
  ci.nota_instalacao    as completude_nota_instalacao,
  ci.qtd_falta_nota_3   as completude_qtd_falta_nota_3
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
  'View principal do dashboard. security_invoker=true faz ela respeitar o RLS de tickets_sync do usuário que está consultando — não precisa de policy própria. Inclui a Completude de Instalação (completude_*) desde 2026-08-11, o indicador de prazo (completude_dentro_do_prazo) desde 2026-08-11 (Rodada 7), e a nota de instalação recalculada (completude_nota_instalacao / completude_qtd_falta_nota_3) desde 2026-08-11 (Rodada 8) -- que também passou a alimentar mrr_status no lugar de basic_value_score.';

-- ============================================================================
-- Fim do patch. Depois de rodar: a próxima sincronização (que já publica
-- nota_instalacao/qtd_falta_nota_3 dentro de cada item de
-- completude_instalacao no JSON -- ver
-- queries/query-completude-instalacao-sync.sql e sync-runbook.md) popula
-- essas colunas de verdade. Até lá, elas aparecem como null no v_dashboard, e
-- mrr_status cai todo em 'ok' até a sincronização rodar (index.html já trata
-- null como "-" na célula de instalação).
--
-- Escopo desta rodada (intencionalmente NÃO alterado -- ver comentário em
-- index.html perto de GRADE_ORDER): o pill de distribuição "Empresas por
-- Basic Value de instalação" e o snapshot de evolução
-- (maybeCaptureSnapshotIfGestorGeral) continuam usando
-- instalation_completeness_grade (Databricks), não completude_nota_instalacao.
-- Migrar isso fica para uma rodada futura.
-- ============================================================================
