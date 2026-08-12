# Backlog — Basic Value / ICP Dashboard

*Atualizado em 2026-08-12 (Rodada 11). Itens marcados ✅ já estão implementados e publicados; os demais estão só registrados, aguardando implementação ou validação.*

## ⚠️ Ações pendentes do Luiz: rodar os patches novos da Rodada 9
A Rodada 9 (ver seção própria abaixo) já está publicada no `index.html`, mas depende de duas migrações de banco novas que **ainda não foram rodadas**:
- `supabase/patch-esn-validacao.sql` — cria `esn_validacao_snapshot` + `v_esn_validacao_ticket` e recria `v_dashboard` com os campos `esn_divergente_count`/`esn_sem_match_count`/`esn_modelos_raw`/`esn_detalhe`. Sem isso, o chip "⚠ N ESN(s) a validar" e o tooltip com o modelo cru do Rastreador não aparecem (campos ficam `null`). Precisa já ter rodado `patch-completude-instalacao-nota.sql` antes (recria a mesma view).
- `supabase/patch-ticket-priority-ack.sql` — cria a tabela `ticket_priority_ack` usada pelo checkbox "Agendado". Sem isso, marcar o checkbox dá erro (RPC/tabela inexistente).
- **Publicação de dados parcial (ver dúvida/pendência abaixo)**: a query rodou pra toda a base nesta sessão (6233 pares ticket/esn, conferido contra agregado direto no Databricks: 5795 ok / 410 divergentes / 28 sem_match) e foi dividida em 32 arquivos de ~200 linhas (`data/chunks/esn_validacao-00.json` a `-31.json`) pra publicação segura (um de cada vez, com verificação byte-a-byte). **Só o chunk `-00.json` (200 dos 6233 pares) foi de fato publicado e conferido nesta sessão** -- os demais 31 chunks não foram publicados por causa do volume de transcrição manual necessário (ESNs são números de 15 dígitos, campo de alto risco de erro de transcrição se apressado). Depois de rodar os dois patches SQL acima, rodar a sincronização (Passo 4C do `sync-runbook.md`) de novo do zero -- ou publicar os chunks `-01` a `-31` que já foram gerados e validados localmente -- pra completar a cobertura de 6233 pares. Até lá, o dashboard mostra o aviso de ESN divergente só pros ~200 tickets do chunk `-00`, não pra base toda.

## ⚠️ Ação pendente do Luiz: recarregar o schema cache do PostgREST (erro `PGRST204`)
Depois de rodar os patches SQL da Rodada 9, o sync do GitHub Actions (2026-08-12) falhou com
`ERRO ao gravar em completude_instalacao_snapshot: 400 {"code":"PGRST204",...,"message":"Could not find the 'dentro_do_prazo' column of 'completude_instalacao_snapshot' in the schema cache"}`.
- A coluna `dentro_do_prazo` existe de verdade na tabela (foi criada pelo `patch-completude-instalacao-prazo.sql`, antes da Rodada 9) -- o erro é o PostgREST (a camada que vira SQL em API REST) usando um **cache de schema desatualizado**, que só se atualiza automaticamente de tempos em tempos ou quando alguém força a atualização.
- Como o script (`scripts/upsert_to_supabase.py`) para no primeiro erro (`r.raise_for_status()`), essa falha travou o restante da sincronização daquele run (o log mostra `tickets_sync`, `basic_value_snapshot` e `field_status_snapshot` OK, e para exatamente em `completude_instalacao_snapshot` -- por isso a Completude de Instalação continua em branco, o card "Empresas com MRR em risco" fica vazio, e os filtros de Prioridades não trazem nada: todos dependem de colunas que vêm dessa mesma tabela).
- **Correção**: no painel do Supabase, ir em Settings → API e clicar em "Reload schema" (ou, no SQL Editor, rodar `NOTIFY pgrst, 'reload schema';`). Depois, re-rodar a sincronização (aba Actions do repo no GitHub → workflow "Sync to Supabase" → "Run workflow", ou fazer um novo push em `data/latest-sync.json`/`data/chunks/**`).
- Isso é diferente de "faltou rodar um patch" -- os patches já foram rodados; é só o cache que precisa ser avisado que o schema mudou.

## ⚠️ Ação pendente do Luiz: rodar `supabase/patch-completude-instalacao-nota.sql`
A Rodada 8 (ver seção própria abaixo) já está publicada no `index.html` e nos dados (`data/chunks/completude_instalacao-*.json`), mas depende de uma migração de banco que **ainda não foi rodada**. Sem isso, `completude_nota_instalacao` / `completude_qtd_falta_nota_3` aparecem como `null` no dashboard (célula de Instalação some) e `mrr_status` continua calculado do jeito antigo (`basic_value_score`).
- Rode `supabase/patch-completude-instalacao-nota.sql` inteiro no SQL Editor do Supabase (idempotente, pode rodar mais de uma vez sem problema). Precisa já ter rodado `patch-completude-instalacao.sql` e `patch-completude-instalacao-prazo.sql` antes.

## ⚠️ Ação pendente do Luiz: rodar `supabase/patch-rodada6.sql`
A Rodada 6 (lista abaixo) já está publicada no `index.html`, mas depende de uma migração de banco que **ainda não foi rodada**. Sem isso, convidar/editar um gestor_geral vai dar erro (squad ainda é obrigatória no banco) e as regras novas de permissão (insert/update/delete de `team_members`) ainda não estarão em vigor.
- Rode `supabase/patch-rodada6.sql` inteiro no SQL Editor do Supabase (idempotente, pode rodar mais de uma vez sem problema).
- Esse mesmo patch já inclui o vínculo pontual do `hubspot_owner_id` da Danielle Couto (199072037) -- ver item 8 abaixo.

## ✅ Rodada 11 (2026-08-12) — coluna Agendado, tratativa em popup, login novo, ajustes de coluna e sincronização
*Lista de 8 pontos passada pelo Luiz depois de testar a Rodada 10 (2 prints da tabela de Tickets + texto). Commits no repo `LuizLackeski/basic-value-cx-acompanhamento`, branch `main`: `a04b8f9` (`index.html`), `0e48ecd` (`scripts/upsert_to_supabase.py`).*

### 1. ✅ Coluna "Agendado" órfã removida da tabela
- O `<th>Agendado</th>` do cabeçalho não tinha `<td>` correspondente no corpo da tabela (o checkbox real já mora na primeira coluna sem título) -- por isso aparecia uma coluna "AGENDADO" vazia nos prints do Luiz. `<th>` órfão removido; o checkbox cinza continua exatamente como estava.

### 2. ✅ Sincronização geral agora remove tickets que saíram de "Agendar instalação"
- `scripts/upsert_to_supabase.py`: nova função `remove_stale_tickets()`, chamada logo depois do upsert de `tickets_sync` em `main()`. Compara os `ticket_id` que vieram nesta sincronização contra os que já existem em `tickets_sync` no Supabase (busca paginada) e apaga os que não vieram mais -- ou seja, que saíram do status no HubSpot.
- **Guarda de segurança**: se o payload desta sincronização tiver menos de 50 tickets (`MIN_EXPECTED_TICKETS`), a remoção é pulada e um aviso é impresso no log -- protege contra apagar a base inteira por causa de um sync parcial/com erro (ex.: um chunk isolado, não a atualização geral).
- **Comentário/observação preservado**: `ticket_checks` (onde ficam `status_tratativa`/`observacao`, gravados pelo popup de Tratativa) não tem foreign key/cascade com `tickets_sync` -- confirmado no schema. Então apagar uma linha de `tickets_sync` nunca apaga o histórico de `ticket_checks`; ele só fica órfão, preservado no banco. E um ticket que ainda está em "Agendar instalação" (ainda presente no payload) nunca é tocado por esta função -- então comentário de ticket ainda ativo nunca corre risco.
- **Ainda não testado contra uma sincronização real** (a próxima "atualização geral" combinada com o Luiz no ponto 8 da lista vai ser o primeiro teste de ponta a ponta). Ver `remove_stale_tickets()` no código pra detalhe do guard/lógica.

### 3. ✅ Tratativa em popup (antes era select+textarea inline na tabela)
- Nova coluna "Tratativa" na tabela agora só mostra um indicador clicável (badge do status, "com observação" ou "Clique p/ observação do agendamento") -- clicar em qualquer parte da célula (`.tratativa-trigger`, `openTratativaModal(ticketId)`) abre um popup (`#tratativa-modal-overlay`) com o select de status + textarea de observação, e um botão Salvar (`saveTratativaModal()`) que grava os dois campos juntos em `ticket_checks` (via `saveTratativa()`, reaproveitada). Fecha clicando fora do card ou no botão Cancelar.
- Libera espaço horizontal na tabela, como pedido.

### 4. ✅ Login redesenhado — Google + e-mail/senha + "esqueceu a senha"
- Tela de login trocada: botão "Entrar com Google" (`loginWithGoogle()`, `signInWithOAuth`) em destaque, depois campos de e-mail + senha (`loginWithPassword()`, `signInWithPassword`) pra quem é de fora da Cobli (ou qualquer um que já tenha senha), e um link "Esqueceu a senha? / Primeiro acesso com senha" (`sendPasswordReset()`, `resetPasswordForEmail`) -- valida o cadastro (`email_is_registered`) antes de mandar o link, igual ao fluxo antigo do magic link.
- `sendMagicLink()` (o fluxo antigo) ficou no código, só não é mais chamado pela UI -- reversível se precisar.
- **"Entrar com Google" só funciona de fato depois que o Luiz configurar o provider Google no painel do Supabase** (Authentication → Providers) -- até lá dá erro "provider not enabled" (inofensivo, só quem clicar vê).
- **Resposta à dúvida do Luiz** ("os usuários já cadastrados precisarão ser excluídos e cadastrados de novo, para que tenha a senha?"): **não.** `resetPasswordForEmail` funciona igual pra quem nunca teve senha (só usava magic link) e pra quem já tem senha e esqueceu -- é ao mesmo tempo o fluxo de "esqueci a senha" e de "primeiro acesso com senha". Ninguém precisa ser excluído/recriado.

### 5. Aba "Evolução B.V." buscar do banco em vez dos tickets abertos atuais — registrado, não implementado
- Pedido do Luiz: a aba hoje deriva a distribuição por grau a partir de `state.allRows` (tickets abertos agora, via `distinctCompanies`/`instalation_completeness_grade`) -- ele quer trocar pra vir do banco/tabelas, já pensando em capturar saída E entrada de empresas ao longo do tempo (hoje `bv_grade_snapshots` já registra snapshots diários/semanais, mas a leitura ao vivo da aba ainda usa os tickets abertos, não uma tabela histórica própria por empresa).
- Luiz pediu explicitamente pra **não fazer agora** ("mas não agora acho, preciso usar") -- só registrado aqui como próximo passo.

### 6. ✅ Colunas reorganizadas: nome truncado + completude com dias restantes
- **Cliente**: nome truncado com "..." (`.client-name`, `max-width: 220px` + `text-overflow: ellipsis`) -- nome completo continua disponível no tooltip (`title`). Ex.: "Cattani Transporte..." em vez do nome inteiro espremendo a linha.
- **Compl. instalação**: `completudeInstalacaoHtml()` reescrita pra trazer a quantidade de dias que falta pro prazo de 60/90 dias (reaproveita `diasRestantes()`, já usada nos filtros de Prioridade). Formato: 1ª linha "10% | faltam 2 p/ 80%"; 2ª linha "dentro do prazo · faltam N dia(s)" quando ainda dá tempo, ou só "prazo encerrado" (sem contagem de dias, que já seria negativa) quando já venceu.
- Como as colunas "Agendado" e "Tratativa" (inline) saíram/mudaram (pontos 1 e 3), sobrou mais espaço horizontal pras colunas que ficaram.

### 7. ✅ Busca da barra lateral: botão de limpar + sem scroll horizontal
- Campo de busca (Ticket/Cliente/etc.) ganhou um "×" (`.search-clear-btn`, `clearSearch()`) que só aparece quando há texto digitado, pra limpar a busca com um clique.
- **Causa raiz do scroll horizontal indevido na sidebar**: `.sidebar-content` tinha `overflow-y: auto` sem `overflow-x` definido -- pela spec de CSS, deixar um eixo non-visible sem setar o outro faz o navegador computar `overflow-x` como `auto` também, então aparecia uma barrinha de rolagem lateral mesmo sem conteúdo mais largo que a sidebar. Corrigido com `overflow-x: hidden` explícito (removido também um `min-width: 216px` que apertava a margem do scrollbar vertical). Tamanho da sidebar não mudou.

### 8. Alinhar sobre a atualização/sincronização, pra testar tudo junto — combinado, ainda não feito
- Luiz pediu pra alinhar depois de tudo isso publicado, antes de rodar a sincronização geral de teste (que vai ser o primeiro teste real da remoção de tickets do ponto 2). Ver próximos passos.

### Verificação feita antes de publicar
- `node --check` no bloco `<script>` extraído do `index.html` -- sintaxe OK.
- Checagem de balanceamento de tags (`<th>`/`</th>`, `<main>`/`</main>`) -- duas discrepâncias aparentes investigadas e confirmadas como falso positivo de um contador ingênuo (contava `<th>`/`<main>` mencionados dentro de comentários de código/CSS, não markup real); tags reais conferidas uma a uma, balanceadas.
- `python3 -m py_compile` em `scripts/upsert_to_supabase.py` -- sintaxe OK.
- `git diff` revisado linha a linha nos dois arquivos antes de publicar; cada um publicado e conferido byte-a-byte (`get_file_contents` + diff/md5sum) imediatamente depois.

## ✅ Rodada 9 (2026-08-12) — implementada e publicada no `index.html`
*Combinado com o Luiz na noite de 2026-08-11, rodado às 07h BRT de 2026-08-12 (scheduled task agendada, ver `claude/pendencias-2026-08-11-para-7h.md` no Projects). Commits no repo `LuizLackeski/basic-value-cx-acompanhamento`, branch `main` -- ver lista ao final desta seção.*

### 1. ✅ Validação de ESN da propriedade
- Cruza o ESN esperado por empresa (`gold.cubo_supply.supply_cube.instalacao__esns_processados`, via `company_id`/`ticket_id`) contra `supply_team.supply_db.pedido_de_entrega` (`Esn`, `TicketIDCRM`, `ModeloItem`, `ItemName`, `CreatedAt`), usando a heurística validada na sessão anterior (linha mais recente por ESN via `ROW_NUMBER() OVER (PARTITION BY Esn ORDER BY CreatedAt DESC) = 1` = "dono atual").
- Rodado pra toda a base em escopo do dashboard (pipeline "Serviços" / status "Agendar instalação"): **6233 pares (ticket_id, esn) em 1742 tickets -- 5795 ok / 410 divergentes / 28 sem_match**.
- `ModeloItem` trazido CRU (ex.: FMC130, JC400), sem mapear pra nome amigável -- decisão do Luiz ("por enquanto tra só o modelo, depois ajusto os nomes com mais tempo").
- Novo `supabase/patch-esn-validacao.sql` (tabela `esn_validacao_snapshot`, view `v_esn_validacao_ticket`, `v_dashboard` recriada com os campos novos), nova query `queries/query-esn-validacao-sync.sql`. Dados divididos em 32 chunks (`data/chunks/esn_validacao-00.json` a `-31.json`, ~200 pares cada) -- **só o chunk `-00` foi publicado nesta sessão** (ver pendência no topo deste arquivo); completar a publicação dos chunks `-01` a `-31` (ou rodar a sincronização de novo) fica como próximo passo.
- **UI**: chip de aviso "⚠ N ESN(s) a validar" ao lado do chip "Rastreador" quando há ESN divergente/sem_match, com tooltip listando ESN + ModeloItem + status; o próprio chip "Rastreador" ganhou tooltip com os modelos crus.
- **Pendência do Luiz**: rodar `supabase/patch-esn-validacao.sql` no Supabase (ver aviso no topo deste arquivo).

### 2. ✅ Redesign de layout — Opção A (sidebar)
- Abas (Tickets / Evolução B.V. / Administração) e filtros (busca, squad, gestor, responsável, Prioridades) movidos para uma barra lateral esquerda recolhível (`#sidebar`, `toggleSidebar()`).
- **Os 4 cards de indicadores reais (`#kpi-row`) e a linha de distribuição por Basic Value (`#grade-row`, `renderGradeDistribution`) continuam EXATAMENTE como estavam** -- mesma renderização JS, só realocados pro topo do conteúdo central (não pra dentro da sidebar) -- correção combinada com o Luiz sobre o mockup anterior, que tinha inventado cards simplificados e esquecido a linha de distribuição.
- `switchTab`, `onSearchChange`, `onGestorFilterChange`, `onSquadFilterChange`, filtro de Responsável e `toggleKpiBlock` preservados sem mudança de lógica -- só o HTML ao redor mudou.
- Paleta/fonte reais da Cobli mantidas (nenhuma mudança de tokens de cor/fonte nesta rodada, fora a correção do item 3 abaixo).

### 3. ✅ Cores do backlog — paleta de status revertida
- `.grade-pill.g0`-`.g4`: revertido pra cor de status (risco/aviso/ok), CSS exato do commit `01c179608ade3b12ca7c414ea4a86751ca82a09d` (antes da Rodada 6).
- `EVO_RAMP` (gráfico de Evolução B.V.): passou a usar essa MESMA paleta de status (g4=`#0E7D5F`, g3=`#3F7D69`, g2=`#B7791F`, g1=`#A3652E`, g0=`#C7362C`, sem_dado=`#8288A3`) -- não é revert (o gráfico nunca teve essa paleta), é aplicação nova, como pedido pelo Luiz. Resolve a seção "Reverter a paleta única de B.V." registrada abaixo (agora ✅).

### 4. ✅ Removida a aba "Atendimentos múltiplos" e o status da Field
- Aba removida da navegação/sidebar (`switchTab` não aceita mais `"multiplos"`). `loadMultiplos()`/`v_atendimentos_multiplos` mantidos no código, só inacessíveis -- reversível, sem apagar nada.
- Exibição do "status da Field" (`field_status`/`prestador`/`consultor`/`data_agendada`) escondida na UI via flag `SHOW_FIELD_STATUS = false` (reversível trocando pra `true`) -- schema/dados/query no Supabase **não foram tocados**.
- **Dúvida em aberto na Rodada 9, resolvida na Rodada 10 (2026-08-12)**: o KPI "Já agendados na Field" usava `field_status` internamente pra calcular a contagem. O Luiz confirmou: "o card já agendado na field pode excluir pq não temos mais ele" -- o card foi **removido** de `renderKpis()` (ver Rodada 10 abaixo). `field_status`/`prestador`/`consultor`/`data_agendada` continuam existindo em `v_dashboard` (nada foi apagado no schema/dados) -- só não alimentam mais nenhum card.

### 5. ✅ Filtros "Prioridades" hierárquicos + checkbox "Agendado"
- Dois pills mutuamente exclusivos na sidebar: "Completude de Instalação" e "Basic Value". Nenhum selecionado = comportamento normal.
- **Completude de Instalação**: filtro obrigatório sempre aplicado (`completude_dentro_do_prazo = true` -- tickets vencidos NUNCA aparecem aqui, regra confirmada pelo Luiz na correção final do pedido). Sub-opções "Quantidade que falta" (1 a 4 padrão / 5 a 10 / 11 a 15 / 16+) e "Dias pra vencer o prazo" (sem opção "Vencido", removida a pedido dele; padrão ordena por dias restantes crescente; faixas de 1 dia a 31+ dias).
- **Basic Value**: sem corte de prazo (confirmado: "o basic vale não tem expiração pode trazer todos"). Sub-opções "Quantidade que falta pra nota 3" (1 a 5 padrão / 6 a 10 / 11 a 15 / 16+) e "MRR" (percentis P50/P75/P90 calculados no cliente a partir dos dados reais carregados -- Todos / Acima da mediana / Top 25% / Top 10% -- nunca uma faixa fixa em R$ chutada).
- Faixas de quantidade/dias documentadas no código como ponto de partida ajustável.
- **Checkbox "Agendado"**: coluna nova em TODA linha da tabela de Tickets, sempre visível, independente de qualquer filtro de Prioridade (correção explícita do Luiz: "o check box é para todos os tickets ok, não somente os prioridades"). Ao marcar, grava em `ticket_priority_ack` (novo, `supabase/patch-ticket-priority-ack.sql`) e a linha fica visualmente apagada nesta sessão; da próxima carga em diante, o ticket marcado não aparece mais (marcação permanente, não snooze de 1 dia).
- **Suposição registrada pro Luiz poder pedir ajuste**: não existe hoje nenhum jeito de ver ou desmarcar os tickets já agendados -- se ele quiser esse controle, é uma rodada futura.
- **Pendência do Luiz**: rodar `supabase/patch-ticket-priority-ack.sql` no Supabase (ver aviso no topo deste arquivo).

### Verificação feita antes de publicar
- `node --check` no bloco `<script>` extraído do `index.html` publicado -- sintaxe OK.
- Checagem programática de balanceamento de tags do HTML (abertura/fechamento) -- OK.
- Logo/SVG da marca conferido byte-a-byte contra a versão publicada antes desta rodada -- idêntico (nenhuma edição tocou essa área, aprendizado da Rodada 8 sobre corrupção de transcrição).
- Cada arquivo (`index.html`, o chunk `-00` de `esn_validacao`, os dois patches SQL novos, `queries/query-esn-validacao-sync.sql`, `scripts/upsert_to_supabase.py`, este `backlog.md` e o `sync-runbook.md`) publicado **um de cada vez**, com `get_file_contents` + diff/md5sum byte-a-byte imediatamente depois, antes de seguir pro próximo.
- Query de validação de ESN conferida cruzando o agregado do Databricks (`GROUP BY esn_status`) contra o CSV local antes de gerar os chunks -- bateu exato (5795/410/28).

## ✅ Rodada 10 (2026-08-12) — remoção do card "Já agendados na Field" + correção de incidente de publicação
*Pedido do Luiz, feito depois de testar a Rodada 9 e mandar prints: "o card já agendado na field pode excluir pq não temos mais ele". Commits no repo `LuizLackeski/basic-value-cx-acompanhamento`, branch `main`.*

- **KPI "Já agendados na Field" removido** de `renderKpis()` -- o bloco `.kpi-card` correspondente saiu do HTML gerado, e a variável `agendados` (que contava `field_status`) saiu da função. `#kpi-row` agora mostra só 3 cards: "Tickets em aberto", "Empresas com MRR em risco", "Tempo médio em aberto". Nada mudou no schema/dados (`field_status_snapshot` continua sincronizando normal, só não alimenta mais nenhum card na UI) -- resolve a dúvida em aberto da Rodada 9 (item 4 acima).
- **Incidente de publicação corrigido nesta sessão**: uma tentativa de publicar essa mudança (commit `04cfda9`) gravou por engano o texto literal `PLACEHOLDER` como conteúdo inteiro do `index.html`, tirando o dashboard do ar por um período. Identificado e corrigido no commit seguinte (`969b48d`), que restaura o conteúdo correto (já incluindo a remoção do card) -- conferido byte-a-byte (`get_file_contents` + md5sum) contra a versão local antes e depois de publicar. Card incluído no reforço do aprendizado já registrado neste arquivo: nunca gravar payload de teste/placeholder num arquivo de produção sem antes validar com um SHA propositalmente inválido (que rejeita a escrita) -- neste caso a etapa seguinte, já com o SHA real, usou o texto errado por engano.
- **Diagnóstico do erro de sincronização reportado pelo Luiz** (`PGRST204` / "dentro_do_prazo... not found in schema cache"): ver aviso no topo deste arquivo -- é cache de schema do PostgREST desatualizado, não patch faltando.

## ✅ Completude de Instalação: patch SQL rodado + primeira sincronização feita (2026-08-11)
O Luiz já rodou `supabase/patch-completude-instalacao.sql` no Supabase. Em seguida, a sincronização (Passo 4B do `sync-runbook.md`) foi executada manualmente nesta sessão: a query `queries/query-completude-instalacao-sync.sql` rodou no Databricks (448 empresas elegíveis), os resultados foram publicados em `data/chunks/completude_instalacao-00.json` a `-04.json` (commit `61edca7`), o que deve disparar o `sync-to-supabase.yml` e popular `completude_instalacao_snapshot` de verdade.
- Verificação: soma/contagens do JSON publicado batem exatamente com a agregação rodada direto no Databricks (448 linhas, 4338/2035/1803 nos totais de completude/instalada/falta, 204 SMB / 125 ICP / 119 Onboarding).
- Não foi possível confirmar diretamente no Supabase (sem acesso de rede a partir desta sessão) nem checar o status do GitHub Actions -- se a coluna "Compl. instalação" não aparecer no dashboard depois de recarregar, o próximo passo é olhar a aba Actions do repo pra ver se o workflow rodou com erro.

## ✅ Completude de Instalação (2026-08-11) — implementada e publicada no `index.html`
*Commits no repo `LuizLackeski/basic-value-cx-acompanhamento`, branch `main`: `6923531` (`supabase/patch-completude-instalacao.sql` + `scripts/upsert_to_supabase.py`), `b4fffe9` (`sync-runbook.md`), `4fa7b06` (queries), `52d3ef4` (`index.html`, versão final corrigida). Depende do patch SQL acima ser rodado.*

Nova métrica por empresa: % de instalações já concluídas em relação ao que é elegível pra ela, e quantas faltam pra bater a meta de 80%. Aparece como uma linha extra ("Compl. instalação: X% (faltam N p/ 80%)") no card de Basic Value de cada linha da tabela de Tickets.

- **Elegibilidade por segmento** (regra confirmada com o Luiz em 2026-08-11, mas explicitamente sinalizada por ele como "ainda vamos ajustar" -- não é definitiva):
  - **Onboarding**: só deals com `classe_deal` contendo "Primeira venda", dentro de até 90 dias da data de início de assinatura.
  - **ICP e SMB**: o inverso -- só deals SEM "Primeira venda" (Upsell/Troca/Upgrade/Downgrade), dentro de até 60 dias da data de início de assinatura.
  - Meta de 80% de instalação nos três casos.
- **Cálculo**: feito por empresa (`company_id` = `associated_company_id` no Databricks = mesmo `hs_object_id` usado no resto do dashboard), não por deal -- soma o contratado e o instalado só dos deals elegíveis, calcula o %, e quantas faltam pra bater 80% (`GREATEST(CEIL(0.8 * contratado) - instalado, 0)`).
- **Pipeline**: nova query (`queries/query-completude-instalacao-sync.sql`, fonte `gold.cubo_contratos.fct_contract_products` + `gold.cubo_supply.supply_cube` + `supply_team.supply_db.*`) roda no Databricks como Passo 4B do `sync-runbook.md`, independente dos tickets abertos no HubSpot. Nova tabela `completude_instalacao_snapshot` no Supabase (mesmo padrão de RLS de `basic_value_snapshot`), nova chave `completude_instalacao` no JSON de sincronização, `v_dashboard` recriada com os 5 campos novos.
- **Validado**: query testada contra dados reais do Databricks (448 empresas elegíveis, ex. TRACBEL AGRO: 73 contratado / 4 instalado = 5,48%, faltam 55 pra bater 80%); patch SQL testado num Postgres local simulando RLS de usuário permitido e bloqueado; função JS `completudeInstalacaoHtml` testada isoladamente (5 casos: sem dado, zero, baixo/médio/alto %, meta batida).
- **Status (2026-08-11)**: patch SQL rodado pelo Luiz + primeira sincronização real feita (ver seção acima) -- 448 empresas publicadas em `data/chunks/completude_instalacao-*.json`, commit `61edca7`. Falta só confirmar visualmente no dashboard depois do Actions processar. A coluna Basic Value (BV) equivalente foi propositalmente deixada pra depois, a pedido do próprio Luiz ("um de cada vez").

## ✅ Rodada 8 (2026-08-11) — nota de instalação (0-4) recalculada + comparativo p/ nota 3
*Commits no repo `LuizLackeski/basic-value-cx-acompanhamento`, branch `main`: chunks `data/chunks/completude_instalacao-00.json` a `-10.json` (11 commits, um por chunk, todos "Rodada 8: chunk NN com nota_instalacao/qtd_falta_nota_3"), `index.html` (commit `44012477`, com fix de uma corrupção de transcrição do commit anterior `703175e` — ver nota de verificação abaixo), `queries/query-completude-instalacao-sync.sql` (commit `0f0f81e`), `supabase/patch-completude-instalacao-nota.sql` (commit `d1875b6`). Depende do patch SQL acima ser rodado.*

Pedido do Luiz: no card de Basic Value da tabela de Tickets, tirar a linha "Geral" pra SMB e ICP e deixar só "Instalação" — no lugar do "Geral", mostrar quanto falta pra bater o mínimo de nota 3. Onboarding mantém as duas (Geral + Instalação) mais o mesmo comparativo.

- **Nota recalculada do zero** (decisão confirmada com o Luiz via pergunta de esclarecimento): em vez de reaproveitar `instalation_completeness_grade` (Databricks, que tinha muita empresa sem dado), a nota de 0 a 4 agora é calculada direto a partir do `pct_completude` (qtd_instalada/qtd_completude) já existente na Completude de Instalação — resolve o problema de cobertura.
- **Escala por segmento** (regra dada pelo Luiz):
  - **SMB**: 0% = 0 · até 75% = 1 · 76-89% = 2 · 90-95% = 3 · acima de 95% = 4.
  - **ICP**: 0% = 0 · até 75% = 1 · 76-79% = 2 · 80-85% = 3 · acima de 85% = 4.
  - **Onboarding**: usa a escala de SMB se o potencial da empresa for ≤50, ou a escala de ICP se >50 (mesma variável de potencial já usada em outros pontos da query).
- **Comparativo mostrado** (decisão confirmada): "faltam N instalações p/ nota 3" — quantidade absoluta, não percentual. Calculado como `GREATEST(CEIL(limiar_nota_3 * qtd_completude) - qtd_instalada, 0)`, com `limiar_nota_3` = 90% (SMB) ou 80% (ICP) conforme a escala aplicada à empresa.
- **`mrr_status` ("em risco") rebaseado** (decisão confirmada): passa a usar `nota_instalacao < 3` para **todos** os segmentos (SMB, ICP e Onboarding) — antes usava só `basic_value_score`, o que só fazia sentido pra Onboarding. Empresa sem dado de completude (nota_instalacao null) cai em `mrr_status = 'ok'` por omissão (comparação `null < 3` é indefinida em SQL) — não é uma decisão de negócio explícita, é o comportamento padrão; revisitar se isso mascarar risco real.
- **Pipeline**: `queries/query-completude-instalacao-sync.sql` ganhou duas novas CTEs (`empresa_resumo` com o campo `potencial_empresa`, e `empresa_escala` decidindo `SMB_SCALE`/`ICP_SCALE`) e as colunas `nota_instalacao` / `qtd_falta_nota_3` no SELECT final. `completude_instalacao_snapshot` ganha as mesmas duas colunas; `v_dashboard` expõe como `completude_nota_instalacao` / `completude_qtd_falta_nota_3` (patch `supabase/patch-completude-instalacao-nota.sql`).
- **`index.html`**: nova função `basicValueCellHtml(row, riskBadge)` monta a célula (Instalação + comparativo, mais Geral+badge só se Onboarding); a ordenação da coluna de instalação passou a usar `completude_nota_instalacao` em vez de `instalation_completeness_grade`.
- **Escopo explicitamente NÃO alterado nesta rodada** (sinalizado com comentário no próprio `index.html`, perto de `GRADE_ORDER`): o pill de distribuição "Empresas por Basic Value de instalação" e o snapshot de evolução (`maybeCaptureSnapshotIfGestorGeral`) continuam usando `instalation_completeness_grade` (Databricks) — migrar isso fica pra uma rodada futura, não foi pedido agora.
- **Validado nesta sessão**: os 1027 registros de `completude_instalacao_full` (query rodada no Databricks) foram conferidos contra uma agregação independente antes de virar os 11 chunks JSON (contagem por segmento: 618 SMB / 290 ICP / 119 Onboarding; distribuição de nota {0:242, 1:203, 2:30, 3:25, 4:527}; soma do gap = 3570) — bateu exato. Cada um dos 11 chunks e o patch SQL foram publicados e conferidos byte-a-byte (`get_file_contents` + diff/md5sum) contra o arquivo local antes de considerar "feito".
- **Incidente durante a publicação (corrigido)**: a primeira tentativa de publicar o `index.html` (commit `703175e`) corrompeu por transcrição um trecho do path SVG da logo da marca (não relacionado à lógica da Rodada 8). Foi pego pela própria verificação byte-a-byte, corrigido no commit seguinte (`4401247`) e reconferido — sem impacto, já que nunca chegou a ficar em produção sem essa checagem.

## ✅ Reverter a paleta única de B.V. — implementado na Rodada 9 (2026-08-12)
Luiz corrigiu o item "paleta de cor única por grau de B.V." da Rodada 6: eu troquei o card "Empresas por Basic Value de instalação" (`.grade-pill`) pra usar a rampa verde do gráfico de Evolução B.V. -- mas o pedido era o **inverso**.
- **Card de distribuição (`.grade-pill`)**: ✅ revertido pra cor de status (risco/aviso/ok) -- ver Rodada 9, item 3.
- **Gráfico de Evolução B.V.**: ✅ trocada a rampa ordinal verde pela paleta de status -- ver Rodada 9, item 3.

## ✅ Login: Google + e-mail/senha + "esqueceu a senha" — implementado na Rodada 11 (2026-08-12)
Front-end publicado -- ver Rodada 11, item 4, no topo deste arquivo. Falta só o Luiz configurar o provider Google no painel do Supabase (Authentication → Providers) pra "Entrar com Google" funcionar de fato; até lá o botão fica inofensivo (dá erro "provider not enabled" só pra quem clicar). E-mail/senha e "esqueceu a senha" já funcionam sem depender de nenhum setup adicional.

<details><summary>Histórico da decisão (2026-08-10)</summary>

## Login: trocar magic link por "Entrar com Google" (2026-08-10) — aguardando setup do Luiz
Luiz apontou uma limitação real do link mágico: se ele (ou alguém já cadastrado) precisar acessar o dashboard num dispositivo/navegador sem sessão salva e sem acesso ao e-mail naquele momento, fica sem conseguir entrar — o link mágico sempre exige esse passo extra de e-mail pra qualquer sessão nova, mesmo pra quem já está cadastrado há tempos.

- **Diagnóstico**: isso não é um bug — é uma limitação inerente de qualquer login sem senha baseado em link/OTP por e-mail: pra uma sessão nova, o sistema precisa de alguma prova de identidade, e "estar cadastrado no banco" não é algo que o navegador consiga provar sozinho.
- **Solução proposta e confirmada pelo Luiz**: a Cobli usa Google Workspace pros e-mails @cobli.co — então dá pra trocar o magic link por login **"Entrar com Google"** (OAuth). Como todo mundo já fica logado no Google no navegador/celular do trabalho, isso resolve exatamente o pedido: entra na hora, sem e-mail, tanto no primeiro acesso quanto em qualquer um depois.
- **O que precisa pra habilitar** (passo do Luiz, fora do meu alcance — não tenho acesso ao Google Cloud/Supabase da Cobli):
  1. Criar um projeto no Google Cloud Console (console.cloud.google.com) — gratuito, qualquer conta Google serve (não precisa ser admin do Workspace, embora seja boa prática usar uma conta/projeto oficial da Cobli se tiver).
  2. Configurar a "OAuth consent screen" (nome do app, e-mail de suporte).
  3. Em "Credentials", criar um "OAuth Client ID" do tipo Web application, com o redirect URI do Supabase (`https://tmjmjrhgmyqamuphgdvi.supabase.co/auth/v1/callback`).
  4. Copiar o Client ID e o Client Secret gerados.
  5. Colar os dois no painel do Supabase → Authentication → Providers → Google, e habilitar.
  6. Nenhuma mudança de código é necessária pro Client ID/Secret em si (eles ficam só na configuração do Supabase) — o front-end só chama `signInWithOAuth({ provider: 'google' })`, que já dá pra implementar de antemão (fica inofensivo/inerte até o passo acima ser feito).
- **Status**: aguardando o Luiz decidir se quer seguir com isso e fazer o setup do Google Cloud. O código do front-end pode ser escrito antes, sem risco, já que não afeta nada até a configuração do lado do Supabase existir.

- **Limite identificado pelo próprio Luiz (2026-08-10, mesma rodada)**: "Entrar com Google" só resolve sozinho quando o navegador/computador já está logado na conta Google @cobli.co (ex.: notebook de trabalho). Num computador onde a pessoa NÃO está logada nessa conta Google (ex.: computador pessoal, de terceiro, LAN house), cai exatamente no mesmo problema de antes: sem sessão salva, o Google também vai pedir login, e se a pessoa não tiver a senha do Google de cabeça (hoje em dia é comum só ter salva no navegador do trabalho), fica travado de novo.
- **Alternativa levantada pelo Luiz**: login com e-mail e senha (usuário/senha própria do dashboard, não do Google).
  - **Avaliação**: essa opção resolve o problema de forma mais direta que o Google OAuth, porque não depende do estado do navegador/dispositivo (sessão salva) nem de acesso ao e-mail no momento do login -- só depende de a pessoa lembrar (ou ter salva em qualquer gerenciador de senha) a combinação e-mail + senha. Funciona em qualquer computador, logado ou não em qualquer coisa.
  - **Como ficaria**: usar o método nativo de senha do Supabase Auth (`signInWithPassword`). Fluxo sugerido: no primeiro acesso (convite), a pessoa define uma senha (link do primeiro acesso viraria "defina sua senha" em vez de só um login automático); dali em diante, ela entra com e-mail + senha em qualquer lugar; existe um "esqueci minha senha" que manda um link de redefinição por e-mail (aí sim usando o e-mail como último recurso, só quando necessário).
  - **Recomendação**: dá pra ter os três métodos disponíveis ao mesmo tempo, sem conflito -- "Entrar com Google" (mais rápido, quando já tem sessão Google no navegador), "E-mail e senha" (funciona em qualquer computador), e o magic link continua existindo por baixo dos panos só pro fluxo de "esqueci minha senha" / primeiro cadastro. Não precisa escolher um único caminho.
  - **Status**: proposto, aguardando o Luiz confirmar se quer seguir com e-mail e senha (em vez do Google, ou junto com ele) antes de eu implementar.

</details>

## ✅ Rodada 6 (2026-08-11) — implementada e publicada no `index.html`
*Commits: `59b28e4` (index.html) e `a572b1d` (supabase/patch-rodada6.sql), branch `main`. Depende do patch SQL ser rodado -- ver aviso no topo deste arquivo.*

### 8. ✅ Bug: squad do ticket não vincula com a squad cadastrada do responsável
Exemplo dado pelo Luiz: Danielle Couto (grafia correta confirmada no HubSpot -- não "Daniele") está cadastrada em `team_members` na squad ICP, mas os tickets no nome dela continuavam aparecendo como "sem squad".
- **Causa raiz confirmada**: a squad do ticket (`v_dashboard.owner_squad`) vem do `join` entre `tickets_sync.owner_hubspot_id` e `team_members.hubspot_owner_id` -- e esse `hubspot_owner_id` só é preenchido durante a sincronização periódica (script Python, `update_owner_ids()`), nunca no momento do convite. Alguém recém-convidado fica "sem squad" nos tickets até a próxima sincronização.
- **Corrigido**: (a) o bloco "Editar usuário" agora expõe o campo "ID no HubSpot" pra preencher esse vínculo na mão, sem esperar o sync; (b) `supabase/patch-rodada6.sql` inclui um vínculo pontual já resolvendo a Danielle Couto especificamente (ownerId 199072037, confirmado via busca no HubSpot).
- Ainda vale lembrar: qualquer pessoa nova continua "sem squad" nos tickets até alguém preencher o ID do HubSpot (na edição) ou até a próxima sincronização -- isso é esperado, não é bug.

### 9. ✅ Reordenar formulário de convite/edição: perfil antes da squad, e squad some pra gestor_geral
- Campo "Papel" agora vem antes de "Squad" no formulário de Convidar.
- Quando o papel selecionado é "Gestor geral", o campo de squad é escondido (e enviado como `NULL`) tanto no convite quanto na edição -- gestor_geral não fica vinculado a uma squad própria.
- Precisou de migração de banco (`squad` deixou de ser `not null`) -- está em `supabase/patch-rodada6.sql`.

### 5. ✅ Excluir usuário no bloco de Administração ("Cadastro atual")
- Decisão do Luiz: **exclusão real** (`delete`), não soft-delete.
- Se a pessoa tiver histórico vinculado (ex.: tratativas em `ticket_checks`), o Postgres bloqueia a exclusão por chave estrangeira (código `23503`) -- tratado com uma mensagem amigável em vez de erro cru, pedindo pra falar com o time técnico se precisar remover mesmo assim.
- Testado com Postgres real simulando gestor_squad (só exclui da própria squad) e gestor_geral (exclui qualquer um).

### 6. ✅ Editar usuário no bloco de Administração
- Novo card "Editar usuário" (nome, papel, squad, ID do HubSpot) -- abre preenchido ao clicar em "Editar" na linha da pessoa.
- gestor_squad só edita gente da própria squad; gestor_geral edita qualquer cadastro.

### 7. ✅ Diferenciar visualmente squad "titular" vs. squad "cobrindo"
- Badge extra "cobrindo" ao lado do badge de squad quando o ticket é de uma squad diferente da squad titular de quem está vendo (por `access_grants`). gestor_geral nunca vê esse selo (não tem squad titular).
- Ficou de fora, por decisão do Luiz ("fora por agora"): um recurso maior de "squads extras permanentes" geridas pelo gestor_geral (schema novo, `extra_squads`) -- por ora só o `access_grants` existente + esse badge visual.

### ✅ Select de `team_members` em vez de e-mail livre (Delegar) + cards mais compactos
- "Delegar visão" agora usa `<select>` alimentado pelo cadastro ativo, em vez de digitar e-mail de cor.
- Cards de "Convidar pessoa" e "Delegar visão" ficaram mais compactos (menos padding/altura) -- pedido do Luiz na Rodada 2.

### ✅ Endurecer a nível de RLS a restrição de convite por papel
- Antes só o front-end impedia gestor_squad de convidar/editar/promover gente fora da própria squad -- agora as policies de `insert`/`update`/`delete` de `team_members` no Postgres também aplicam essa regra (gestor_squad só mexe em colaborador da própria squad; nunca promove a gestor_geral; nunca move gente de squad).
- Testado localmente com Postgres puro simulando os 3 papéis (11 cenários: convite dentro/fora da squad, promoção indevida, edição própria, exclusão dentro/fora da squad, etc.) antes de publicar.

### ✅ Ordenação clicável na coluna MRR
- Terceira coluna ordenável por clique (além de "Aberto há" e "Basic Value").

### ✅ Rótulos de dados no gráfico + paleta de cor única por grau de B.V.
- Gráfico de Evolução B.V. agora mostra o % direto nas barras (antes só no tooltip).
- Badges de grau (`.grade-pill`) passaram a usar a mesma rampa de verde do gráfico de Evolução, em vez de cores de status -- reverte a decisão da Rodada 2/3, por pedido do Luiz de consistência visual.

### ✅ Recolher o bloco de KPIs + distribuição por Basic Value
- Vira um único bloco recolhível. Decisão do Luiz: **começa sempre expandido** (o toggle é só uma opção pra quem quiser recolher).

### Verificação feita antes de publicar
- `node --check` no bloco `<script>` do `index.html` publicado (sintaxe OK).
- 21 checes automatizados via Playwright (Chromium headless) simulando gestor_squad e gestor_geral: visibilidade do formulário, restrições de linha na tabela de cadastro, edição, exclusão com erro de FK simulado, badge "cobrindo", ordenação por MRR, toggle de KPIs, selects de delegação.
- `supabase/patch-rodada6.sql` rodado de ponta a ponta num Postgres 16 local (schema.sql + todos os patches anteriores + este), com 11 cenários de RLS testados como gestor_squad/gestor_geral reais (não só lidos, executados de verdade).
- Push feito e imediatamente conferido via `get_file_contents` + diff byte-a-byte contra o arquivo local publicado -- idêntico.

## Ainda em aberto, deixado explicitamente de fora desta rodada (a pedido do Luiz)
Estes NÃO foram tocados nesta rodada -- continuam só como proposta/backlog:

### 2. Mapeamento de propriedades de produto/quantidade (HubSpot) para a próxima sincronização
Lista fornecida pelo Luiz (nome de exibição no HubSpot → rótulo que deve aparecer no dashboard):

| Propriedade (HubSpot) | Rótulo no dashboard |
|---|---|
| Quantidade Instalação Instalado leves ou pesados | Instalado Simples |
| Quantidade Instalação Instalado leves ou pesados Cobli Cam Fadiga | Coblicam Fadiga |
| Quantidade Instalação Instalado leves ou pesados Cobli Cam Geração 2 | Coblicam Multi |
| Quantidade Instalação Instalado leves ou pesados coblicam Cabine | Coblicam Cabine |
| Quantidade Instalação Instalado leves ou pesados identificador | Instalado Identificador |
| Quantidade Instalação Instalado leves ou pesados Trava de Ignição | Trava de Ignição |
| Quantidade Instalação Instalado motos ou maquinários | Moto Maquinário |
| Quantidade Instalação Removível leves | Removível |
| Quantidade Instalação Removível leves ou pesados buzzer | Removível |
| Quantidade Instalação Removível leves ou pesados identificador | Removível |
| Quantidade Instalação Removível pesados | Removível |
| Quantidade Instalação Removível pesados *(repetida)* | Removível |

- A última linha veio duplicada (idêntica) no texto original — preciso confirmar com o Luiz se uma delas era pra ser outra variante (ex. "Removível pesados buzzer/identificador") antes de fechar o mapeamento de vez.
- Essas são os nomes de EXIBIÇÃO no HubSpot, não as chaves internas de propriedade — na próxima sincronização real preciso resolver a chave interna de cada uma (via schema discovery, casando pelo rótulo). Esta lista é mais completa que o conjunto de 5 propriedades hoje confirmadas como funcionando via API (buzzer / câmera fadiga / câmera fadiga premium / removível buzzer / removível identificador).
- Não muda nada no front-end agora — é insumo pra próxima rodada de sincronização real (ajustar `sync-runbook.md` e o script de montagem do JSON).

### 4. ✅ Redesign da área de abas + filtros (toolbar) — implementado na Rodada 9 (2026-08-12)
- Opção A (sidebar recolhível) confirmada pelo Luiz e implementada -- ver Rodada 9, item 2.

### Squads extras permanentes (gestor_geral atribuir mais de uma squad a alguém, de forma permanente)
- Decisão do Luiz (2026-08-11): **fora por agora**. Ficou só o `access_grants` existente (cobertura temporária pessoa-a-pessoa) + o badge visual "cobrindo" (item 7 da Rodada 6, já implementado). Um recurso maior de squads extras permanentes (schema novo, tipo `extra_squads`, gerenciado pelo gestor_geral) fica pra uma rodada futura, se necessário.

### Investigar `deal_id` como identificador adicional
Ainda indisponível em qualquer fonte de dados sincronizada hoje.

### Indicador de "quantidade agendados" (pedido do Luiz, Rodada 9→10, 2026-08-12)
Depois de testar o checkbox "Agendado", o Luiz pediu um indicador novo pra ver o que foi agendado no dia: "pode deixar um de backlog para qtd agendados, para ver o que agendamos no dia conforme marcar o check, ai detalhe se é prioridade (completudo ou basic value, ou normal sem usar o filtro)."
- Ideia: um contador (KPI novo, ou seção separada) de quantos tickets foram marcados como "Agendado" **no dia** (não o total histórico de `ticket_priority_ack`), com o detalhe de quantos foram marcados enquanto o filtro de Prioridade "Completude de Instalação" estava ativo, quantos com "Basic Value" ativo, e quantos "normal" (sem filtro de Prioridade selecionado).
- Pra isso funcionar, precisa capturar o `priorityCategory` ativo no momento do clique (hoje `onAckTicket()` só grava `ticket_id` e `marked_by` em `ticket_priority_ack` -- não guarda em qual contexto/filtro a marcação aconteceu). Provável migração: coluna nova em `ticket_priority_ack` (ex. `priority_category_at_ack text null`) preenchida a partir de `state.priorityCategory` no momento do `insert`.
- Não implementado ainda -- só registrado aqui como próximo passo, a pedido explícito do Luiz de deixar em backlog por agora.

---

## Deixado explicitamente para o final (confirmado pelo Luiz)
- **Notificação Slack** ao liberar acesso/convidar alguém (proposta técnica já escrita no doc do projeto).
- **Frequência da sincronização automática** + criação da scheduled task de sync.

---

## Já implementado e publicado
- Aba "Evolução B.V." com histórico real do Databricks (41 semanas) + toggle Semanal/Mensal — confirmado pelo Luiz.
- Busca unificada por nome/empresa/ticket/company_id/grupo econômico.
- Ordenação clicável em "Aberto há" e "Basic Value".
- Célula de Basic Value com Instalação em destaque, Geral discreto.
- Badge de sincronização desatualizada (>2 dias).
- Restrição do formulário de convite por papel (gestor de squad só convida colaborador pra própria squad).
- Badges/pills no card de distribuição por Basic Value, ticket clicável, filtros de Gestor/Squad/Responsável, largura do painel de Administração corrigida.
