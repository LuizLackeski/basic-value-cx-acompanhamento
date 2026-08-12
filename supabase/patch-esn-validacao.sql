-- ============================================================================
-- Patch: Validação de ESN da propriedade (2026-08-12)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS de todos os
-- patches anteriores (login-flow, team-members-rls, rodada6,
-- completude-instalacao, completude-instalacao-prazo,
-- completude-instalacao-nota). Idempotente: pode rodar de novo sem quebrar
-- nada.
--
-- Contexto / pedido do Luiz (2026-08-11 à noite): havia uma divergência de
-- backlog em que o ESN vindo da propriedade do HubSpot
-- (gold.cubo_supply.supply_cube.instalacao__esns_processados, por
-- company_id/ticket_id) aparecia "a mais" na comparação simples com
-- supply_team.supply_db.pedido_de_entrega. Causa raiz confirmada: um mesmo
-- ESN físico pode ter sido desinstalado de uma empresa e reinstalado em
-- outra ao longo do tempo -- pedido_de_entrega guarda TODO o histórico por
-- ESN, então um match ESN-only (sem desambiguação por tempo) conta empresas
-- antigas também. Heurística validada com 5 ESNs de teste (todos corretos,
-- inclusive 3 casos com histórico de outras empresas): a linha de
-- pedido_de_entrega com CreatedAt mais recente por ESN
-- (ROW_NUMBER() OVER (PARTITION BY Esn ORDER BY CreatedAt DESC) = 1) é o
-- "dono atual" -- comparar o company_id dessa linha (via TicketIDCRM ->
-- ticket_id -> company_id) contra o company_id esperado (o da propriedade)
-- decide se o ESN está "ok" ou "divergente".
--
-- Rodado para toda a base em escopo do dashboard (pipeline "Serviços",
-- status "Agendar instalação" -- mesmo filtro do resto do app): 6233 pares
-- (ticket_id, esn) em 1742 tickets distintos -- 5795 ok / 410 divergentes /
-- 28 sem_match (ESN não encontrado em pedido_de_entrega).
--
-- Escopo combinado com o Luiz: trazer só o ModeloItem CRU por ESN (sem
-- mapear pra nome amigável ainda -- "por enquanto tra só o modelo, depois
-- ajusto os nomes com mais tempo").
--
-- Query de sincronização completa: queries/query-esn-validacao-sync.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabela de snapshot -- grão (ticket_id, esn), 1 linha por ESN esperado
--    por ticket (um ticket pode ter vários ESNs).
-- ----------------------------------------------------------------------------
create table if not exists esn_validacao_snapshot (
  ticket_id           text not null,     -- ticket que "espera" este ESN (propriedade do HubSpot)
  esn                 text not null,     -- ESN do dispositivo
  company_id_esperado text,              -- company_id do ticket acima (o que a propriedade diz que é dono)
  modelo_item         text,              -- ModeloItem CRU de pedido_de_entrega (ex.: FMC130, JC400) -- SEM mapeamento de nome amigável, a pedido do Luiz
  item_name           text,              -- descrição mais completa (ItemName), também crua
  dono_ticket_id      text,              -- TicketIDCRM da linha mais recente de pedido_de_entrega pra este ESN ("dono atual")
  dono_company_id     text,              -- company_id resolvido a partir do dono_ticket_id (via supply_cube)
  esn_status          text not null,     -- 'ok' | 'divergente' | 'sem_match' (ESN não encontrado em pedido_de_entrega)
  synced_at           timestamptz not null default now(),
  primary key (ticket_id, esn)
);

comment on table esn_validacao_snapshot is
  'Validação do ESN da propriedade do HubSpot (supply_cube.instalacao__esns_processados) contra o "dono atual" segundo pedido_de_entrega (linha mais recente por ESN via CreatedAt). esn_status=divergente indica ESN reutilizado entre empresas (mesmo device físico, dono mudou). Query de sincronização: queries/query-esn-validacao-sync.sql.';

alter table esn_validacao_snapshot enable row level security;

-- Mesma regra das outras tabelas de snapshot: visível pra quem já enxerga
-- esse ticket via tickets_sync (o RLS/bypass de gestor_geral cai em
-- cascata aqui também).
drop policy if exists esn_validacao_select on esn_validacao_snapshot;
create policy esn_validacao_select on esn_validacao_snapshot
  for select using (
    ticket_id in (select ticket_id from tickets_sync)
  );

-- ----------------------------------------------------------------------------
-- 2. View de agregação por ticket -- 1 linha por ticket_id, resume os ESNs
--    dele pra caber no v_dashboard (que é 1 linha por ticket).
-- ----------------------------------------------------------------------------
drop view if exists v_esn_validacao_ticket;
create view v_esn_validacao_ticket
with (security_invoker = true) as
select
  ticket_id,
  count(*) filter (where esn_status = 'divergente') as esn_divergente_count,
  count(*) filter (where esn_status = 'sem_match')  as esn_sem_match_count,
  array_agg(distinct modelo_item order by modelo_item) filter (where modelo_item is not null) as esn_modelos_raw,
  jsonb_agg(
    jsonb_build_object(
      'esn', esn, 'modelo_item', modelo_item, 'status', esn_status,
      'dono_ticket_id', dono_ticket_id, 'dono_company_id', dono_company_id
    ) order by esn
  ) as esn_detalhe
from esn_validacao_snapshot
group by ticket_id;

comment on view v_esn_validacao_ticket is
  'Agregação de esn_validacao_snapshot por ticket -- alimenta v_dashboard (esn_divergente_count, esn_sem_match_count, esn_modelos_raw, esn_detalhe).';

-- ----------------------------------------------------------------------------
-- 3. v_dashboard: recriar incluindo os 4 campos novos (join por ticket_id).
--    Mesma view de supabase/patch-completude-instalacao-nota.sql, só
--    acrescentando o join novo no final.
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
  ci.nota_instalacao    as completude_nota_instalacao,
  ci.qtd_falta_nota_3   as completude_qtd_falta_nota_3,
  -- ---- NOVO (2026-08-12): Validação de ESN da propriedade ----
  ev.esn_divergente_count,
  ev.esn_sem_match_count,
  ev.esn_modelos_raw,
  ev.esn_detalhe
from tickets_sync t
left join team_members owner_tm
  on owner_tm.hubspot_owner_id = t.owner_hubspot_id
left join basic_value_snapshot bv
  on bv.company_id = t.company_id
left join field_status_snapshot fs
  on fs.ticket_id = t.ticket_id and fs.suffix_num is null
left join completude_instalacao_snapshot ci
  on ci.company_id = t.company_id
left join v_esn_validacao_ticket ev
  on ev.ticket_id = t.ticket_id
left join lateral (
  select status_tratativa, observacao, updated_at
  from ticket_checks
  where ticket_id = t.ticket_id
  order by updated_at desc
  limit 1
) tc on true;

comment on view v_dashboard is
  'View principal do dashboard. security_invoker=true faz ela respeitar o RLS de tickets_sync do usuário que está consultando. Inclui Completude de Instalação (completude_*, desde 2026-08-11) e Validação de ESN da propriedade (esn_divergente_count/esn_sem_match_count/esn_modelos_raw/esn_detalhe, desde 2026-08-12).';

-- ============================================================================
-- Fim do patch. Depois de rodar: a sincronização (que já publica a chave
-- "esn_validacao" no payload -- ver queries/query-esn-validacao-sync.sql e
-- sync-runbook.md) popula esn_validacao_snapshot. Até lá, os campos esn_*
-- novos aparecem como null/vazio no v_dashboard.
-- ============================================================================
