#!/usr/bin/env python3
"""
Lê data/latest-sync.json (gerado pela scheduled task do Claude Cowork, que tem
acesso ao HubSpot e ao Databricks) e grava tudo no Supabase via REST (PostgREST),
usando a service_role key -- que só existe aqui, como secret do GitHub Actions,
nunca no front-end nem no repositório.

Formato esperado de data/latest-sync.json:
{
  "tickets": [ {...linhas de tickets_sync...} ],
  "basic_value": [ {...linhas de basic_value_snapshot...} ],
  "field_status": [ {...linhas de field_status_snapshot...} ],
  "ticket_products": [ {...linhas de ticket_products, sem "id"...} ]
}
"""
import json
import os
import sys

import requests

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DATA_FILE = os.path.join(os.path.dirname(__file__), "..", "data", "latest-sync.json")

HEADERS = {
    "apikey": SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    "Content-Type": "application/json",
    # merge-duplicates = faz upsert real (insere novo, atualiza se já existir pela PK/on_conflict)
    "Prefer": "resolution=merge-duplicates,return=minimal",
}


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
    ids_csv = ",".join(f'"{t}"' for t in ticket_ids)
    del_url = f"{SUPABASE_URL}/rest/v1/ticket_products?ticket_id=in.({ids_csv})"
    del_headers = {**HEADERS, "Prefer": "return=minimal"}
    r = requests.delete(del_url, headers=del_headers, timeout=60)
    if not r.ok:
        print(f"ERRO ao limpar ticket_products: {r.status_code} {r.text}", file=sys.stderr)
        r.raise_for_status()

    insert_url = f"{SUPABASE_URL}/rest/v1/ticket_products"
    r = requests.post(insert_url, headers={**HEADERS, "Prefer": "return=minimal"}, data=json.dumps(rows), timeout=60)
    if not r.ok:
        print(f"ERRO ao inserir ticket_products: {r.status_code} {r.text}", file=sys.stderr)
        r.raise_for_status()
    print(f"ticket_products: {len(ticket_ids)} ticket(s), {len(rows)} linha(s) de produto gravada(s)")


def main():
    with open(DATA_FILE, encoding="utf-8") as f:
        payload = json.load(f)

    upsert("tickets_sync", payload.get("tickets", []), on_conflict="ticket_id")
    upsert("basic_value_snapshot", payload.get("basic_value", []), on_conflict="company_id")
    upsert("field_status_snapshot", payload.get("field_status", []), on_conflict="ordem_servico_raw")
    replace_ticket_products(payload.get("ticket_products", []))

    print("Sincronização com o Supabase concluída.")


if __name__ == "__main__":
    main()
