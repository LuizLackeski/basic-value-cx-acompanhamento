-- ============================================================================
-- Query: Validação de ESN da propriedade — versão de SINCRONIZAÇÃO
-- (1 linha por par ticket_id/esn). Gerado em 2026-08-12.
--
-- Esta é a versão usada pelo pipeline de sincronização: roda no Databricks,
-- o resultado vira a chave "esn_validacao" do data/latest-sync.json, e o
-- upsert_to_supabase.py grava em esn_validacao_snapshot (ver
-- supabase/patch-esn-validacao.sql).
--
-- Pedido do Luiz (2026-08-11 à noite, verbatim): "sobre a validação dos esn
-- na propriedade, tem uma divergência que mostra a mais nelas, então queria
-- pegar pela tabela do Databricks puxa o esn da propriedade do hubs que ja
-- temos, e cruza com a pedido_de_entrega usando o esn + company_id no
-- Databricks." Depois: "por enquanto tra só o modelo [do dispositivo]. depois
-- ajusto os nomes com mais tempo" -- ModeloItem cru, sem mapear pra nome
-- amigável ainda.
--
-- Causa raiz da divergência ("ESN a mais"): um mesmo dispositivo físico pode
-- ser desinstalado de uma empresa e reinstalado em outra ao longo do tempo.
-- supply_team.supply_db.pedido_de_entrega guarda TODO o histórico por Esn
-- (uma linha por entrega/alocação), não só a atual -- então um match
-- ESN-only, sem desambiguação por tempo, também conta empresas antigas.
--
-- Heurística validada (POC com 5 ESNs de teste, 3 deles com histórico de
-- outras empresas -- os 5 bateram certo): a linha de pedido_de_entrega com o
-- CreatedAt mais recente por Esn é o "dono atual" --
-- ROW_NUMBER() OVER (PARTITION BY Esn ORDER BY CreatedAt DESC) = 1. O
-- company_id dessa linha (via TicketIDCRM -> ticket_id -> company_id, usando
-- gold.cubo_supply.supply_cube como tabela de resolução ticket->company) é
-- comparado contra o company_id esperado (o mesmo da propriedade
-- instalacao__esns_processados) -- 'ok' se bater, 'divergente' se não bater,
-- 'sem_match' se o Esn não for encontrado em pedido_de_entrega.
--
-- Escopo: mesmo filtro de pipeline/status do resto do dashboard (pipeline
-- "Serviços" = hs_pipeline 263640, status "Agendar instalação" = stage
-- 263641). Rodado para toda a base em 2026-08-12: 6233 pares (ticket_id,
-- esn) em 1742 tickets distintos -- 5795 ok / 410 divergentes / 28 sem_match.
-- ============================================================================

WITH scope AS (
  SELECT ticket_id, company_id, instalacao__esns_processados
  FROM gold.cubo_supply.supply_cube
  WHERE pipeline_label = 'Serviços' AND ticket_status = 'Agendar instalação'
),
esn_expected AS (
  -- Explode o array de ESNs da propriedade do HubSpot (já ingerida no
  -- supply_cube) -- 1 linha por (ticket_id, esn) esperado.
  SELECT ticket_id, company_id, esn
  FROM scope
  LATERAL VIEW explode(instalacao__esns_processados) t AS esn
  WHERE company_id IS NOT NULL
    AND instalacao__esns_processados IS NOT NULL
    AND size(instalacao__esns_processados) > 0
),
ticket_company AS (
  -- Resolução ticket_id -> company_id (usada pra descobrir a empresa do
  -- TicketIDCRM encontrado em pedido_de_entrega, que pode ser QUALQUER
  -- ticket histórico, não só os do escopo atual).
  SELECT DISTINCT ticket_id, company_id
  FROM gold.cubo_supply.supply_cube
  WHERE company_id IS NOT NULL
),
pedido_ranked AS (
  SELECT Esn, TicketIDCRM, ModeloItem, ItemName, CreatedAt,
    ROW_NUMBER() OVER (PARTITION BY Esn ORDER BY CreatedAt DESC) AS rn
  FROM supply_team.supply_db.pedido_de_entrega
  WHERE Esn IS NOT NULL
),
dono_atual AS (
  -- "Dono atual" do ESN = linha mais recente por Esn em pedido_de_entrega.
  SELECT pr.Esn,
    pr.TicketIDCRM AS dono_ticket_id,
    tc.company_id  AS dono_company_id,
    pr.ModeloItem,   -- CRU -- sem mapear pra nome amigável (a pedido do Luiz)
    pr.ItemName
  FROM pedido_ranked pr
  LEFT JOIN ticket_company tc ON tc.ticket_id = pr.TicketIDCRM
  WHERE pr.rn = 1
)
SELECT
  ee.ticket_id,
  ee.company_id AS company_id_esperado,
  ee.esn,
  da.ModeloItem AS modelo_item,
  da.ItemName   AS item_name,
  da.dono_ticket_id,
  da.dono_company_id,
  CASE
    WHEN da.dono_company_id IS NULL THEN 'sem_match'
    WHEN da.dono_company_id = ee.company_id THEN 'ok'
    ELSE 'divergente'
  END AS esn_status
FROM esn_expected ee
LEFT JOIN dono_atual da ON da.Esn = ee.esn
ORDER BY ee.ticket_id, ee.esn;

-- ============================================================================
-- Depois de rodar: o resultado vira a chave "esn_validacao" (array de
-- objetos, um por linha acima) dentro do payload de sincronização -- ver
-- Passo 4C do sync-runbook.md e scripts/upsert_to_supabase.py
-- (TABLE_KEYS inclui "esn_validacao", grava em esn_validacao_snapshot via
-- upsert on_conflict=(ticket_id,esn)).
-- ============================================================================
