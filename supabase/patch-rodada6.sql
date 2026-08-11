-- ============================================================================
-- Patch Rodada 6 (2026-08-11)
-- Rode este arquivo inteiro no SQL Editor do Supabase DEPOIS do schema.sql e
-- dos outros patches (patch-login-flow.sql, patch-team-members-rls.sql).
-- Idempotente: pode rodar de novo sem quebrar nada.
--
-- O que este patch faz:
--   1. Permite squad = NULL em team_members (necessário pro gestor_geral não
--      precisar mais ter uma squad marcada -- ele enxerga tudo mesmo assim).
--   2. Cria a policy de DELETE em team_members (hoje não existe nenhuma --
--      então excluir cadastro seria bloqueado por padrão pela RLS). Segue a
--      decisão do Luiz: exclusão real (delete), não soft-delete.
--   3. Endurece as policies de INSERT e UPDATE de team_members pra valer
--      também no banco (hoje só o front-end impedia gestor_squad de
--      convidar/editar gente pra outra squad ou promover a gestor_geral --
--      um gestor_squad chamando a API direto, sem passar pela tela, ainda
--      conseguiria burlar isso).
--   4. Vínculo pontual do hubspot_owner_id da Danielle Couto (squad ICP) --
--      resolve o bug em que os tickets dela ainda apareciam como "sem
--      squad" no dashboard, porque esse vínculo só é feito automaticamente
--      durante a sincronização periódica, nunca no momento do convite.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. squad vira opcional (NULL permitido) em team_members
-- ----------------------------------------------------------------------------
alter table team_members alter column squad drop not null;

do $$
declare
  c record;
begin
  -- Remove qualquer CHECK constraint existente na coluna squad (nome pode
  -- variar dependendo de como a tabela foi criada) e recria permitindo NULL.
  for c in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_attribute att on att.attrelid = rel.oid and att.attnum = any(con.conkey)
    where rel.relname = 'team_members'
      and con.contype = 'c'
      and att.attname = 'squad'
  loop
    execute format('alter table team_members drop constraint %I', c.conname);
  end loop;
end $$;

alter table team_members
  add constraint team_members_squad_check
  check (squad is null or squad in ('onboarding', 'smb', 'icp'));

comment on column team_members.squad is
  'Squad da pessoa (onboarding/smb/icp). NULL é permitido só para role = gestor_geral, que enxerga tudo e não precisa de squad própria (regra aplicada no front-end, não no banco).';

-- IMPORTANTE (testado localmente com Postgres puro antes de publicar este
-- patch): dentro do EXISTS correlacionado abaixo, "team_members.squad" e
-- "team_members.role" (qualificados com o nome da tabela) são a linha sendo
-- inserida/atualizada/excluída; SEM essa qualificação, "squad"/"role" soltos
-- seriam resolvidos para a subquery "m" (que já está no escopo), e a
-- comparação viraria sempre m.squad = m.squad / nunca role = 'colaborador'
-- quando m.role = 'gestor_squad' -- ou sempre verdadeiro, ou impossível de
-- satisfazer, dependendo do caso. Não remova a qualificação "team_members."
-- abaixo achando que é redundante.

-- ----------------------------------------------------------------------------
-- 2. Policy de DELETE em team_members (não existia nenhuma até agora)
-- ----------------------------------------------------------------------------
-- gestor_geral: pode excluir qualquer cadastro.
-- gestor_squad: só pode excluir cadastro de gente da própria squad (e não de
--   outro gestor_geral, óbvio, já que gestor_geral não tem squad pra bater).
drop policy if exists team_members_delete on team_members;
create policy team_members_delete on team_members
  for delete using (
    exists (
      select 1 from team_members m
      where m.email = auth.jwt() ->> 'email'
        and (
          m.role = 'gestor_geral'
          or (m.role = 'gestor_squad' and team_members.squad = m.squad)
        )
    )
  );

-- ----------------------------------------------------------------------------
-- 3. Policies de INSERT/UPDATE mais restritivas (endurecendo o que já era
--    regra só no front-end)
-- ----------------------------------------------------------------------------
-- INSERT (convite): gestor_geral convida qualquer papel/squad. gestor_squad só
-- pode convidar colaborador pra própria squad (não pode criar outro
-- gestor_squad/gestor_geral, nem cadastrar gente em outra squad).
drop policy if exists team_members_insert on team_members;
create policy team_members_insert on team_members
  for insert with check (
    exists (
      select 1 from team_members m
      where m.email = auth.jwt() ->> 'email'
        and (
          m.role = 'gestor_geral'
          or (m.role = 'gestor_squad' and team_members.role = 'colaborador' and team_members.squad = m.squad)
        )
    )
  );

-- UPDATE: mantém o "using" original (quem pode mexer em algum cadastro) e
-- adiciona "with check" pra travar o RESULTADO da edição. gestor_geral edita
-- qualquer coisa. gestor_squad só pode editar cadastro que continue na
-- própria squad e cujo papel não vire gestor_geral (evita promoção indevida
-- ou "roubo" de gente de outra squad via chamada direta à API).
drop policy if exists team_members_update on team_members;
create policy team_members_update on team_members
  for update
  using (
    exists (
      select 1 from team_members m
      where m.email = auth.jwt() ->> 'email' and m.role in ('gestor_squad', 'gestor_geral')
    )
  )
  with check (
    exists (
      select 1 from team_members m
      where m.email = auth.jwt() ->> 'email'
        and (
          m.role = 'gestor_geral'
          or (m.role = 'gestor_squad' and team_members.squad = m.squad and team_members.role <> 'gestor_geral')
        )
    )
  );

-- ----------------------------------------------------------------------------
-- 4. Vínculo pontual: Danielle Couto (squad ICP) -> hubspot_owner_id
-- ----------------------------------------------------------------------------
-- Bug identificado em 2026-08-11 (Rodada 7): squad do ticket só é preenchida
-- via v_dashboard quando team_members.hubspot_owner_id bate com
-- tickets_sync.owner_hubspot_id -- e esse vínculo só é feito automaticamente
-- durante a sincronização periódica (nunca no convite). Enquanto isso, os
-- tickets da Danielle (squad ICP) aparecem "sem squad".
-- ownerId confirmado no HubSpot via busca por "Couto": 199072037
-- (nome oficial no HubSpot é "Danielle", com dois L -- não "Daniele").
-- Ajuste o e-mail abaixo se não for exatamente esse o cadastrado.
do $$
declare
  n int;
begin
  update team_members
     set hubspot_owner_id = 199072037
   where name ilike '%danielle%couto%'
      or name ilike '%daniele%couto%';
  get diagnostics n = row_count;
  if n = 0 then
    raise notice 'Nenhuma linha em team_members bateu com "Danielle/Daniele Couto" -- confira o nome/e-mail cadastrado e rode o UPDATE manualmente.';
  elsif n > 1 then
    raise notice '% linhas em team_members bateram com "Danielle/Daniele Couto" -- confira se não há duplicidade de cadastro.', n;
  else
    raise notice 'hubspot_owner_id 199072037 vinculado a 1 cadastro (Danielle Couto).';
  end if;
end $$;

-- ============================================================================
-- Fim do patch. Depois de rodar: confira no dashboard (aba Administração)
-- se a Danielle aparece com "sem vínculo de tickets ainda" sumindo, e se os
-- tickets dela na aba Tickets passam a mostrar a squad ICP corretamente.
-- ============================================================================
