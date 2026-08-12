#!/usr/bin/env python3
"""
Lê os dados sincronizados (gerados pela scheduled task do Claude Cowork, que tem
acesso ao HubSpot e ao Databricks) e grava tudo no Supabase via REST (PostgREST),
usando a service_role key -- que só existe aqui, como secret do GitHub Actions,
nunca no front-end nem no repositório.

Dois formatos são aceitos (e combinados se os dois existirem):

1. `data/latest-sync.json` — um único arquivo com todas as tabelas:
   {
     "tickets": [ {...linhas de tickets_sync...} ],
     "basic_value": [ {...linhas de basic_value_snapshot...} ],
     "field_status": [ {...linhas de field_status_snapshot...} ],
     "ticket_products": [ {...linhas de ticket_products, sem "id"...} ],
     "team_members_updates": [ {...linhas de team_members (só email + hubspot_owner_id)...} ],
     "completude_instalacao": [ {...linhas de completude_instalacao_snapshot...} ],
     "esn_validacao": [ {...linhas de esn_validacao_snapshot...} ]
   }

2. `data/chunks/<tabela>-NN.json` — a mesma coisa, mas partida em vários
   arquivos menores (cada um uma lista JSON simples de linhas da tabela
   `<tabela>`), usado quando o payload é grande demais para publicar num único
   arquivo de uma vez (ex.: a primeira sincronização completa, com todos os
   tickets abertos). `<tabela>` é um destes: tickets, basic_value,
   ticket_products, field_status, team_members_updates, completude_instalacao,
   esn_validacao.
"""
import glob
import json
import os
import sys

import requests

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
SINGLE_FILE = os.path.join(DATA_DIR, "latest-sync.json")
CHUNKS_DIR = os.path.join(DATA_DIR, "chunks")

TABLE_KEYS = ["tickets", "basic_value", "ticket_products", "field_status", "team_members_updates", "completude_instalacao", "esn_validacao"]

HEADERS = {
    "apikey": SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    "Content-Type": "application/json",
    # merge-duplicates = faz upsert real (insere novo, atualiza se já existir pela PK/on_conflict)
    "Prefer": "resolution=merge-duplicates,return=minimal",
}


def load_payload() -> dict:
    payload = {k: [] for k in TABLE_KEYS}

    if os.path.exists(SINGLE_FILE):
        with open(SINGLE_FILE, encoding="utf-8") as f:
            single = json.load(f)
        for k in TABLE_KEYS:
            payload[k].extend(single.get(k, []))

    if os.path.isdir(CHUNKS_DIR):
        for k in TABLE_KEYS:
            chunk_files = sorted(glob.glob(os.path.join(CHUNKS_DIR, f"{k}-*.json")))
            for path in chunk_files:
                with open(path, encoding="utf-8") as f:
                    payload[k].extend(json.load(f))

    return payload


def fetch_all_ids(table: str, id_column: str) -> set:
    """GET paginado só da coluna de ID -- o Supabase (PostgREST) limita cada
    resposta a um teto de linhas ("Max Rows" do projeto, hoje 1000), mesma
    razão pela qual o front-end (index.html) usa fetchAllPages(). Usa o
    header Range em vez de .range() (isso aqui é a API REST crua, não o
    client JS)."""
    ids = set()
    page_size = 1000
    start = 0
    while True:
        url = f"{SUPABASE_URL}/rest/v1/{table}?select={id_column}"
        headers = {**HEADERS, "Range-Unit": "items", "Range": f"{start}-{start + page_size - 1}"}
        r = requests.get(url, headers=headers, timeout=60)
        if not r.ok:
            print(f"ERRO ao ler {table}: {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()
        page = r.json()
        ids.update(row[id_column] for row in page)
        if len(page) < page_size:
            break
        start += page_size
    return ids


# Rodada 11 (2026-08-12), pedido do Luiz: "os tickets hoje eles irão sair do
# status agendar instalação no hubs, então quando rodarmos a atualização
# geral precisamos também atualizar isso, o que mudou de status não voltar
# mais". Até aqui, upsert() só inseria/atualizava -- nunca removia --
# então um ticket que saísse de "Agendar instalação" no HubSpot continuava
# aparecendo pra sempre no dashboard, com os dados congelados da última
# sincronização em que ainda estava no status.
#
# Sobre não perder comentário/observação (mesmo pedido, na sequência): a
# tabela ticket_checks (onde ficam status_tratativa/observacao, gravados
# pelo popup de Tratativa) NÃO tem foreign key/cascade com tickets_sync --
# apagar uma linha de tickets_sync aqui NUNCA apaga o histórico de
# ticket_checks associado; a linha de ticket_checks só fica órfã (preservada,
# sem vínculo). E um ticket que ainda está em "Agendar instalação" (ou seja,
# que ainda aparece no payload desta sincronização) nunca é tocado por esta
# função -- só quem SAIU do status é removido. Ou seja: comentário de ticket
# ainda ativo nunca é apagado; comentário de ticket que saiu do status
# continua no banco (órfão), só não aparece mais atrelado a uma linha de
# tickets_sync visível no dashboard.
MIN_EXPECTED_TICKETS = 50  # ver guarda de segurança abaixo


def remove_stale_tickets(current_ticket_ids: list):
    """Remove de tickets_sync os tickets que não vieram no payload desta
    sincronização -- ou seja, que saíram de "Agendar instalação" no HubSpot
    desde a última rodada.

    Guarda de segurança: se o payload atual vier vazio ou suspeitosamente
    pequeno (< MIN_EXPECTED_TICKETS), a sincronização provavelmente falhou ou
    veio parcial (ex.: um chunk isolado, não a atualização geral) -- nesse
    caso NÃO remove nada, pra nunca arriscar apagar a base inteira por um
    payload incompleto."""
    if len(current_ticket_ids) < MIN_EXPECTED_TICKETS:
        print(
            f"tickets_sync: payload desta sincronização tem só {len(current_ticket_ids)} "
            f"ticket(s) (< {MIN_EXPECTED_TICKETS}) -- pulando a remoção de tickets que "
            "saíram do status, por segurança (pode ser sync parcial; evita apagar a base "
            "inteira por engano). Só roda numa atualização geral de verdade.",
            file=sys.stderr,
        )
        return

    existing_ids = fetch_all_ids("tickets_sync", "ticket_id")
    stale_ids = sorted(existing_ids - set(current_ticket_ids))

    if not stale_ids:
        print("tickets_sync: nenhum ticket saiu de 'Agendar instalação' desde a última sincronização")
        return

    for i in range(0, len(stale_ids), 200):
        batch = stale_ids[i : i + 200]
        ids_csv = ",".join(f'"{t}"' for t in batch)
        del_url = f"{SUPABASE_URL}/rest/v1/tickets_sync?ticket_id=in.({ids_csv})"
        r = requests.delete(del_url, headers={**HEADERS, "Prefer": "return=minimal"}, timeout=60)
        if not r.ok:
            print(f"ERRO ao remover tickets_sync órfãos: {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()
    print(f"tickets_sync: {len(stale_ids)} ticket(s) removido(s) (saíram de 'Agendar instalação'; histórico de tratativa/observação em ticket_checks preservado, sem FK/cascade)")


def upsert(table: str, rows: list, on_conflict: str, chunk_size: int = 500):
    if not rows:
        print(f"{table}: nada para gravar (0 linhas)")
        return
    url = f"{SUPABASE_URL}/rest/v1/{table}?on_conflict={on_conflict}"
    for i in range(0, len(rows), chunk_size):
        chunk = rows[i : i + chunk_size]
        r = requests.post(url, headers=HEADERS, data=json.dumps(chunk), timeout=60)
        if not r.ok:
            print(f"ERRO ao gravar em {table}: {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()
    print(f"{table}: upsert de {len(rows)} linha(s) OK")


def replace_ticket_products(rows: list):
    """ticket_products não tem uma chave natural simples (ticket_id + produto
    poderia repetir se o produto mudar de nome), então em vez de upsert por PK
    fazemos: apaga os produtos dos tickets presentes neste sync, e reinsere.
    Isso evita duplicar linhas quando um ticket muda de produto/quantidade."""
    if not rows:
        print("ticket_products: nada para gravar (0 linhas)")
        return

    ticket_ids = sorted({row["ticket_id"] for row in rows})
    # Em lotes, pra não estourar o tamanho da URL se houver muitos tickets.
    for i in range(0, len(ticket_ids), 200):
        batch = ticket_ids[i : i + 200]
        ids_csv = ",".join(f'"{t}"' for t in batch)
        del_url = f"{SUPABASE_URL}/rest/v1/ticket_products?ticket_id=in.({ids_csv})"
        del_headers = {**HEADERS, "Prefer": "return=minimal"}
        r = requests.delete(del_url, headers=del_headers, timeout=60)
        if not r.ok:
            print(f"ERRO ao limpar ticket_products: {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()

    insert_url = f"{SUPABASE_URL}/rest/v1/ticket_products"
    for i in range(0, len(rows), 500):
        chunk = rows[i : i + 500]
        r = requests.post(insert_url, headers={**HEADERS, "Prefer": "return=minimal"}, data=json.dumps(chunk), timeout=60)
        if not r.ok:
            print(f"ERRO ao inserir ticket_products: {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()
    print(f"ticket_products: {len(ticket_ids)} ticket(s), {len(rows)} linha(s) de produto gravada(s)")


def update_owner_ids(rows: list):
    """Preenche o hubspot_owner_id de pessoas já cadastradas em team_members
    (resolvido pela scheduled task via busca por e-mail no HubSpot).

    Importante: isto faz um PATCH (update), nunca um upsert/insert. Se
    fizéssemos upsert normal (POST + on_conflict=email) e a pessoa ainda não
    tivesse sido cadastrada manualmente (convite via tela de Administração ou
    INSERT direto), o Postgres tentaria criar uma linha nova só com
    email/hubspot_owner_id e quebraria na constraint not-null de
    name/squad/role (foi exatamente o erro 23502 visto em produção). Com
    PATCH, se a pessoa não existir ainda, simplesmente não atualiza nada (0
    linhas afetadas, sem erro) -- o cadastro em si continua sendo manual."""
    if not rows:
        print("team_members: nada para atualizar (0 linhas)")
        return
    updated = 0
    for row in rows:
        email = row.get("email")
        owner_id = row.get("hubspot_owner_id")
        if not email or owner_id is None:
            continue
        url = f"{SUPABASE_URL}/rest/v1/team_members?email=eq.{email}"
        r = requests.patch(
            url,
            headers={**HEADERS, "Prefer": "return=representation"},
            data=json.dumps({"hubspot_owner_id": owner_id}),
            timeout=60,
        )
        if not r.ok:
            print(f"ERRO ao atualizar team_members ({email}): {r.status_code} {r.text}", file=sys.stderr)
            r.raise_for_status()
        if r.json():
            updated += 1
    print(f"team_members: {updated}/{len(rows)} pessoa(s) já cadastrada(s) tiveram hubspot_owner_id atualizado")


def main():
    payload = load_payload()

    upsert("tickets_sync", payload["tickets"], on_conflict="ticket_id")
    remove_stale_tickets([row["ticket_id"] for row in payload["tickets"]])
    upsert("basic_value_snapshot", payload["basic_value"], on_conflict="company_id")
    upsert("field_status_snapshot", payload["field_status"], on_conflict="ordem_servico_raw")
    upsert("completude_instalacao_snapshot", payload["completude_instalacao"], on_conflict="company_id")
    upsert("esn_validacao_snapshot", payload["esn_validacao"], on_conflict="ticket_id,esn")
    replace_ticket_products(payload["ticket_products"])
    update_owner_ids(payload["team_members_updates"])

    print("Sincronização com o Supabase concluída.")


if __name__ == "__main__":
    main()
