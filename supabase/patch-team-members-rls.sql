-- ============================================================================
-- Patch: fecha vazamento de team_members para gente autenticada mas não
-- cadastrada (2026-08-10)
-- ============================================================================
-- Pergunta do Luiz: "qualquer pessoa que clicar em solicitar link vai
-- conseguir entrar? deveria ter uma validação de só enviar se foi cadastrado
-- pelo painel". Resposta curta: sim, hoje qualquer e-mail consegue completar
-- o login (o Supabase não valida domínio/cadastro no servidor -- o aviso
-- "use seu e-mail @cobli.co" é só um texto no front-end, não trava nada de
-- verdade). Mas isso sozinho não expõe tickets/MRR/Basic Value: essas
-- tabelas dependem de visible_owner_ids(), que só devolve algo se o e-mail
-- já estiver cadastrado em team_members -- pra quem não está, a função
-- devolve vazio e a pessoa só vê a tela "seu e-mail ainda não foi
-- cadastrado" com a tabela vazia.
--
-- O gap real encontrado: a policy de SELECT em team_members era
-- `auth.role() = 'authenticated'` -- ou seja, QUALQUER pessoa que
-- conseguisse logar (mesmo sem estar cadastrada) podia listar TODOS os
-- nomes/e-mails/squads/papéis do time inteiro, direto pela API REST do
-- Supabase (sem precisar passar pelo front-end). Não é dado comercial
-- (ticket/MRR/Basic Value), mas é o cadastro do time -- não deveria ser
-- público pra qualquer autenticado.
--
-- Fix: só permite SELECT em team_members pra quem já é um membro ATIVO
-- cadastrado. Usa uma função security definer (is_registered_member) em vez
-- de colocar a subquery direto na policy, porque uma policy de SELECT em
-- team_members não pode consultar team_members dentro de si mesma sem cair
-- num loop de avaliação de RLS -- a função, sendo security definer, resolve
-- isso (roda com privilégio do dono da função, ignorando RLS internamente,
-- só pra essa checagem pontual).
--
-- Idempotente: pode rodar de novo sem quebrar nada.

create or replace function is_registered_member()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from team_members
    where email = auth.jwt() ->> 'email' and active
  )
$$;

comment on function is_registered_member is
  'Usada pela RLS de team_members_select -- true só se o e-mail autenticado já é um membro ATIVO cadastrado. security definer evita recursão de RLS (a policy não pode olhar pra própria tabela que protege).';

drop policy if exists team_members_select on team_members;
create policy team_members_select on team_members
  for select using (is_registered_member());

-- Nada muda pra quem já está cadastrado: gestor_squad/gestor_geral continuam
-- vendo o cadastro completo no painel de Administração igual antes -- essa
-- policy não distingue squad, só se a pessoa é um membro ativo (isso já era
-- assim antes do patch, não é uma restrição nova pra quem já tem acesso).
-- ============================================================================
-- Reforço opcional (não incluído aqui, requer acesso ao painel do Supabase):
-- ainda é possível, hoje, completar o LOGIN (obter uma sessão válida) com um
-- e-mail que não está em team_members -- só não enxerga dado nenhum depois.
-- Pra bloquear o login em si (não só o acesso a dado), o Supabase oferece um
-- Auth Hook "Before User Created" (Authentication → Hooks, no painel) que
-- roda uma função Postgres antes de criar o usuário e pode rejeitar e-mails
-- fora de uma lista permitida. Isso é configuração de projeto (só o Luiz
-- consegue habilitar) -- posso escrever a função se ele quiser seguir por
-- esse caminho depois.
-- ============================================================================
