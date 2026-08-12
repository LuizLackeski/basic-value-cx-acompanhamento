-- ============================================================================
-- Patch: Checkbox "Agendado" (ticket_priority_ack) — Rodada 9, 2026-08-12
-- Rode este arquivo inteiro no SQL Editor do Supabase. Idempotente: pode
-- rodar de novo sem quebrar nada.
--
-- Contexto / pedido do Luiz: "o que precisamos é ter um check box para
-- marcar e ele ficar apagamento demonstrando que foi agendado, e no dia
-- seguinte não vai aparecer mais." Correção explícita dele: "o check box é
-- para todos os tickets ok, não somente os prioridades" -- ou seja, vale pra
-- TODO ticket da tabela de Tickets, sempre, independente de qualquer filtro
-- de Prioridades (ver seção 5 do doc do projeto) estar ativo.
--
-- Comportamento implementado no front-end (index.html, onAckTicket() /
-- loadDashboard()): ao marcar, grava uma linha aqui e a linha da tabela fica
-- visualmente apagada (opacity reduzida) NESTA sessão, mantendo o checkbox
-- marcado. Da próxima vez que a página carregar (reload ou dia seguinte), o
-- ticket marcado NÃO aparece mais na tabela -- marcação PERMANENTE, não um
-- snooze de 1 dia.
--
-- SUPOSIÇÃO REGISTRADA (documentar pro Luiz poder pedir ajuste): não existe
-- hoje nenhuma tela ou botão pra VER ou DESMARCAR os tickets já agendados --
-- se ele quiser esse controle (ex.: uma lista de "já agendados" separada,
-- ou reaparecer depois de X dias em vez de sumir pra sempre), isso é uma
-- rodada futura.
-- ============================================================================

create table if not exists ticket_priority_ack (
  ticket_id  text primary key,
  marked_at  timestamptz not null default now(),
  marked_by  text
);

comment on table ticket_priority_ack is
  'Checkbox "Agendado" da tabela de Tickets -- marcação permanente (não expira). Um ticket_id aqui presente é excluído de v_dashboard/state.allRows a partir do próximo carregamento (ver loadDashboard() em index.html). marked_by guarda o e-mail de quem marcou.';

alter table ticket_priority_ack enable row level security;

-- Mesma regra das outras tabelas: só quem já enxerga esse ticket via
-- tickets_sync (RLS existente, com bypass em cascata pra gestor_geral) pode
-- ler ou marcar.
drop policy if exists ticket_priority_ack_select on ticket_priority_ack;
create policy ticket_priority_ack_select on ticket_priority_ack
  for select using (
    ticket_id in (select ticket_id from tickets_sync)
  );

drop policy if exists ticket_priority_ack_insert on ticket_priority_ack;
create policy ticket_priority_ack_insert on ticket_priority_ack
  for insert with check (
    ticket_id in (select ticket_id from tickets_sync)
  );

-- ============================================================================
-- Fim do patch. Depois de rodar: o checkbox "Agendado" (coluna nova na
-- tabela de Tickets, index.html) já funciona -- não precisa de mais nenhuma
-- sincronização/patch pra isso.
-- ============================================================================
