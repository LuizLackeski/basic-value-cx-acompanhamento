-- ============================================================================
-- Patch Rodada 15 (2026-08-27) -- contatos da empresa no popup de detalhes.
-- Rode ISTO INTEIRO de uma vez no SQL Editor do Supabase (limpe o editor
-- antes de colar, senao pode dar erro de sintaxe com texto de uma query
-- anterior ainda no editor).
-- ============================================================================

-- 1) tickets_sync -- 3 colunas novas, aditivo (nao quebra nada existente).
--    Passam a ser preenchidas pelo Job do Databricks a partir da proxima
--    sincronizacao (instalacao__cliente_nome/telefone/email do
--    gold.cubo_supply.supply_cube -- ver basic_value_icp_sync_databricks.py).
ALTER TABLE public.tickets_sync
  ADD COLUMN IF NOT EXISTS contato_nome text,
  ADD COLUMN IF NOT EXISTS contato_telefone text,
  ADD COLUMN IF NOT EXISTS contato_email text;

-- 2) v_dashboard -- expoe as 3 colunas novas pro dashboard. Mesmo padrao
--    seguro do patch de squad-por-e-mail (Rodada 14): le a definicao viva da
--    view, injeta as colunas logo depois de "t.company_id," via um replace
--    direcionado, e ABORTA sem alterar nada se esse texto nao aparecer
--    exatamente 1 vez -- nao reconstroi a view inteira na mao.
do $
declare
  old_def text;
  anchor text := 't.company_id,';
  replacement text := 't.company_id, t.contato_nome, t.contato_telefone, t.contato_email,';
  n int;
begin
  select pg_get_viewdef('public.v_dashboard'::regclass, true) into old_def;
  n := (length(old_def) - length(replace(old_def, anchor, ''))) / length(anchor);
  if n <> 1 then
    raise exception 'Esperava encontrar "%" exatamente 1 vez na view, encontrei %. Abortando sem alterar a view -- me manda o resultado de "select pg_get_viewdef(''public.v_dashboard''::regclass, true)" que eu ajusto o anchor.', anchor, n;
  end if;
  execute 'create or replace view public.v_dashboard as ' || replace(old_def, anchor, replacement);
  raise notice 'v_dashboard recriada: contato_nome/contato_telefone/contato_email agora disponiveis.';
end $;
