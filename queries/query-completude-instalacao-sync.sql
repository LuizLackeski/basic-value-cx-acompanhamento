-- ============================================================================
-- Query: Completude de Instalação — versão de SINCRONIZAÇÃO (1 linha por empresa)
-- Gerado em 2026-08-11. Testado direto no Databricks (dados reais).
--
-- Esta é a versão usada pelo pipeline (Passo 4B do sync-runbook.md): roda no
-- Databricks, o resultado vira a chave "completude_instalacao" do
-- data/latest-sync.json, e o upsert_to_supabase.py grava em
-- completude_instalacao_snapshot (ver supabase/patch-completude-instalacao.sql).
--
-- Difere de queries/query-completude-instalacao-onboarding.sql (que era a
-- versão "debug", 1 linha por deal, filtrada só em Onboarding, no formato de
-- BI tool com measure()) -- esta aqui junta os 3 segmentos (Onboarding, ICP,
-- SMB) numa linha só por empresa, pronta pra virar JSON.
--
-- Regra de elegibilidade por TIPO (o que entra na soma de cada empresa, sem
-- corte de dias), por segmento:
--   Onboarding: só deals cujo classe_deal contém 'Primeira venda'.
--   ICP e SMB: o INVERSO -- só deals cujo classe_deal NÃO contém 'Primeira
--     venda' (Upsell/Troca/Upgrade/Downgrade).
--   Meta de instalação nos três casos: 80%.
-- Ajuste de 2026-08-11 (pedido do Luiz): o corte de 60 dias (ICP/SMB) / 90
-- dias (Onboarding) NÃO exclui mais o deal da soma -- os dados continuam
-- aparecendo mesmo depois do prazo vencer. O corte agora só alimenta o campo
-- "dentro_do_prazo" (por empresa: TRUE se ao menos 1 deal elegível por tipo
-- ainda está dentro do prazo: "ainda dá pra completar"; FALSE se todos já
-- passaram: "já passou do prazo"). Ver ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO x
-- DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO no deal_metrics abaixo.
-- Pontos em aberto (ver também query-completude-instalacao-onboarding.sql):
--   1. "vinculando o company id do ticket aberto" interpretado como agregar
--      por associated_company_id (a mesma chave usada em basic_value etc.).
--   2. Um deal com classe_deal misto (ex. "Primeira venda, Upsell") conta
--      inteiro como "Primeira venda" -- aproximação, a query não separa por
--      linha de produto dentro do deal.
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
      AND p.DATA_INICIO_ASSINATURA >= '2026-01-01'
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
  ),
  completude_empresa AS (
    SELECT
      *,
      SUM(CASE WHEN ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO THEN QTD_COMPLETUDE ELSE 0 END)
        OVER (PARTITION BY associated_company_id) AS QTD_COMPLETUDE_INSTALACAO_EMPRESA,
      SUM(CASE WHEN ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO THEN QTD_INSTALADA ELSE 0 END)
        OVER (PARTITION BY associated_company_id) AS QTD_INSTALADA_INSTALACAO_EMPRESA,
      -- Empresa ainda "dentro do prazo" pra completar = existe ao menos 1 deal
      -- elegível por tipo cujo prazo (60/90 dias) ainda não venceu. Quando
      -- TODOS os deals elegíveis já passaram do prazo, vira FALSE ("já passou").
      MAX(
        CASE
          WHEN ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO AND DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO THEN 1
          ELSE 0
        END
      ) OVER (PARTITION BY associated_company_id) AS DENTRO_DO_PRAZO_EMPRESA
    FROM deal_metrics
  )
  SELECT
    *,
    LEAST(
      ROUND(QTD_INSTALADA_INSTALACAO_EMPRESA / NULLIF(QTD_COMPLETUDE_INSTALACAO_EMPRESA, 0), 4),
      1
    ) AS PCT_COMPLETUDE_INSTALACAO,
    GREATEST(
      CAST(CEIL(0.8 * QTD_COMPLETUDE_INSTALACAO_EMPRESA) AS BIGINT) - QTD_INSTALADA_INSTALACAO_EMPRESA,
      0
    ) AS QTD_FALTA_PARA_META_80_INSTALACAO
  FROM completude_empresa
)
-- ---- Resultado final: 1 linha por empresa, pronto pra virar a chave
-- "completude_instalacao" do data/latest-sync.json ----
SELECT
  associated_company_id AS company_id,
  MAX(TIME)                              AS time_segmento,
  MAX(QTD_COMPLETUDE_INSTALACAO_EMPRESA) AS qtd_completude,
  MAX(QTD_INSTALADA_INSTALACAO_EMPRESA)  AS qtd_instalada,
  MAX(PCT_COMPLETUDE_INSTALACAO)         AS pct_completude,
  MAX(QTD_FALTA_PARA_META_80_INSTALACAO) AS qtd_falta_meta_80,
  MAX(DENTRO_DO_PRAZO_EMPRESA) = 1       AS dentro_do_prazo
FROM q
GROUP BY associated_company_id
HAVING MAX(QTD_COMPLETUDE_INSTALACAO_EMPRESA) > 0
