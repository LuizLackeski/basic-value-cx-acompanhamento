-- ============================================================================
-- Patch: valida cadastro ANTES de enviar o link de acesso (2026-08-10)
-- ============================================================================
-- Pedido do Luiz, na sequência do patch de RLS de team_members: em vez de
-- mandar o magic link pra qualquer e-mail @cobli.co (mesmo não cadastrado),
-- a tela de login deve primeiro checar se o e-mail já está em team_members
-- e só então enviar o link -- se não encontrar, mostra uma mensagem pedindo
-- pra solicitar acesso ao gestor, sem mandar e-mail nenhum.
--
-- Esse check precisa acontecer ANTES do usuário estar autenticado (é
-- justamente pra decidir se autentica ou não) -- então não dá pra usar uma
-- policy normal de RLS em team_members (que exige `authenticated`, e o
-- patch anterior fechou até isso pra quem não está cadastrado). A solução é
-- uma função RPC "security definer" que só devolve true/false (nunca o
-- resto da linha), liberada pro papel `anon` -- é a mesma técnica de
-- is_registered_member(), só que parametrizada por e-mail e chamável antes
-- do login.

create or replace function email_is_registered(check_email text)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from team_members
    where email = check_email and active
  )
$$;

comment on function email_is_registered is
  'Chamada pelo front-end na tela de login, ANTES de autenticar, pra checar se um e-mail já está cadastrado em team_members e ativo -- não expõe nenhum outro dado da linha (só o boolean). security definer + grant explícito pro anon, já que quem chama ainda não tem sessão nesse momento.';

grant execute on function email_is_registered(text) to anon, authenticated;

-- Idempotente: pode rodar de novo sem quebrar nada.
-- ============================================================================
