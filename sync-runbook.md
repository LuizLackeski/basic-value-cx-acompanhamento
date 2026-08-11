# Runbook de sincronização — Basic Value / ICP Dashboard

Este é o roteiro que a **scheduled task do Claude Cowork** deve seguir a cada execução.
Ele usa os conectores HubSpot e Databricks já autenticados na conta do Luiz — nenhum
token de serviço é necessário. O resultado é gravar `data/latest-sync.json` no
repositório `LuizLackeski/basic-value-cx-acompanhamento` (branch `main`), o que dispara
o GitHub Actions que grava tudo no Supabase.

> **Como publicar (atualizado 2026-08-09)**: usar o conector GitHub (MCP) conectado
> nesta conta do Claude — ferramenta `push_files` (ou `create_or_update_file`) do
> servidor `other_github` — em vez de `git push` via linha de comando. O ambiente
> sandbox do Cowork bloqueia `git`/chamadas diretas à API do GitHub feitas por shell
> para repositórios não pré-autorizados; o conector MCP passa por um caminho
> diferente (OAuth do conector) e não tem essa restrição. Só preencher a frequência
> antes de criar a scheduled task de verdade (`create_trigger`).

## Passo 1 — Status "Agendar Instalação" (confirmado pelo Luiz)
`hs_pipeline = '263640'` (Serviços) e `hs_pipeline_stage = '263641'` (Agendar Instalação) —
confirmado com o Luiz em 2026-08-09, validado batendo com o total real de tickets (1721,
muito próximo dos ~1800 esperados). Não precisa mais resolver isso dinamicamente.

Existe também o ID `238827605`, que é **outro status** (não "Agendar Instalação") — o Luiz
mencionou que vamos usá-lo depois, mas não faz parte do escopo agora.

## Passo 2 — Buscar tickets do HubSpot
Objeto: `TICKET`. Filtro: `hs_pipeline = '263640'` E `hs_pipeline_stage = <ID resolvido no passo 1>`.

Propriedades a trazer:
- `hs_object_id` (ticket_id)
- `subject`
- `createdate`
- `hs_pipeline_stage`
- `ops__instalacao__esns` (ESNs separados por `,`, `/` ou `|` — contar e listar)
- `ops__instalacao__classe` (classificação da instalação, ex. "Piloto")
- `cobler_smart_ops` (squad, critério provisório)
- Todas as propriedades cujo **nome interno** comece com `quantidade_instalacao_` e **não** contenha `calculado` — descobrir isso dinamicamente (via schema discovery), não usar uma lista fixa, pois novos produtos podem ser adicionados no HubSpot no futuro.

Para cada ticket, resolver também:
- **Empresa associada** (associação TICKET→COMPANY) → `company_id` = `hs_object_id` da Company (chave de vínculo validada com o Basic Value).
- **`owner_hubspot_id` / `owner_name` (crítico para o permissionamento — ler com atenção)**: NÃO usar o dono padrão do ticket (`hubspot_owner_id` do ticket) — usar quem está atribuído em **`cobler_smart_ops`**, que é a propriedade que define a squad/responsável real pra este fluxo. `cobler_smart_ops` é uma propriedade do tipo "usuário do HubSpot" cujo valor já É o ID do owner — **guardar esse ID diretamente** em `tickets_sync.owner_hubspot_id` (não precisa resolver nada nesse momento). Para exibir o nome na tela, resolver o nome via `search_owners` (lookup por `ownerIds`) — isso funciona bem e traz o nome.
  - **Limitação real descoberta (2026-08-09)**: a ferramenta de owners do HubSpot disponível não devolve o e-mail a partir do ID — só nome. Por isso o vínculo com `team_members` é feito por **ID de owner**, não por e-mail comparado ticket a ticket.
- **Resolução do `hubspot_owner_id` de cada pessoa cadastrada** (passo adicional, roda uma vez por pessoa nova): para cada linha de `team_members` no Supabase cujo `hubspot_owner_id` esteja nulo, buscar o owner no HubSpot usando `search_owners` com `searchQuery = <e-mail da pessoa>` (a busca por e-mail funciona, mesmo o retorno não trazendo e-mail) e gravar o `ownerId` encontrado de volta em `team_members.hubspot_owner_id` (update direto via service_role, ou registrar para o GitHub Actions gravar). Isso substitui a resolução por e-mail: convidar continua tão simples quanto antes (só e-mail/nome/squad/papel), a resolução do ID acontece nos bastidores na sincronização seguinte.

Isso resolve o ponto que o Luiz levantou: ao convidar alguém, ela já escolhe a squad (o formulário de convite já tem esse campo), e o vínculo de quais tickets aparecem pra ela é feito por um identificador exato (ID de owner do HubSpot) — não por adivinhação de nome.

## Passo 3 — Tickets que já saíram de "Agendar Instalação" mas continuam agendados
Além do filtro do Passo 2, incluir também tickets que **não** estão mais em "Agendar Instalação" mas que têm um registro correspondente na tabela da Field (Passo 5) — para eles não sumirem do dashboard quando o HubSpot avança o status. Marcar esses com `in_agendar_instalacao = false`.

## Passo 4 — Basic Value (Databricks)
```sql
SELECT company_id, id_grupo_economico, company_name, event_week,
       basic_value_score, instalation_completeness_grade, mrr, csm
FROM gold.customer_success_reports.basic_value
WHERE company_id IN (<lista de company_id dos tickets do passo 2/3>)
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY event_week DESC) = 1
```
(Se `QUALIFY` não for aceito, usar subquery com `ROW_NUMBER() OVER (...)` e filtrar por `rn = 1`.)

Sempre usar a linha da `event_week` mais recente por `company_id` — nunca uma semana antiga.

## Passo 5 — Status de agendamento na Field
```sql
SELECT ORDEM_DE_SERVICO, STATUS, PRESTADOR, CONSULTOR, DATA_AGENDADA, CLIENTE
FROM supply_team.view_metabase.view_novos_eventos_field
```
Para cada linha:
- Extrair o `ticket_id` removendo o sufixo `-N` do final de `ORDEM_DE_SERVICO` (ex.: `123456789-1` → ticket `123456789`, sufixo `1`).
- Se não houver sufixo, `suffix_num = null`.
- Guardar a linha "principal" (sem sufixo, ou o menor sufixo) para juntar no dashboard principal; guardar todas (inclusive com sufixo) para a aba de atendimentos múltiplos.

## Passo 4B — Completude de Instalação (Databricks, novo em 2026-08-11)
Query completa (testada e validada contra dados reais) em
`queries/query-completude-instalacao-sync.sql`. Roda direto no Databricks
(fonte diferente do Passo 4: `gold.cubo_contratos.fct_contract_products` +
`gold.cubo_supply.supply_cube` + `supply_team.supply_db.*`), devolve **1 linha
por empresa** (`company_id` = mesmo `hs_object_id` usado em todo o resto):

```sql
SELECT
  associated_company_id AS company_id,
  MAX(TIME)                                     AS time_segmento,
  MAX(QTD_COMPLETUDE_INSTALACAO_EMPRESA)        AS qtd_completude,
  MAX(QTD_INSTALADA_INSTALACAO_EMPRESA)         AS qtd_instalada,
  MAX(PCT_COMPLETUDE_INSTALACAO)                AS pct_completude,
  MAX(QTD_FALTA_PARA_META_80_INSTALACAO)        AS qtd_falta_meta_80
FROM q  -- CTE completa em queries/query-completude-instalacao-sync.sql
GROUP BY associated_company_id
HAVING MAX(QTD_COMPLETUDE_INSTALACAO_EMPRESA) > 0
```

Regra de elegibilidade (o que entra na soma de cada empresa), por segmento:
- **Onboarding**: só deals com `classe_deal` contendo "Primeira venda", até 90
  dias da data de início de assinatura.
- **ICP / SMB**: o inverso — só deals SEM "Primeira venda" (Upsell, Troca,
  Upgrade, Downgrade), até 60 dias da data de início de assinatura.
- Meta 80% nos três casos. Confirmado com o Luiz em 2026-08-11, mas sinalizado
  por ele como "ainda vamos ajustar" — não é regra definitiva.

## Passo 6 — Montar o JSON e publicar
Montar um objeto:
```json
{
  "tickets": [ { "ticket_id": "...", "subject_raw": "...", "display_name": "...", "pipeline_stage_id": "263641", "pipeline_stage_label": "Agendar Instalação", "classe_instalacao": "...", "owner_hubspot_id": 199072037, "owner_name": "...", "company_id": "...", "createdate": "...", "esn_count": 3, "esn_list": ["...","...","..."], "hubspot_url": "...", "in_agendar_instalacao": true } ],
  "team_members_updates": [ { "email": "pessoa@cobli.co", "hubspot_owner_id": 199072037 } ],
  "ticket_products": [ { "ticket_id": "...", "product_label": "Trava de Ignição", "quantity": 2 } ],
  "basic_value": [ { "company_id": "...", "company_name": "...", "id_grupo_economico": "...", "event_week": "...", "basic_value_score": 1.5, "instalation_completeness_grade": 2, "mrr": 1234.56, "csm": "..." } ],
  "field_status": [ { "ordem_servico_raw": "123456789-1", "ticket_id": "123456789", "suffix_num": 1, "status": "...", "prestador": "...", "consultor": "...", "data_agendada": "2026-08-10", "cliente": "..." } ],
  "completude_instalacao": [ { "company_id": "...", "time_segmento": "ICP", "qtd_completude": 73, "qtd_instalada": 4, "pct_completude": 0.0548, "qtd_falta_meta_80": 55 } ]
}
```

Importante: `completude_instalacao` usa `company_id` (`associated_company_id`
no Databricks) como chave, igual a `basic_value` — não depende de ticket
aberto no HubSpot, então roda independente dos Passos 1-3.

Para `display_name`: tentar limpar o `subject` usando o `company_name` do Basic Value quando disponível (o padrão real observado é `[SUPPLY | <motivo>] Instalação <EMPRESA> Deal ID: <id>` — extrair o nome ou substituir pelo `company_name`); se não der, manter o `subject` original.

Gravar esse objeto em `data/latest-sync.json` usando o conector GitHub (MCP,
servidor `other_github`) conectado nesta conta do Claude:
```
mcp__other_github__push_files(
  owner="LuizLackeski",
  repo="basic-value-cx-acompanhamento",
  branch="main",
  files=[{"path": "data/latest-sync.json", "content": "<JSON serializado>"}],
  message="sync: <timestamp ISO>"
)
```

Isso dispara automaticamente o GitHub Actions (`.github/workflows/sync-to-supabase.yml`), que faz o upsert de verdade no Supabase.

## Frequência
`<A DEFINIR PELO LUIZ — ex.: a cada 2h, ou 2x/dia (manhã e tarde)>`

## Pré-requisitos para ativar isto de verdade
1. Repositório GitHub do Luiz criado, com este conteúdo (`supabase/schema.sql` já rodado no Supabase). ✅ feito.
2. `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` cadastrados como *secrets* do repositório (Settings → Secrets and variables → Actions).
3. Conector GitHub conectado na conta do Claude (Configurações → Conectores) — conectado em 2026-08-09, mas ⚠️ **ainda sem permissão de escrita**: as chamadas de leitura funcionam, mas gravar arquivo dá `403 Resource not accessible by integration`. Isso indica que o GitHub App do conector foi autorizado (identidade) mas não **instalado** na conta/repositório do Luiz (são duas etapas separadas no GitHub — ver `github.com/settings/installations`). Até isso ser resolvido, a publicação de `data/latest-sync.json` / `data/chunks/*` é feita manualmente (upload direto no GitHub), não pela scheduled task.
4. A scheduled task criada via `create_trigger`, com este runbook como prompt e a frequência definida.
