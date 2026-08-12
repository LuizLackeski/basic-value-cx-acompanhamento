-- ============================================================================
-- Patch: Completude de Instalação por DEAL, não mais por EMPRESA (Rodada 12, 2026-08-12)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS de
-- patch-completude-instalacao.sql, patch-completude-instalacao-prazo.sql e
-- patch-completude-instalacao-nota.sql.
--
-- Contexto / achado (Luiz, 2026-08-12): completude_instalacao_snapshot era
-- agregada por EMPRESA (company_id) -- 1 valor de dentro_do_prazo/pct/etc.
-- compartilhado por TODOS os tickets/deals da mesma empresa. Uma empresa com
-- uma venda nova ainda dentro do prazo "carregava" esse status pra tickets de
-- vendas antigas já vencidas da MESMA empresa -- achado investigando o ticket
-- 36311791626 (deal 49779167653, assinado 24/11/2025, ~258 dias -- já
-- vencido -- mas aparecia "dentro do prazo" porque a mesma empresa,
-- 9608025244, tem outra venda Upsell mais recente, deal 62115236907, 37 dias,
-- ainda dentro do prazo). Ver backlog.md (Rodada 12) e
-- claude/rodada11-2026-08-12-resumo.md para o achado completo.
--
-- O que este patch faz:
--   1. tickets_sync ganha a coluna deal_id (resolvida via associação HubSpot
--      TICKET->DEAL na sincronização -- ver sync-runbook.md Passo 2).
--   2. completude_instalacao_snapshot é recriada (drop + create) com deal_id
--      como CHAVE (era company_id) -- é uma tabela de snapshot, sobrescrita a
--      cada sincronização, sem histórico valioso e sem FK apontando pra ela,
--      então dropar e recriar é seguro. Ganha também a coluna nova
--      dias_restantes_prazo (ver queries/query-completude-instalacao-sync.sql).
--   3. RLS: nova policy de select por deal_id (era por company_id).
--   4. v_dashboard: recriada (drop + create) com o join por deal_id
--      (t.deal_id = ci.deal_id) em vez de company_id, e expõe
--      completude_dias_restantes_prazo. TODOS os outros nomes de coluna
--      expostos continuam os mesmos -- completude_pct, completude_qtd_falta,
--      completude_dentro_do_prazo, completude_nota_instalacao,
--      completude_qtd_falta_nota_3, completude_time_segmento,
--      completude_qtd_completude, completude_qtd_instalada -- só a CHAVE de
--      join mudou, index.html não precisa de nenhuma mudança pra ler os
--      dados novos.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. tickets_sync ganha deal_id
-- ----------------------------------------------------------------------------
alter table tickets_sync add column if not exists deal_id text;

comment on column tickets_sync.deal_id is
  'ID do deal do HubSpot associado a este ticket (associação nativa TICKET->DEAL). Resolvido na sincronização (sync-runbook.md Passo 2) via query_crm_data (SELECT DEAL.hs_object_id FROM TICKET ...). Usado desde a Rodada 12 (2026-08-12) para juntar com completude_instalacao_snapshot por deal em vez de por company_id -- corrige o caso de uma venda nova da mesma empresa "carregar" o status de uma venda antiga já vencida.';

-- ----------------------------------------------------------------------------
-- 2. completude_instalacao_snapshot: recriar com deal_id como chave
-- ----------------------------------------------------------------------------
drop table if exists completude_instalacao_snapshot cascade;

create table completude_instalacao_snapshot (
  deal_id              text primary key,
  company_id           text,   -- mantido pra referência/debug -- não é mais a chave de join
  time_segmento        text,
  qtd_completude        int,
  qtd_instalada         int,
  pct_completude        numeric,
  qtd_falta_meta_80     int,
  dentro_do_prazo       boolean,
  nota_instalacao       int,
  qtd_falta_nota_3      int,
  dias_restantes_prazo  int,
  synced_at             timestamptz not null default now()
);

comment on table completude_instalacao_snapshot is
  'Completude de Instalação por DEAL (Rodada 12, 2026-08-12) -- antes era por company_id (empresa). Ver queries/query-completude-instalacao-sync.sql para a query de origem (roda no Databricks, 1 linha por deal elegível).';

comment on column completude_instalacao_snapshot.dias_restantes_prazo is
  'Dias restantes do prazo (90 ou 60 menos dias desde a assinatura, conforme o segmento) do PRÓPRIO deal -- positivo = ainda dentro do prazo, negativo = já venceu há N dias. Consistente por construção com dentro_do_prazo. Usado no front-end para mostrar "dentro do prazo Nd" (ver diasRestantesPrazoCompletude() em index.html).';

alter table completude_instalacao_snapshot enable row level security;

drop policy if exists completude_instalacao_select on completude_instalacao_snapshot;
create policy completude_instalacao_select on completude_instalacao_snapshot
  for select using (
    deal_id in (select deal_id from tickets_sync where deal_id is not null)
  );

-- ----------------------------------------------------------------------------
-- 3. v_dashboard: recriar com o join por deal_id
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
  t.deal_id,
  bv.company_name,
  bv.basic_value_score,
  bv.instalation_completeness_grade,
  bv.mrr,
  -- mrr_status continua igual à Rodada 8 (baseado em nota_instalacao, não
  -- mais basic_value_score) -- só o que mudou é como nota_instalacao chega
  -- até aqui (agora via join por deal_id).
  case when ci.nota_instalacao < 3 then 'em_risco' else 'ok' end as mrr_status,
  fs.status        as field_status,
  fs.prestador,
  fs.consultor,
  fs.data_agendada,
  tc.status_tratativa,
  tc.observacao,
  tc.updated_at    as tratativa_updated_at,
  -- ---- Completude de Instalação (Rodada 12: por DEAL, não mais por empresa) ----
  ci.time_segmento     as completude_time_segmento,
  ci.qtd_completude    as completude_qtd_completude,
  ci.qtd_instalada     as completude_qtd_instalada,
  ci.pct_completude    as completude_pct,
  ci.qtd_falta_meta_80 as completude_qtd_falta,
  ci.dentro_do_prazo   as completude_dentro_do_prazo,
  ci.nota_instalacao    as completude_nota_instalacao,
  ci.qtd_falta_nota_3   as completude_qtd_falta_nota_3,
  -- ---- NOVO (Rodada 12, 2026-08-12) ----
  ci.dias_restantes_prazo as completude_dias_restantes_prazo
from tickets_sync t
left join team_members owner_tm
  on owner_tm.hubspot_owner_id = t.owner_hubspot_id
left join basic_value_snapshot bv
  on bv.company_id = t.company_id
left join field_status_snapshot fs
  on fs.ticket_id = t.ticket_id and fs.suffix_num is null
left join completude_instalacao_snapshot ci
  on ci.deal_id = t.deal_id
left join lateral (
  select status_tratativa, observacao, updated_at
  from ticket_checks
  where ticket_id = t.ticket_id
  order by updated_at desc
  limit 1
) tc on true;

comment on view v_dashboard is
  'View principal do dashboard. security_invoker=true faz ela respeitar o RLS de tickets_sync do usuário que está consultando. Completude de Instalação (completude_*) agora por DEAL (Rodada 12, 2026-08-12) -- join por t.deal_id = ci.deal_id, não mais por company_id. Ver backlog.md e claude/rodada11-2026-08-12-resumo.md para o achado que motivou a mudança (ticket 36311791626).';

-- ============================================================================
-- Fim do patch. IMPORTANTE: depois de rodar este patch, os dados de
-- completude ficam TODOS null até a próxima sincronização publicar (a) o
-- deal_id de cada ticket em tickets_sync e (b) as linhas por deal em
-- completude_instalacao_snapshot (ver queries/query-completude-instalacao-sync.sql
-- e sync-runbook.md, Passo 2 e Passo 4B atualizados na Rodada 12). Isso é
-- esperado -- index.html já trata completude null como "-" na célula.
-- ============================================================================
