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
     "team_members_updates": [ {...linhas de team_members (só email + hubspot_owner_id)...} ]
   }

2. `data/chunks/<tabela>-NN.json` — a mesma coisa, mas partida em vários
   arquivos menores (cada um uma lista JSON simples de linhas da tabela
   `<tabela>`), usado quando o payload é grande demais para publicar num único
   arquivo de uma vez (ex.: a primeira sincronização completa, com todos os
   tickets abertos). `<tabela>` é um destes: tickets, basic_value,
   ticket_products, field_status, team_members_updates.
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

TABLE_KEYS = ["tickets", "basic_value", "ticket_products", "field_status", "team_members_updates"]

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


def main():
    payload = load_payload()

    upsert("tickets_sync", payload["tickets"], on_conflict="ticket_id")
    upsert("basic_value_snapshot", payload["basic_value"], on_conflict="company_id")
    upsert("field_status_snapshot", payload["field_status"], on_conflict="ordem_servico_raw")
    replace_ticket_products(payload["ticket_products"])

    # Preenche o hubspot_owner_id de pessoas recém-convidadas (resolvido pela
    # scheduled task via busca por e-mail no HubSpot). Só atualiza essa coluna,
    # não mexe em squad/papel/nome que o convite já definiu.
    upsert("team_members", payload["team_members_updates"], on_conflict="email")

    print("Sincronização com o Supabase concluída.")


if __name__ == "__main__":
    main()
