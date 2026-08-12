-- ============================================================================
-- Query: Completude de Instalação — versão de SINCRONIZAÇÃO (1 linha por DEAL)
-- Gerado em 2026-08-11. Atualizado em 2026-08-11 (Rodada 8) com a nota de
-- Basic Value de Instalação (nota_instalacao) e o gap pra nota 3
-- (qtd_falta_nota_3). Testado direto no Databricks (dados reais).
--
-- REESCRITA NA RODADA 12 (2026-08-12) -- pedido do Luiz depois de investigar
-- o ticket 36311791626 (deal 49779167653, assinado 24/11/2025, ~258 dias
-- atrás -- já vencido -- mas aparecendo "dentro do prazo" no dashboard):
-- **antes**, esta query agregava por EMPRESA (associated_company_id) -- 1 só
-- valor de dentro_do_prazo/pct/qtd por empresa, compartilhado por TODOS os
-- tickets/deals dela (via SUM/MAX OVER PARTITION BY associated_company_id).
-- Uma empresa com uma venda nova ainda dentro do prazo "carregava" esse
-- status pra tickets de vendas antigas já vencidas da MESMA empresa -- exatamente
-- o caso do ticket acima (a mesma empresa, 9608025244, tem outra venda Upsell
-- mais recente, deal 62115236907, assinada 06/07/2026, 37 dias -- ainda
-- dentro do prazo -- que "carregava" o status pro ticket errado).
-- **Agora**: o resultado final é 1 linha POR DEAL (`deal_id`), não por
-- empresa -- cada deal mostra o status/percentual/nota da SUA PRÓPRIA venda,
-- sem interferência de outras vendas da mesma empresa. O front-end
-- (`v_dashboard`) passa a juntar por `deal_id` (o deal do PRÓPRIO ticket, via
-- associação HubSpot TICKET->DEAL, nova coluna `tickets_sync.deal_id`) em vez
-- de por `company_id` -- ver `supabase/patch-completude-instalacao-por-deal.sql`
-- e o Passo 2 atualizado do `sync-runbook.md`.
--
-- Também nesta rodada: o corte de data `DATA_INICIO_ASSINATURA >= '2026-01-01'`
-- (CTE `contratos`) foi trocado pra `>= '2024-01-01'`, a pedido do Luiz
-- ("pode considerar de 2024 o deal para trazer tudo") -- traz muito mais
-- histórico de deals elegíveis pra completude (validado no Databricks: 5809
-- deals / 1989 empresas com o corte de 2024, vs. 448 empresas com o corte de
-- 2026-01-01 usado até aqui).
--
-- Esta é a versão usada pelo pipeline (Passo 4B do sync-runbook.md): roda no
-- Databricks, o resultado vira a chave "completude_instalacao" do
-- data/latest-sync.json, e o upsert_to_supabase.py grava em
-- completude_instalacao_snapshot (ver
-- supabase/patch-completude-instalacao-por-deal.sql, que substitui a chave
-- primária de company_id para deal_id).
--
-- Difere de queries/query-completude-instalacao-onboarding.sql (que era a
-- versão "debug", 1 linha por deal, filtrada só em Onboarding, no formato de
-- BI tool com measure()) -- essa outra era só de debug; esta aqui é a que
-- roda de verdade no pipeline, juntando os 3 segmentos (Onboarding, ICP, SMB).
--
-- Regra de elegibilidade por TIPO (o que entra no resultado, sem corte de
-- dias), por segmento -- inalterada nesta rodada:
--   Onboarding: só deals cujo classe_deal contém 'Primeira venda'.
--   ICP e SMB: o INVERSO -- só deals cujo classe_deal NÃO contém 'Primeira
--     venda' (Upsell/Troca/Upgrade/Downgrade).
--   Meta de instalação nos três casos: 80%.
-- O corte de 60 dias (ICP/SMB) / 90 dias (Onboarding) NÃO exclui o deal do
-- resultado -- os dados continuam aparecendo mesmo depois do prazo vencer.
-- O corte só alimenta o campo "dentro_do_prazo" de CADA deal (TRUE = esse
-- deal, isoladamente, ainda está dentro do prazo; FALSE = já passou). Ver
-- ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO x DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO
-- no deal_metrics abaixo.
--
-- Nota de Basic Value de Instalação (2026-08-11, Rodada 8): substitui o
-- "Instalação" que vinha do Databricks
-- (gold.customer_success_reports.basic_value.instalation_completeness_grade,
-- que não cobre 100% das empresas com ticket aberto) por uma nota calculada
-- por nós, direto do % instalado/total do PRÓPRIO deal (antes era da
-- empresa), com faixas por segmento:
--   SMB (e Onboarding com potencial <= 50): 0%=0; até 75%=1; 76-89%=2;
--     90-95%=3; acima de 95%=4.
--   ICP (e Onboarding com potencial > 50): 0%=0; até 75%=1; 76-79%=2;
--     80-85%=3; acima de 85%=4.
-- O "potencial" usado pra decidir a escala do Onboarding é o mesmo campo já
-- usado internamente pra decidir se uma empresa pós-90-dias vira ICP ou SMB
-- (GRUPO_POTENCIAL / potencial_total_da_empresa, coalescidos). qtd_falta_nota_3
-- = quantas instalações faltam pra cruzar o piso da faixa que dá nota 3 (90%
-- na escala SMB, 80% na escala ICP) -- 0 se a nota já é 3 ou 4.
--
-- Pontos em aberto (ver também query-completude-instalacao-onboarding.sql):
--   1. Um deal com classe_deal misto (ex. "Primeira venda, Upsell") conta
--      inteiro como "Primeira venda" -- aproximação, a query não separa por
--      linha de produto dentro do deal.
--   2. Um ticket sem associação de deal no HubSpot (ou associado a mais de
--      um deal) não tem como ser vinculado por deal_id -- precisa de
--      verificação na sincronização de tickets (Passo 2) se isso acontece na
--      prática; amostra de 10 tickets conferida manualmente (Rodada 12)
--      mostrou sempre exatamente 1 deal por ticket.
-- ============================================================================

WITH q AS (
  WITH contratos AS (
    SELECT
      c.RAZAO_SOCIAL,
      c.endereco_uf,
      p.associated_company_id,
      c.status_da_empresa,
      c.fleet_size_empresa,
      c.potencial_total_da_empresa,
      p.TICKET_ASSOCIATED_DEAL_ID,
      p.DATA_INICIO_ASSINATURA,
      DATEDIFF(CURRENT_DATE, p.DATA_INICIO_ASSINATURA) AS DIAS_DESDE_ASSINATURA,
      SUM(
        CASE
          WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell')
          THEN p.QUANTIDADE_ALTERADOS
          ELSE 0
        END
      ) AS QTD_CONTRATADA_VENDA,
      SUM(
        CASE
          WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell')
          THEN p.MRR_TOTAL_PRODUTO
          ELSE 0
        END
      ) AS MRR_TOTAL,
      array_join(
        sort_array(
          collect_set(
            CASE
              WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]')
              THEN 'Primeira venda'
              ELSE p.FIN__CONFIG_TIPO
            END
          )
        ),
        ', '
      ) AS CLASSE_DEAL,
      MAX(
        CASE
          WHEN p.FIN__CONFIG_TIPO IN ('Troca', 'Upgrade', 'Downgrade') THEN 'TROCA'
          ELSE 'VENDA'
        END
      ) AS GRUPO_DEAL,
      c.csm_name
    FROM
      gold.cubo_contratos.fct_contract_products p
        LEFT JOIN gold.dimensions.dim_company_info c
          ON p.associated_company_id = c.id
    WHERE
      p.PRODUCT_ID IN ('1', '3', '4', '5', '6', '8', '31', '32')
      AND p.FIN__CONFIG_TIPO IN (
        'Primeira venda', 'Primeira venda [Upsell]', 'Upsell', 'Troca', 'Upgrade', 'Downgrade'
      )
      AND p.DATA_INICIO_ASSINATURA >= '2024-01-01'
      AND c.status_da_empresa IN ('Onboarding', 'Ongoing')
      AND p.TICKET_ASSOCIATED_DEAL_ID NOT IN (
        SELECT
          TICKET_ASSOCIATED_DEAL_ID
        FROM
          gold.cubo_contratos.fct_contract_products
        WHERE
          PRODUCT_ID IN ('11', '12')
          AND FIN__CONFIG_TIPO = 'Downgrade'
        GROUP BY
          TICKET_ASSOCIATED_DEAL_ID
        HAVING
          SUM(QUANTIDADE_ALTERADOS) > 0
      )
    GROUP BY
      p.associated_company_id,
      p.TICKET_ASSOCIATED_DEAL_ID,
      p.DATA_INICIO_ASSINATURA,
      c.RAZAO_SOCIAL,
      c.endereco_uf,
      c.status_da_empresa,
      c.fleet_size_empresa,
      c.potencial_total_da_empresa,
      c.csm_name
    HAVING
      COUNT(DISTINCT
        CASE
          WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell') THEN 'VENDA'
          WHEN p.FIN__CONFIG_TIPO IN ('Troca', 'Upgrade', 'Downgrade') THEN 'TROCA'
        END
      ) = 1
  ),
  churn AS (
    SELECT
      associated_company_id,
      MAX(CAST(DATA_INICIO_ASSINATURA AS DATE)) AS ULTIMO_CHURN
    FROM
      gold.cubo_contratos.fct_contract_products
    WHERE
      FIN__CONFIG_TIPO = 'Abandono total'
    GROUP BY
      associated_company_id
  ),
  primeira_venda_atual AS (
    SELECT
      p.associated_company_id,
      MIN(CAST(p.DATA_INICIO_ASSINATURA AS DATE)) AS DATA_PRIMEIRA_VENDA_ATUAL
    FROM
      gold.cubo_contratos.fct_contract_products p
        LEFT JOIN churn c
          ON p.associated_company_id = c.associated_company_id
    WHERE
      p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]')
      AND CAST(p.DATA_INICIO_ASSINATURA AS DATE) >= COALESCE(c.ULTIMO_CHURN, DATE '1900-01-01')
    GROUP BY
      p.associated_company_id
  ),
  grupo_time AS (
    SELECT
      a.grupo_economico_id,
      MIN(pva.DATA_PRIMEIRA_VENDA_ATUAL) AS GRUPO_DATA_PRIMEIRA_VENDA,
      MAX(g.grupo_economico__potencial_total) AS GRUPO_POTENCIAL
    FROM
      gold.dimensions.dim_company_associations a
        JOIN gold.dimensions.dim_company_info ci
          ON a.id = ci.id
          AND ci.status_da_empresa IN ('Onboarding', 'Ongoing')
        JOIN primeira_venda_atual pva
          ON a.id = pva.associated_company_id
        LEFT JOIN gold.dimensions.dim_grupo_economico_info g
          ON a.grupo_economico_id = g.id
    GROUP BY
      a.grupo_economico_id
  ),
  envios AS (
    SELECT
      t.ticket_associated_deal_id,
      e.ESN,
      e.COBLIID,
      t.ENVIO__CLASSE
    FROM
      gold.cubo_supply.supply_cube t
        LEFT JOIN supply_team.supply_db.pedido_de_entrega e
          ON t.TICKET_ID = e.TICKETIDCRM
    WHERE
      t.PIPELINE_LABEL = 'Envios'
      AND t.ENVIO__CLASSE IN ('Primeira compra', 'Upsell', 'Troca', 'Upgrade', 'Downgrade')
      AND t.TICKET_STATUS NOT IN ('Envio Retornado', 'Envio Cancelado')
      AND e.ESN IS NOT NULL
      AND e.Sku NOT LIKE 'PAREM%'
      AND e.Sku NOT LIKE 'PAPNP%'
      AND e.SKU NOT LIKE 'PAPERCAMAUX%'
      AND e.SKU NOT LIKE 'PAPERCARTR%'
      AND e.Sku NOT IN (
        'PAPERCAMAUXCD',
        'PAPERCHAVIDE',
        'PAPERCAMAUXCI',
        'PAPERCAMAUXCE',
        'PAPERCARTRFID125',
        'PAPERCARTRFID013'
      )
      AND t.ticket_associated_deal_id IN (
        SELECT
          TICKET_ASSOCIATED_DEAL_ID
        FROM
          contratos
      )
  ),
  envios_u AS (
    SELECT
      ticket_associated_deal_id,
      ESN,
      COBLIID,
      ENVIO__CLASSE
    FROM
      (
        SELECT
          e.*,
          ROW_NUMBER() OVER (
              PARTITION BY e.ticket_associated_deal_id, e.ESN
              ORDER BY e.ENVIO__CLASSE
            ) AS rn
        FROM
          envios e
      ) x
    WHERE
      rn = 1
  ),
  instalacoes AS (
    SELECT
      env.ticket_associated_deal_id,
      env.ESN,
      env.ENVIO__CLASSE,
      CASE
        WHEN CAST(o.DATA_SERVICO AS DATE) >= con.DATA_INICIO_ASSINATURA THEN 'Instalado'
        WHEN
          o.DATA_SERVICO IS NULL
          AND d.ORDEM_DE_SERVICO IS NOT NULL
        THEN
          'Instalado'
        ELSE 'Não Instalado'
      END AS STATUS_INSTALACAO,
      ROW_NUMBER() OVER (
          PARTITION BY env.ticket_associated_deal_id, env.ESN
          ORDER BY o.DATA_SERVICO ASC NULLS LAST
        ) AS rn
    FROM
      envios_u env
        LEFT JOIN contratos con
          ON env.ticket_associated_deal_id = con.TICKET_ASSOCIATED_DEAL_ID
        LEFT JOIN supply_team.supply_db.dispositivos d
          ON env.ESN = d.ESN
          AND env.COBLIID = d.numero_cobli
        LEFT JOIN supply_team.supply_db.os_finalizadas o
          ON d.ORDEM_DE_SERVICO = o.ORDEM_DE_SERVICO
  ),
  primeira_instalacao AS (
    SELECT
      *
    FROM
      instalacoes
    WHERE
      rn = 1
  ),
  agendados AS (
    SELECT
      ticket_associated_deal_id AS deal_id,
      SUM(instalacao__qtd_dispositivos_efetivamente_agendados) AS QTD_AGENDADO
    FROM
      gold.cubo_supply.supply_cube
    WHERE
      pipeline_label = 'Serviços'
      AND ticket_status = 'Aguardando tecnico instalar'
      AND instalacao__qtd_dispositivos_efetivamente_agendados > 0
      AND ticket_associated_deal_id IN (
        SELECT
          TICKET_ASSOCIATED_DEAL_ID
        FROM
          contratos
      )
    GROUP BY
      ticket_associated_deal_id
  ),
  base_deal AS (
    SELECT
      con.TICKET_ASSOCIATED_DEAL_ID AS deal_id,
      con.RAZAO_SOCIAL,
      con.endereco_uf,
      con.associated_company_id,
      con.status_da_empresa,
      con.fleet_size_empresa,
      con.potencial_total_da_empresa,
      con.DATA_INICIO_ASSINATURA,
      con.DIAS_DESDE_ASSINATURA,
      pva.DATA_PRIMEIRA_VENDA_ATUAL,
      gt.GRUPO_DATA_PRIMEIRA_VENDA,
      DATEDIFF(
        CURRENT_DATE,
        COALESCE(gt.GRUPO_DATA_PRIMEIRA_VENDA, pva.DATA_PRIMEIRA_VENDA_ATUAL)
      ) AS DIAS_1A_VENDA_GRUPO,
      con.CLASSE_DEAL,
      con.GRUPO_DEAL,
      con.QTD_CONTRATADA_VENDA,
      con.MRR_TOTAL,
      con.csm_name,
      cg.grupo_economico_id,
      gt.GRUPO_POTENCIAL,
      CASE
        WHEN
          DATEDIFF(
            CURRENT_DATE,
            COALESCE(gt.GRUPO_DATA_PRIMEIRA_VENDA, pva.DATA_PRIMEIRA_VENDA_ATUAL)
          ) <= 90
        THEN
          'Onboarding'
        WHEN COALESCE(gt.GRUPO_POTENCIAL, con.potencial_total_da_empresa) > 50 THEN 'ICP'
        ELSE 'SMB'
      END AS TIME,
      COUNT(DISTINCT inst.ESN) AS QTD_ENVIADA,
      COUNT(DISTINCT
        CASE
          WHEN inst.STATUS_INSTALACAO = 'Instalado' THEN inst.ESN
        END
      ) AS QTD_INSTALADA,
      COALESCE(MAX(ag.QTD_AGENDADO), 0) AS QTD_AGENDADO
    FROM
      contratos con
        LEFT JOIN primeira_venda_atual pva
          ON con.associated_company_id = pva.associated_company_id
        LEFT JOIN gold.dimensions.dim_company_associations cg
          ON con.associated_company_id = cg.id
        LEFT JOIN grupo_time gt
          ON cg.grupo_economico_id = gt.grupo_economico_id
        LEFT JOIN primeira_instalacao inst
          ON con.TICKET_ASSOCIATED_DEAL_ID = inst.ticket_associated_deal_id
        LEFT JOIN agendados ag
          ON con.TICKET_ASSOCIATED_DEAL_ID = ag.deal_id
    GROUP BY
      con.TICKET_ASSOCIATED_DEAL_ID,
      con.RAZAO_SOCIAL,
      con.endereco_uf,
      con.associated_company_id,
      con.status_da_empresa,
      con.fleet_size_empresa,
      con.potencial_total_da_empresa,
      con.DATA_INICIO_ASSINATURA,
      con.DIAS_DESDE_ASSINATURA,
      pva.DATA_PRIMEIRA_VENDA_ATUAL,
      con.CLASSE_DEAL,
      con.GRUPO_DEAL,
      con.QTD_CONTRATADA_VENDA,
      con.MRR_TOTAL,
      con.csm_name,
      cg.grupo_economico_id,
      gt.GRUPO_DATA_PRIMEIRA_VENDA,
      gt.GRUPO_POTENCIAL
  ),
  -- Blacklist de deal_id (mesma lista da query original do dashboard) aplicada
  -- ANTES de somar por empresa, senão esses deals ainda contaminariam a soma.
  base_deal_filtered AS (
    SELECT * FROM base_deal
    WHERE deal_id NOT IN (
      '49744884273','51088242312','47907249332','48859405420','47277935129','47662541092',
      '42407795752','45107932311','44888228389','45429497935','43937770118','44464602501',
      '44452441377','43241121701','43739885079','43500752711','43369126798','42905777020',
      '42960493590','42973395979','42361744266','41443159393','42656861344','39265106823',
      '42252841361','37485349527','38979039274','38345043279','40792938788','40286190860',
      '40456321868','40456958240','39875827496','39988437666','39662004113','39805446740',
      '38516913051','39995177997','39349114788','39549001221','39259367226','39222010663',
      '38847489864','39125272207','38818313555','38098101656','36837414186','38601810042',
      '38209661847','38936059725','38130885752','37186994180','36592098949','37422858593',
      '34036042268','34529402508','36457948799','35866597238','36130815518','35866578863',
      '41782178732','37238171010','23239760558','35848395942','32325265742','32153016413',
      '33496397369','31086285475','32114247697','32354980431','32755187613','43906314407',
      '45962242096','41470917405','43542950696','43361550263','34665962803','40759227727',
      '39983789097','37883716791','38737085351','37730717356','36195598214','35565036865',
      '35684308328','35445368936','33917360525','29706676599','53284608543','55031387469',
      '57019209475','53674920452','53507571525','54265019467','52476103450','55679598968',
      '54004500151','58133846644','53418667180','58630502585','57939185442','58208287837',
      '55381767541','57982450758','56896681728','51727021069','59522731339'
    )
  ),
  deal_metrics AS (
    SELECT
      b.*,
      CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END AS QTD_COMPLETUDE,
      GREATEST(
        (CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END) - b.QTD_INSTALADA,
        0
      ) AS QTD_PENDENTE,
      b.QTD_INSTALADA + b.QTD_AGENDADO AS QTD_INSTALADA_MAIS_AGENDADO,
      LEAST(
        ROUND(b.QTD_INSTALADA / NULLIF(CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END, 0), 2),
        1
      ) AS PCT_COMPLETUDE,
      LEAST(
        ROUND((b.QTD_INSTALADA + b.QTD_AGENDADO) / NULLIF(CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END, 0), 2),
        1
      ) AS PCT_COMPLETUDE_COM_AGENDADO,
      -- Elegibilidade por TIPO de deal (SEM corte de dias) -- decide o que
      -- entra na soma da empresa. Ajustado em 2026-08-11 a pedido do Luiz:
      -- "mesmo se já tiver passado [do prazo] pode trazer" -- ou seja, o dado
      -- não deve mais sumir quando o deal envelhece, só o corte de dias abaixo
      -- (DENTRO_DO_PRAZO) sinaliza se ainda dá pra completar dentro do prazo.
      CASE
        WHEN b.TIME = 'Onboarding'
          THEN b.CLASSE_DEAL LIKE '%Primeira venda%'
        WHEN b.TIME IN ('ICP', 'SMB')
          THEN b.CLASSE_DEAL NOT LIKE '%Primeira venda%'
        ELSE FALSE
      END AS ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO,
      -- Este deal, isoladamente, ainda está dentro do prazo (90 dias
      -- Onboarding / 60 dias ICP-SMB) contado da assinatura?
      CASE
        WHEN b.TIME = 'Onboarding' THEN b.DIAS_DESDE_ASSINATURA <= 90
        WHEN b.TIME IN ('ICP', 'SMB') THEN b.DIAS_DESDE_ASSINATURA <= 60
        ELSE FALSE
      END AS DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO
    FROM base_deal_filtered b
  )
  -- ---- Rodada 12: fim da CTE `q` já em nível de DEAL (não mais agregado por
  -- empresa) -- cada linha de deal_metrics já tem QTD_COMPLETUDE, QTD_INSTALADA,
  -- PCT_COMPLETUDE e DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO calculados só a
  -- partir do PRÓPRIO deal, sem window function por empresa. ----
  SELECT * FROM deal_metrics
),
-- ---- NOVO (Rodada 12, por deal -- antes era "empresa_escala" por empresa):
-- escala de nota por segmento (SMB/ICP direto pelo TIME do deal; Onboarding
-- decide pela mesma variável de potencial já usada pra classificar ICP x SMB
-- pós-90-dias). Só entram deals elegíveis por tipo (ELEGIVEL_TIPO_...) e com
-- QTD_COMPLETUDE > 0 -- equivalente ao antigo `HAVING MAX(...) > 0` da
-- agregação por empresa, mas aplicado deal a deal. ----
deal_escala AS (
  SELECT
    *,
    CASE
      WHEN TIME = 'ICP' THEN 'ICP_SCALE'
      WHEN TIME = 'SMB' THEN 'SMB_SCALE'
      WHEN TIME = 'Onboarding' AND COALESCE(GRUPO_POTENCIAL, potencial_total_da_empresa, 0) > 50 THEN 'ICP_SCALE'
      ELSE 'SMB_SCALE'
    END AS escala_nota,
    ROUND(PCT_COMPLETUDE * 100) AS pct_inteiro
  FROM q
  WHERE ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO
    AND QTD_COMPLETUDE > 0
)
-- ---- Resultado final: 1 linha por DEAL, pronto pra virar a chave
-- "completude_instalacao" do data/latest-sync.json. `deal_id` é a chave nova
-- usada pelo join em v_dashboard (via tickets_sync.deal_id); `company_id`
-- continua disponível pra referência/debug, mas não é mais a chave de join. ----
SELECT
  deal_id,
  associated_company_id AS company_id,
  TIME AS time_segmento,
  QTD_COMPLETUDE AS qtd_completude,
  QTD_INSTALADA AS qtd_instalada,
  PCT_COMPLETUDE AS pct_completude,
  GREATEST(CAST(CEIL(0.8 * QTD_COMPLETUDE) AS BIGINT) - QTD_INSTALADA, 0) AS qtd_falta_meta_80,
  DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO AS dentro_do_prazo,
  -- NOVO (Rodada 12, pedido do Luiz: "o dentro do prazo tem que trazer os
  -- dias que ainda temos, tipo dentro do prazo 10d"): dias restantes do
  -- prazo do PRÓPRIO deal (90 ou 60 menos DIAS_DESDE_ASSINATURA, conforme o
  -- segmento) -- positivo = ainda dentro do prazo, negativo = já venceu há N
  -- dias. Consistente por construção com `dentro_do_prazo` (mesmo cálculo
  -- de base) -- diferente do diasRestantes() do front-end, que hoje usa
  -- dias_aberto (idade do TICKET) como aproximação. `v_dashboard` expõe como
  -- completude_dias_restantes_prazo; o front-end já está pronto pra usar
  -- este campo assim que ele existir (ver diasRestantesPrazoCompletude() no
  -- index.html).
  CASE
    WHEN TIME = 'Onboarding' THEN 90 - DIAS_DESDE_ASSINATURA
    ELSE 60 - DIAS_DESDE_ASSINATURA
  END AS dias_restantes_prazo,
  -- Nota de Basic Value de Instalação (0-4), calculada por faixas de % DO
  -- PRÓPRIO DEAL (antes era da empresa) -- ver cabeçalho.
  CASE
    WHEN escala_nota = 'SMB_SCALE' THEN
      CASE
        WHEN pct_inteiro = 0 THEN 0
        WHEN pct_inteiro <= 75 THEN 1
        WHEN pct_inteiro <= 89 THEN 2
        WHEN pct_inteiro <= 95 THEN 3
        ELSE 4
      END
    ELSE
      CASE
        WHEN pct_inteiro = 0 THEN 0
        WHEN pct_inteiro <= 75 THEN 1
        WHEN pct_inteiro <= 79 THEN 2
        WHEN pct_inteiro <= 85 THEN 3
        ELSE 4
      END
  END AS nota_instalacao,
  -- Quantas instalações faltam pra cruzar o piso da faixa que dá nota 3
  -- (90% na escala SMB, 80% na escala ICP) -- 0 se a nota já é 3 ou 4.
  GREATEST(
    CAST(CEIL((CASE WHEN escala_nota = 'SMB_SCALE' THEN 0.90 ELSE 0.80 END) * QTD_COMPLETUDE) AS BIGINT) - QTD_INSTALADA,
    0
  ) AS qtd_falta_nota_3
FROM deal_escala
