-- ============================================================================
-- Patch: Completude de Instalação (2026-08-11)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS do schema.sql e
-- dos outros patches (patch-login-flow.sql, patch-team-members-rls.sql,
-- patch-rodada6.sql). Idempotente: pode rodar de novo sem quebrar nada.
--
-- O que este patch faz:
--   1. Cria a tabela completude_instalacao_snapshot (1 linha por empresa),
--      alimentada pela sincronização (Databricks -> GitHub Actions ->
--      Supabase), igual às outras tabelas de snapshot (basic_value_snapshot,
--      field_status_snapshot).
--   2. RLS: mesma regra de basic_value_snapshot -- só é visível quem já
--      enxerga algum ticket dessa empresa (reaproveita o RLS de
--      tickets_sync via IN, sem duplicar a lógica de visible_owner_ids()).
--   3. Recria v_dashboard incluindo os 5 campos novos (join por company_id).
--
-- De onde vêm os números (Databricks): gold.cubo_contratos.fct_contract_products
-- + gold.cubo_supply.supply_cube + supply_team.supply_db.*. Query completa de
-- sincronização em queries/query-completude-instalacao-sync.sql.
--
-- Regra de elegibilidade (o que entra na soma de cada empresa), por segmento:
--   Onboarding: só deals cujo classe_deal contém 'Primeira venda', e só
--     dentro de até 90 dias da data de início de assinatura.
--   ICP e SMB: o INVERSO -- só deals cujo classe_deal NÃO contém 'Primeira
--     venda' (ou seja, Upsell/Troca/Upgrade/Downgrade), e só dentro de até
--     60 dias da data de início de assinatura.
--   Meta de instalação nos três casos: 80%.
-- Regra confirmada com o Luiz em 2026-08-11, mas sinalizada por ele como
-- "ainda vamos ajustar" -- não é definitiva.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabela de snapshot (1 linha por empresa)
-- ----------------------------------------------------------------------------
create table if not exists completude_instalacao_snapshot (
  company_id         text primary key,   -- = hs_object_id da Company (mesma chave de tickets_sync.company_id / basic_value_snapshot.company_id)
  time_segmento      text,               -- 'Onboarding' | 'ICP' | 'SMB' -- mesmo segmento usado no resto do dashboard
  qtd_completude     int,                -- soma do que foi contratado, só dos deals elegíveis (ver regra no cabeçalho)
  qtd_instalada      int,                -- soma do que já foi instalado, mesmos deals elegíveis
  pct_completude     numeric,            -- qtd_instalada / qtd_completude, já capado em 1.0 (100%)
  qtd_falta_meta_80  int,                -- quantas instalações faltam pra bater a meta de 80% (0 se já bateu)
  synced_at          timestamptz not null default now()
);

comment on table completude_instalacao_snapshot is
  'Completude de instalação por empresa. Elegibilidade: Onboarding = só deals "Primeira venda" até 90 dias da assinatura; ICP/SMB = o inverso (Upsell/Troca/Upgrade/Downgrade) até 60 dias. Meta 80% nos três casos. Query de sincronização em queries/query-completude-instalacao-sync.sql -- regra sinalizada pelo Luiz como sujeita a ajuste (2026-08-11).';

alter table completude_instalacao_snapshot enable row level security;

-- Mesma regra de basic_value_snapshot: visível pra quem já enxerga algum
-- ticket dessa empresa (o RLS de tickets_sync é reaplicado dentro do IN,
-- então o bypass de gestor_geral cai em cascata aqui também).
drop policy if exists completude_instalacao_select on completude_instalacao_snapshot;
create policy completude_instalacao_select on completude_instalacao_snapshot
  for select using (
    company_id in (select company_id from tickets_sync)
  );

-- ----------------------------------------------------------------------------
-- 2. v_dashboard: recriar incluindo os 5 campos novos (join por company_id).
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
  -- ---- NOVO: Completude de Instalação (por empresa) ----
  ci.time_segmento     as completude_time_segmento,
  ci.qtd_completude    as completude_qtd_completude,
  ci.qtd_instalada     as completude_qtd_instalada,
  ci.pct_completude    as completude_pct,
  ci.qtd_falta_meta_80 as completude_qtd_falta
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
  'View principal do dashboard. security_invoker=true faz ela respeitar o RLS de tickets_sync do usuário que está consultando — não precisa de policy própria. Inclui a Completude de Instalação (completude_*) desde 2026-08-11.';

-- ============================================================================
-- Fim do patch. Depois de rodar: a sincronização seguinte (que já vai incluir
-- a chave "completude_instalacao" no payload -- ver
-- queries/query-completude-instalacao-sync.sql e sync-runbook.md) popula esta
-- tabela. Até lá, os campos completude_* aparecem como null no v_dashboard
-- (index.html já trata null como "-").
-- ============================================================================
