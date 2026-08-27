# Databricks notebook source
# ============================================================================
# Basic Value / ICP Dashboard — sincronização nativa no Databricks
# Consolidado em 2026-08-26 a partir do teste interativo validado ponta a
# ponta (notebook "teste_permissao_supabase"). Substitui o pipeline anterior
# (Claude Cowork -> GitHub -> GitHub Action -> Supabase) por um job nativo:
# lê direto das tabelas gold/supply_team, grava direto no Supabase via REST,
# sem LLM/OAuth interativo envolvido em cada execução.
#
# Pré-requisitos (já feitos em 2026-08-26):
#   - Secret scope "supply_team", secret "bv_icp_supabase" = a service_role
#     key do projeto Supabase (JWT puro, sem wrapper JSON).
#   - Esse secret precisa de permissão READ liberada pra identidade que vai
#     rodar o Job (hoje liberado pro usuário luiz.lackeski@cobli.co -- se o
#     Job rodar com outra identidade/service principal, liberar READ pra ela
#     também: `databricks secrets put-acl supply_team <identidade> READ`).
#   - URL do projeto Supabase (não é segredo, fica direto no código abaixo).
#
# Ordem de execução importa: tickets_sync sempre primeiro -- as outras 4
# tabelas usam os company_id/ticket_id JÁ ATUALIZADOS de tickets_sync como
# fonte da verdade pra decidir o que é "ativo" (filtro de escopo e limpeza de
# órfãos). Nunca rodar as outras tabelas com tickets_sync desatualizado.
#
# IMPORTANTE (achado em 2026-08-26): a gold.cubo_supply.supply_cube tem
# tickets cujo ticket_status/pipeline_label ficaram desatualizados -- 41 dos
# 1760 tickets em "Agendar instalação"/"Serviços" já têm closed_date
# preenchido (ou seja, já foram fechados de verdade no HubSpot, em outro
# pipeline até, mas a supply_cube não atualizou esses dois campos
# denormalizados). Por isso todo filtro de escopo abaixo inclui também
# "closed_date IS NULL" -- um ticket genuinamente em aberto nunca deveria ter
# data de fechamento preenchida.
# ============================================================================

# COMMAND ----------
import decimal
import json
import math
from datetime import datetime, timezone
from urllib.parse import quote

import numpy as np
import pandas as pd
import requests

token = dbutils.secrets.get("supply_team", "bv_icp_supabase")
SUPABASE_URL = "https://tmjmjrhgmyqamuphgdvi.supabase.co"
headers = {
    "apikey": token,
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

MIN_EXPECTED_TICKETS = 50  # guarda de segurança: nunca remover em massa se o payload vier suspeito de incompleto


def clean(v):
    """Serializa tipos que vêm do Spark/pandas e que json.dumps não entende
    de cara: NaN -> None, pandas.Timestamp -> ISO string, numpy int/float/bool
    -> tipos nativos do Python, numpy.ndarray/list -> lista recursivamente
    limpa (necessário pra colunas array do Postgres, ex. esn_list)."""
    if v is None:
        return None
    if isinstance(v, float) and math.isnan(v):
        return None
    if isinstance(v, pd.Timestamp):
        return None if pd.isna(v) else v.isoformat()
    if isinstance(v, np.integer):
        return int(v)
    if isinstance(v, np.floating):
        f = float(v)
        return None if math.isnan(f) else f
    if isinstance(v, np.bool_):
        return bool(v)
    if isinstance(v, decimal.Decimal):
        f = float(v)
        return None if math.isnan(f) else f
    if isinstance(v, (np.ndarray, list)):
        return [clean(x) for x in (v.tolist() if isinstance(v, np.ndarray) else v)]
    return v


def fetch_all_ids(table, id_column):
    """GET paginado de uma coluna só (Supabase limita a 1000 linhas por
    página -- usa o header Range pra paginar, igual o script antigo faz)."""
    ids, start = set(), 0
    while True:
        r = requests.get(
            f"{SUPABASE_URL}/rest/v1/{table}?select={id_column}",
            headers={**headers, "Range-Unit": "items", "Range": f"{start}-{start + 999}"},
        )
        r.raise_for_status()
        page = r.json()
        ids.update(row[id_column] for row in page if row.get(id_column) is not None)
        if len(page) < 1000:
            break
        start += 1000
    return ids


def upsert(table, payload, on_conflict, chunk_size=500):
    if not payload:
        print(f"{table}: nada para gravar (0 linhas)")
        return
    upsert_headers = {**headers, "Prefer": "resolution=merge-duplicates,return=minimal"}
    for i in range(0, len(payload), chunk_size):
        chunk = payload[i : i + chunk_size]
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/{table}?on_conflict={on_conflict}",
            headers=upsert_headers,
            data=json.dumps(chunk),
        )
        if not r.ok:
            print(f"ERRO no upsert de {table}:", r.status_code, r.text[:500])
            r.raise_for_status()
    print(f"{table}: upsert de {len(payload)} linha(s) OK")


def delete_by_ids(table, id_column, ids, extra_qs=""):
    ids = sorted(ids)
    for i in range(0, len(ids), 200):
        batch = ids[i : i + 200]
        ids_csv = ",".join(f'"{v}"' for v in batch)
        r = requests.delete(
            f"{SUPABASE_URL}/rest/v1/{table}?{id_column}=in.({ids_csv}){extra_qs}",
            headers={**headers, "Prefer": "return=minimal"},
        )
        if not r.ok:
            print(f"ERRO ao remover de {table}:", r.status_code, r.text[:500])
            r.raise_for_status()


# COMMAND ----------
# ============================================================================
# 1) TICKETS_SYNC -- fonte: gold.cubo_supply.supply_cube
#    IMPORTANTE: company_id vem do campo "company_id" simples da supply_cube.
#    NÃO usar "deal_associated_company_id" -- validamos em 2026-08-26 que
#    esse campo NÃO corresponde ao company_id usado em basic_value/completude
#    (0% de match, contra 98% do campo "company_id" simples).
# ============================================================================
print("=== 1) tickets_sync ===")

df_tickets_spark = spark.sql(
    """
    SELECT
      ticket_id,
      subject                                    AS subject_raw,
      company_name                               AS display_name,
      ticket_status                              AS pipeline_stage_label,
      instalacao__classe                         AS classe_instalacao,
      ticket_owner_email                         AS owner_email,
      ticket_owner_name                          AS owner_name,
      company_id,
      createdate,
      size(coalesce(instalacao__esns_processados, array())) AS esn_count,
      instalacao__esns_processados                AS esn_list,
      ticket_associated_deal_id                   AS deal_id,
      -- Rodada 15 (2026-08-27): contatos da empresa, a pedido do Luiz ("seria
      -- muito bom se conseguíssemos trazer os números de contatos da
      -- empresa, pra já facilitar o contato"). Campos por-ticket já
      -- confirmados populados em supply_cube (ver claude/rodada15... no
      -- projeto) -- exigem as colunas novas contato_nome/contato_telefone/
      -- contato_email em tickets_sync (supabase/patch-rodada15-contatos.sql).
      instalacao__cliente_nome                    AS contato_nome,
      instalacao__cliente_telefone                AS contato_telefone,
      instalacao__cliente_email                   AS contato_email
    FROM gold.cubo_supply.supply_cube
    WHERE ticket_status = 'Agendar instalação'
      AND pipeline_label = 'Serviços'
      AND closed_date IS NULL
    """
)
df_tickets = df_tickets_spark.toPandas()
df_tickets["pipeline_stage_id"] = None
df_tickets["owner_hubspot_id"] = None
df_tickets["hubspot_url"] = None
df_tickets["in_agendar_instalacao"] = True
df_tickets["synced_at"] = datetime.now(timezone.utc).isoformat()
print("tickets extraídos:", len(df_tickets))

payload_tickets = [{k: clean(v) for k, v in row.items()} for row in df_tickets.to_dict(orient="records")]
upsert("tickets_sync", payload_tickets, on_conflict="ticket_id")

current_ticket_ids = {row["ticket_id"] for row in payload_tickets}
existing_ticket_ids = fetch_all_ids("tickets_sync", "ticket_id")
stale_ticket_ids = existing_ticket_ids - current_ticket_ids

if len(current_ticket_ids) < MIN_EXPECTED_TICKETS:
    print(f"tickets_sync: payload pequeno ({len(current_ticket_ids)}) -- pulando remoção, por segurança.")
elif not stale_ticket_ids:
    print("tickets_sync: nenhum ticket para remover.")
else:
    delete_by_ids("tickets_sync", "ticket_id", stale_ticket_ids)
    print(f"tickets_sync: {len(stale_ticket_ids)} ticket(s) removido(s) (saíram de 'Agendar instalação').")

# ATIVOS = os tickets/company_ids que sobreviveram nesta rodada -- usado como
# fonte da verdade pelas 4 tabelas seguintes.
active_ticket_ids = sorted(current_ticket_ids)
active_company_ids = sorted({row["company_id"] for row in payload_tickets if row.get("company_id")})
print(f"ativos: {len(active_ticket_ids)} ticket(s), {len(active_company_ids)} empresa(s) distinta(s)")

# COMMAND ----------
# ============================================================================
# 2) TICKET_PRODUCTS -- fonte: ESN do ticket (supply_cube) cruzado com
#    supply_team.supply_db.pedido_de_entrega (Esn -> ModeloItem/ItemName).
#    Rodada 15 (2026-08-27): mapeamento reformulado a pedido do Luiz, com os
#    nomes definitivos pro dashboard (substitui o mapeamento "cru" da Rodada
#    13, que só cobria JC450/JC400AD/trava genérica e excluía FMC130/FMC150/
#    JC400/JC400P inteiramente -- esses produtos não apareciam nos chips):
#      ModeloItem 'JC400'   -> "Coblicam G1"
#      ModeloItem 'JC400P'  -> "Coblicam Cabine"
#      ModeloItem 'JC400AD' -> "Coblicam Fadiga"
#      ModeloItem 'JC450'   -> "Coblicam Multi"
#      ModeloItem 'FMC150'  -> "Rede Can" (+ "- Identificador" ou
#                              "- Trava ignição" se o ItemName tiver esse
#                              complemento; só "Rede Can" se não tiver nenhum)
#      ModeloItem 'FMC130'  -> "Identificador" ou "Trava ignição" se o
#                              ItemName tiver o complemento; "Instalado" se
#                              não tiver nenhum (mesma lógica de complemento
#                              do FMC150, mas sem o nome base "Rede Can")
#    Complementos de FMC130/FMC150 detectados por substring no ItemName
#    (case-insensitive) -- validado com dados reais em 2026-08-27 (ver
#    claude/rodada15... no projeto).
# ============================================================================
print("=== 2) ticket_products ===")

df_products_spark = spark.sql(
    """
    WITH tickets AS (
      SELECT ticket_id, explode(instalacao__esns_processados) AS esn
      FROM gold.cubo_supply.supply_cube
      WHERE ticket_status = 'Agendar instalação' AND pipeline_label = 'Serviços' AND closed_date IS NULL
    ),
    esn_produto AS (
      SELECT DISTINCT Esn, ModeloItem, ItemName
      FROM supply_team.supply_db.pedido_de_entrega
    ),
    labeled AS (
      SELECT t.ticket_id,
        CASE
          WHEN e.ModeloItem = 'JC400' THEN 'Coblicam G1'
          WHEN e.ModeloItem = 'JC400P' THEN 'Coblicam Cabine'
          WHEN e.ModeloItem = 'JC400AD' THEN 'Coblicam Fadiga'
          WHEN e.ModeloItem = 'JC450' THEN 'Coblicam Multi'
          WHEN e.ModeloItem = 'FMC150' AND lower(e.ItemName) LIKE '%identificador%' THEN 'Rede Can - Identificador'
          WHEN e.ModeloItem = 'FMC150' AND lower(e.ItemName) LIKE '%trava de ignição%' THEN 'Rede Can - Trava ignição'
          WHEN e.ModeloItem = 'FMC150' THEN 'Rede Can'
          WHEN e.ModeloItem = 'FMC130' AND lower(e.ItemName) LIKE '%identificador%' THEN 'Identificador'
          WHEN e.ModeloItem = 'FMC130' AND lower(e.ItemName) LIKE '%trava de ignição%' THEN 'Trava ignição'
          WHEN e.ModeloItem = 'FMC130' THEN 'Instalado'
          ELSE NULL
        END AS product_label
      FROM tickets t
      LEFT JOIN esn_produto e ON t.esn = e.Esn
    )
    SELECT ticket_id, product_label, count(*) AS quantity
    FROM labeled
    WHERE product_label IS NOT NULL
    GROUP BY ticket_id, product_label
    """
)
df_products = df_products_spark.toPandas()
print("linhas de produto extraídas:", len(df_products))

run_ts = datetime.now(timezone.utc).isoformat()
run_ts_encoded = quote(run_ts, safe="")
payload_products = [
    {**{k: clean(v) for k, v in row.items()}, "synced_at": run_ts} for row in df_products.to_dict(orient="records")
]
products_ticket_ids = sorted({row["ticket_id"] for row in payload_products})

if not payload_products:
    print("ticket_products: nada para gravar (0 linhas)")
else:
    for i in range(0, len(payload_products), 500):
        chunk = payload_products[i : i + 500]
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/ticket_products",
            headers={**headers, "Prefer": "return=minimal"},
            data=json.dumps(chunk),
        )
        if not r.ok:
            print("ERRO no insert de ticket_products:", r.status_code, r.text[:500])
            r.raise_for_status()
    print(f"ticket_products: INSERT de {len(payload_products)} linha(s) OK")

    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/ticket_products?select=id&synced_at=eq.{run_ts_encoded}&limit=1",
        headers={**headers, "Prefer": "count=exact", "Range": "0-0"},
    )
    inserted_count = int(r.headers.get("content-range", "0-0/0").split("/")[-1])
    print("ticket_products: linhas confirmadas com este synced_at:", inserted_count)

    if inserted_count < len(payload_products):
        print("ticket_products: AVISO -- contagem não bate, NÃO removendo nada antigo por segurança.")
    elif len(products_ticket_ids) < MIN_EXPECTED_TICKETS:
        print(f"ticket_products: payload pequeno ({len(products_ticket_ids)}) -- pulando remoção do antigo.")
    else:
        # remove as linhas antigas (synced_at anterior) só dos tickets deste payload
        for i in range(0, len(products_ticket_ids), 200):
            batch = products_ticket_ids[i : i + 200]
            ids_csv = ",".join(f'"{t}"' for t in batch)
            r = requests.delete(
                f"{SUPABASE_URL}/rest/v1/ticket_products?ticket_id=in.({ids_csv})&synced_at=neq.{run_ts_encoded}",
                headers={**headers, "Prefer": "return=minimal"},
            )
            if not r.ok:
                print("ERRO ao remover antigos de ticket_products:", r.status_code, r.text[:500])
                r.raise_for_status()
        print("ticket_products: linhas antigas removidas.")

        # remove órfãos: tickets que já não estão mais em tickets_sync
        pt_ticket_ids = fetch_all_ids("ticket_products", "ticket_id")
        orphan_ids = pt_ticket_ids - set(active_ticket_ids)
        if orphan_ids:
            delete_by_ids("ticket_products", "ticket_id", orphan_ids)
            print(f"ticket_products: {len(orphan_ids)} ticket(s) órfão(s) removido(s).")
        else:
            print("ticket_products: nenhum órfão encontrado.")

# COMMAND ----------
# ============================================================================
# 3) BASIC_VALUE_SNAPSHOT -- fonte: gold.customer_success_reports.basic_value
#    (Passo 4 do sync-runbook.md). Upsert simples por company_id, sem remoção
#    de órfão (igual o comportamento do script antigo pra essa tabela).
# ============================================================================
print("=== 3) basic_value_snapshot ===")

company_ids_df = spark.createDataFrame([(c,) for c in active_company_ids], ["company_id"])
company_ids_df.createOrReplaceTempView("active_company_ids")

df_bv_spark = spark.sql(
    """
    SELECT bv.company_id, bv.id_grupo_economico, bv.company_name, bv.event_week,
           bv.basic_value_score, bv.instalation_completeness_grade, bv.mrr, bv.csm
    FROM gold.customer_success_reports.basic_value bv
    JOIN active_company_ids a ON bv.company_id = a.company_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY bv.company_id ORDER BY bv.event_week DESC) = 1
    """
)
df_bv = df_bv_spark.toPandas()
print("empresas extraídas:", len(df_bv))

payload_bv = [{k: clean(v) for k, v in row.items()} for row in df_bv.to_dict(orient="records")]
upsert("basic_value_snapshot", payload_bv, on_conflict="company_id")

# COMMAND ----------
# ============================================================================
# 4) COMPLETUDE_INSTALACAO_SNAPSHOT -- fonte: query completa e validada em
#    queries/query-completude-instalacao-sync.sql (Passo 4B do runbook).
#    1 linha por deal_id. Upsert simples, sem remoção de órfão.
# ============================================================================
print("=== 4) completude_instalacao_snapshot ===")

df_compl_spark = spark.sql(
    """
    WITH q AS (
      WITH contratos AS (
        SELECT
          c.RAZAO_SOCIAL, c.endereco_uf, p.associated_company_id, c.status_da_empresa,
          c.fleet_size_empresa, c.potencial_total_da_empresa, p.TICKET_ASSOCIATED_DEAL_ID,
          p.DATA_INICIO_ASSINATURA,
          DATEDIFF(CURRENT_DATE, p.DATA_INICIO_ASSINATURA) AS DIAS_DESDE_ASSINATURA,
          SUM(CASE WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell') THEN p.QUANTIDADE_ALTERADOS ELSE 0 END) AS QTD_CONTRATADA_VENDA,
          SUM(CASE WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell') THEN p.MRR_TOTAL_PRODUTO ELSE 0 END) AS MRR_TOTAL,
          array_join(sort_array(collect_set(CASE WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]') THEN 'Primeira venda' ELSE p.FIN__CONFIG_TIPO END)), ', ') AS CLASSE_DEAL,
          MAX(CASE WHEN p.FIN__CONFIG_TIPO IN ('Troca', 'Upgrade', 'Downgrade') THEN 'TROCA' ELSE 'VENDA' END) AS GRUPO_DEAL,
          c.csm_name
        FROM gold.cubo_contratos.fct_contract_products p
          LEFT JOIN gold.dimensions.dim_company_info c ON p.associated_company_id = c.id
        WHERE p.PRODUCT_ID IN ('1', '3', '4', '5', '6', '8', '31', '32')
          AND p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell', 'Troca', 'Upgrade', 'Downgrade')
          AND p.DATA_INICIO_ASSINATURA >= '2024-01-01'
          AND c.status_da_empresa IN ('Onboarding', 'Ongoing')
          AND p.TICKET_ASSOCIATED_DEAL_ID NOT IN (
            SELECT TICKET_ASSOCIATED_DEAL_ID FROM gold.cubo_contratos.fct_contract_products
            WHERE PRODUCT_ID IN ('11', '12') AND FIN__CONFIG_TIPO = 'Downgrade'
            GROUP BY TICKET_ASSOCIATED_DEAL_ID HAVING SUM(QUANTIDADE_ALTERADOS) > 0
          )
        GROUP BY p.associated_company_id, p.TICKET_ASSOCIATED_DEAL_ID, p.DATA_INICIO_ASSINATURA, c.RAZAO_SOCIAL, c.endereco_uf, c.status_da_empresa, c.fleet_size_empresa, c.potencial_total_da_empresa, c.csm_name
        HAVING COUNT(DISTINCT CASE WHEN p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]', 'Upsell') THEN 'VENDA' WHEN p.FIN__CONFIG_TIPO IN ('Troca', 'Upgrade', 'Downgrade') THEN 'TROCA' END) = 1
      ),
      churn AS (
        SELECT associated_company_id, MAX(CAST(DATA_INICIO_ASSINATURA AS DATE)) AS ULTIMO_CHURN
        FROM gold.cubo_contratos.fct_contract_products WHERE FIN__CONFIG_TIPO = 'Abandono total'
        GROUP BY associated_company_id
      ),
      primeira_venda_atual AS (
        SELECT p.associated_company_id, MIN(CAST(p.DATA_INICIO_ASSINATURA AS DATE)) AS DATA_PRIMEIRA_VENDA_ATUAL
        FROM gold.cubo_contratos.fct_contract_products p
          LEFT JOIN churn c ON p.associated_company_id = c.associated_company_id
        WHERE p.FIN__CONFIG_TIPO IN ('Primeira venda', 'Primeira venda [Upsell]')
          AND CAST(p.DATA_INICIO_ASSINATURA AS DATE) >= COALESCE(c.ULTIMO_CHURN, DATE '1900-01-01')
        GROUP BY p.associated_company_id
      ),
      grupo_time AS (
        SELECT a.grupo_economico_id, MIN(pva.DATA_PRIMEIRA_VENDA_ATUAL) AS GRUPO_DATA_PRIMEIRA_VENDA, MAX(g.grupo_economico__potencial_total) AS GRUPO_POTENCIAL
        FROM gold.dimensions.dim_company_associations a
          JOIN gold.dimensions.dim_company_info ci ON a.id = ci.id AND ci.status_da_empresa IN ('Onboarding', 'Ongoing')
          JOIN primeira_venda_atual pva ON a.id = pva.associated_company_id
          LEFT JOIN gold.dimensions.dim_grupo_economico_info g ON a.grupo_economico_id = g.id
        GROUP BY a.grupo_economico_id
      ),
      envios AS (
        SELECT t.ticket_associated_deal_id, e.ESN, e.COBLIID, t.ENVIO__CLASSE
        FROM gold.cubo_supply.supply_cube t
          LEFT JOIN supply_team.supply_db.pedido_de_entrega e ON t.TICKET_ID = e.TICKETIDCRM
        WHERE t.PIPELINE_LABEL = 'Envios'
          AND t.ENVIO__CLASSE IN ('Primeira compra', 'Upsell', 'Troca', 'Upgrade', 'Downgrade')
          AND t.TICKET_STATUS NOT IN ('Envio Retornado', 'Envio Cancelado')
          AND e.ESN IS NOT NULL
          AND e.Sku NOT LIKE 'PAREM%' AND e.Sku NOT LIKE 'PAPNP%' AND e.SKU NOT LIKE 'PAPERCAMAUX%' AND e.SKU NOT LIKE 'PAPERCARTR%'
          AND e.Sku NOT IN ('PAPERCAMAUXCD','PAPERCHAVIDE','PAPERCAMAUXCI','PAPERCAMAUXCE','PAPERCARTRFID125','PAPERCARTRFID013')
          AND t.ticket_associated_deal_id IN (SELECT TICKET_ASSOCIATED_DEAL_ID FROM contratos)
      ),
      envios_u AS (
        SELECT ticket_associated_deal_id, ESN, COBLIID, ENVIO__CLASSE
        FROM (SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.ticket_associated_deal_id, e.ESN ORDER BY e.ENVIO__CLASSE) AS rn FROM envios e) x
        WHERE rn = 1
      ),
      instalacoes AS (
        SELECT env.ticket_associated_deal_id, env.ESN, env.ENVIO__CLASSE,
          CASE
            WHEN CAST(o.DATA_SERVICO AS DATE) >= con.DATA_INICIO_ASSINATURA THEN 'Instalado'
            WHEN o.DATA_SERVICO IS NULL AND d.ORDEM_DE_SERVICO IS NOT NULL THEN 'Instalado'
            ELSE 'Não Instalado'
          END AS STATUS_INSTALACAO,
          ROW_NUMBER() OVER (PARTITION BY env.ticket_associated_deal_id, env.ESN ORDER BY o.DATA_SERVICO ASC NULLS LAST) AS rn
        FROM envios_u env
          LEFT JOIN contratos con ON env.ticket_associated_deal_id = con.TICKET_ASSOCIATED_DEAL_ID
          LEFT JOIN supply_team.supply_db.dispositivos d ON env.ESN = d.ESN AND env.COBLIID = d.numero_cobli
          LEFT JOIN supply_team.supply_db.os_finalizadas o ON d.ORDEM_DE_SERVICO = o.ORDEM_DE_SERVICO
      ),
      primeira_instalacao AS (SELECT * FROM instalacoes WHERE rn = 1),
      agendados AS (
        SELECT ticket_associated_deal_id AS deal_id, SUM(instalacao__qtd_dispositivos_efetivamente_agendados) AS QTD_AGENDADO
        FROM gold.cubo_supply.supply_cube
        WHERE pipeline_label = 'Serviços' AND ticket_status = 'Aguardando tecnico instalar'
          AND instalacao__qtd_dispositivos_efetivamente_agendados > 0
          AND ticket_associated_deal_id IN (SELECT TICKET_ASSOCIATED_DEAL_ID FROM contratos)
        GROUP BY ticket_associated_deal_id
      ),
      base_deal AS (
        SELECT con.TICKET_ASSOCIATED_DEAL_ID AS deal_id, con.RAZAO_SOCIAL, con.endereco_uf, con.associated_company_id,
          con.status_da_empresa, con.fleet_size_empresa, con.potencial_total_da_empresa, con.DATA_INICIO_ASSINATURA,
          con.DIAS_DESDE_ASSINATURA, pva.DATA_PRIMEIRA_VENDA_ATUAL, gt.GRUPO_DATA_PRIMEIRA_VENDA,
          DATEDIFF(CURRENT_DATE, COALESCE(gt.GRUPO_DATA_PRIMEIRA_VENDA, pva.DATA_PRIMEIRA_VENDA_ATUAL)) AS DIAS_1A_VENDA_GRUPO,
          con.CLASSE_DEAL, con.GRUPO_DEAL, con.QTD_CONTRATADA_VENDA, con.MRR_TOTAL, con.csm_name,
          cg.grupo_economico_id, gt.GRUPO_POTENCIAL,
          CASE
            WHEN DATEDIFF(CURRENT_DATE, COALESCE(gt.GRUPO_DATA_PRIMEIRA_VENDA, pva.DATA_PRIMEIRA_VENDA_ATUAL)) <= 90 THEN 'Onboarding'
            WHEN COALESCE(gt.GRUPO_POTENCIAL, con.potencial_total_da_empresa) > 50 THEN 'ICP'
            ELSE 'SMB'
          END AS TIME,
          COUNT(DISTINCT inst.ESN) AS QTD_ENVIADA,
          COUNT(DISTINCT CASE WHEN inst.STATUS_INSTALACAO = 'Instalado' THEN inst.ESN END) AS QTD_INSTALADA,
          COALESCE(MAX(ag.QTD_AGENDADO), 0) AS QTD_AGENDADO
        FROM contratos con
          LEFT JOIN primeira_venda_atual pva ON con.associated_company_id = pva.associated_company_id
          LEFT JOIN gold.dimensions.dim_company_associations cg ON con.associated_company_id = cg.id
          LEFT JOIN grupo_time gt ON cg.grupo_economico_id = gt.grupo_economico_id
          LEFT JOIN primeira_instalacao inst ON con.TICKET_ASSOCIATED_DEAL_ID = inst.ticket_associated_deal_id
          LEFT JOIN agendados ag ON con.TICKET_ASSOCIATED_DEAL_ID = ag.deal_id
        GROUP BY con.TICKET_ASSOCIATED_DEAL_ID, con.RAZAO_SOCIAL, con.endereco_uf, con.associated_company_id,
          con.status_da_empresa, con.fleet_size_empresa, con.potencial_total_da_empresa, con.DATA_INICIO_ASSINATURA,
          con.DIAS_DESDE_ASSINATURA, pva.DATA_PRIMEIRA_VENDA_ATUAL, con.CLASSE_DEAL, con.GRUPO_DEAL, con.QTD_CONTRATADA_VENDA,
          con.MRR_TOTAL, con.csm_name, cg.grupo_economico_id, gt.GRUPO_DATA_PRIMEIRA_VENDA, gt.GRUPO_POTENCIAL
      ),
      base_deal_filtered AS (
        SELECT * FROM base_deal
        WHERE deal_id NOT IN (
          '49744884273','51088242312','47907249332','48859405420','47277935129','47662541092','42407795752','45107932311',
          '44888228389','45429497935','43937770118','44464602501','44452441377','43241121701','43739885079','43500752711',
          '43369126798','42905777020','42960493590','42973395979','42361744266','41443159393','42656861344','39265106823',
          '42252841361','37485349527','38979039274','38345043279','40792938788','40286190860','40456321868','40456958240',
          '39875827496','39988437666','39662004113','39805446740','38516913051','39995177997','39349114788','39549001221',
          '39259367226','39222010663','38847489864','39125272207','38818313555','38098101656','36837414186','38601810042',
          '38209661847','38936059725','38130885752','37186994180','36592098949','37422858593','34036042268','34529402508',
          '36457948799','35866597238','36130815518','35866578863','41782178732','37238171010','23239760558','35848395942',
          '32325265742','32153016413','33496397369','31086285475','32114247697','32354980431','32755187613','43906314407',
          '45962242096','41470917405','43542950696','43361550263','34665962803','40759227727','39983789097','37883716791',
          '38737085351','37730717356','36195598214','35565036865','35684308328','35445368936','33917360525','29706676599',
          '53284608543','55031387469','57019209475','53674920452','53507571525','54265019467','52476103450','55679598968',
          '54004500151','58133846644','53418667180','58630502585','57939185442','58208287837','55381767541','57982450758',
          '56896681728','51727021069','59522731339'
        )
      ),
      deal_metrics AS (
        SELECT b.*,
          CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END AS QTD_COMPLETUDE,
          GREATEST((CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END) - b.QTD_INSTALADA, 0) AS QTD_PENDENTE,
          b.QTD_INSTALADA + b.QTD_AGENDADO AS QTD_INSTALADA_MAIS_AGENDADO,
          LEAST(ROUND(b.QTD_INSTALADA / NULLIF(CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END, 0), 2), 1) AS PCT_COMPLETUDE,
          LEAST(ROUND((b.QTD_INSTALADA + b.QTD_AGENDADO) / NULLIF(CASE WHEN b.GRUPO_DEAL = 'TROCA' THEN b.QTD_ENVIADA ELSE b.QTD_CONTRATADA_VENDA END, 0), 2), 1) AS PCT_COMPLETUDE_COM_AGENDADO,
          CASE
            WHEN b.TIME = 'Onboarding' THEN b.CLASSE_DEAL LIKE '%Primeira venda%'
            WHEN b.TIME IN ('ICP', 'SMB') THEN b.CLASSE_DEAL NOT LIKE '%Primeira venda%'
            ELSE FALSE
          END AS ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO,
          CASE
            WHEN b.TIME = 'Onboarding' THEN b.DIAS_DESDE_ASSINATURA <= 90
            WHEN b.TIME IN ('ICP', 'SMB') THEN b.DIAS_DESDE_ASSINATURA <= 60
            ELSE FALSE
          END AS DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO
        FROM base_deal_filtered b
      )
      SELECT * FROM deal_metrics
    ),
    deal_escala AS (
      SELECT *,
        CASE
          WHEN TIME = 'ICP' THEN 'ICP_SCALE'
          WHEN TIME = 'SMB' THEN 'SMB_SCALE'
          WHEN TIME = 'Onboarding' AND COALESCE(GRUPO_POTENCIAL, potencial_total_da_empresa, 0) > 50 THEN 'ICP_SCALE'
          ELSE 'SMB_SCALE'
        END AS escala_nota,
        ROUND(PCT_COMPLETUDE * 100) AS pct_inteiro
      FROM q
      WHERE ELEGIVEL_TIPO_COMPLETUDE_INSTALACAO AND QTD_COMPLETUDE > 0
    )
    SELECT
      deal_id,
      associated_company_id AS company_id,
      TIME AS time_segmento,
      QTD_COMPLETUDE AS qtd_completude,
      QTD_INSTALADA AS qtd_instalada,
      PCT_COMPLETUDE AS pct_completude,
      GREATEST(CAST(CEIL(0.8 * QTD_COMPLETUDE) AS BIGINT) - QTD_INSTALADA, 0) AS qtd_falta_meta_80,
      DENTRO_DO_PRAZO_COMPLETUDE_INSTALACAO AS dentro_do_prazo,
      CASE WHEN TIME = 'Onboarding' THEN 90 - DIAS_DESDE_ASSINATURA ELSE 60 - DIAS_DESDE_ASSINATURA END AS dias_restantes_prazo,
      CASE
        WHEN escala_nota = 'SMB_SCALE' THEN
          CASE WHEN pct_inteiro = 0 THEN 0 WHEN pct_inteiro <= 75 THEN 1 WHEN pct_inteiro <= 89 THEN 2 WHEN pct_inteiro <= 95 THEN 3 ELSE 4 END
        ELSE
          CASE WHEN pct_inteiro = 0 THEN 0 WHEN pct_inteiro <= 75 THEN 1 WHEN pct_inteiro <= 79 THEN 2 WHEN pct_inteiro <= 85 THEN 3 ELSE 4 END
      END AS nota_instalacao,
      GREATEST(CAST(CEIL((CASE WHEN escala_nota = 'SMB_SCALE' THEN 0.90 ELSE 0.80 END) * QTD_COMPLETUDE) AS BIGINT) - QTD_INSTALADA, 0) AS qtd_falta_nota_3
    FROM deal_escala
    """
)
df_compl = df_compl_spark.toPandas()
print("deals extraídos:", len(df_compl))

payload_compl = [
    {**{k: clean(v) for k, v in row.items()}, "synced_at": datetime.now(timezone.utc).isoformat()}
    for row in df_compl.to_dict(orient="records")
]
upsert("completude_instalacao_snapshot", payload_compl, on_conflict="deal_id")

# COMMAND ----------
# ============================================================================
# 5) ESN_VALIDACAO_SNAPSHOT -- fonte: queries/query-esn-validacao-sync.sql
#    (Passo 4C do runbook). 1 linha por par (ticket_id, esn).
#    Dedup necessário: um mesmo ticket pode listar o mesmo ESN 2x na
#    propriedade do HubSpot -- sem isso o ON CONFLICT falha (Postgres não
#    aceita 2 linhas com a mesma chave de conflito no mesmo comando).
# ============================================================================
print("=== 5) esn_validacao_snapshot ===")

df_esn_spark = spark.sql(
    """
    WITH scope AS (
      SELECT ticket_id, company_id, instalacao__esns_processados
      FROM gold.cubo_supply.supply_cube
      WHERE pipeline_label = 'Serviços' AND ticket_status = 'Agendar instalação' AND closed_date IS NULL
    ),
    esn_expected AS (
      SELECT ticket_id, company_id, esn
      FROM scope
      LATERAL VIEW explode(instalacao__esns_processados) t AS esn
      WHERE company_id IS NOT NULL
        AND instalacao__esns_processados IS NOT NULL
        AND size(instalacao__esns_processados) > 0
    ),
    ticket_company AS (
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
      SELECT pr.Esn,
        pr.TicketIDCRM AS dono_ticket_id,
        tc.company_id  AS dono_company_id,
        pr.ModeloItem,
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
    ORDER BY ee.ticket_id, ee.esn
    """
)
df_esn = df_esn_spark.toPandas()
antes = len(df_esn)
df_esn = df_esn.drop_duplicates(subset=["ticket_id", "esn"], keep="first")
print(f"pares ticket/esn extraídos: {len(df_esn)} (removidas {antes - len(df_esn)} duplicata(s) de origem)")

payload_esn = [
    {**{k: clean(v) for k, v in row.items()}, "synced_at": datetime.now(timezone.utc).isoformat()}
    for row in df_esn.to_dict(orient="records")
]
upsert("esn_validacao_snapshot", payload_esn, on_conflict="ticket_id,esn")

# COMMAND ----------
print("=== Sincronização completa. ===")
