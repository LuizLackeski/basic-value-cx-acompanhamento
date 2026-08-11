# Backlog — Basic Value / ICP Dashboard

*Atualizado em 2026-08-11 (Rodada 8). Itens marcados ✅ já estão implementados e publicados; os demais estão só registrados, aguardando implementação ou validação.*

## ⚠️ Ação pendente do Luiz: rodar `supabase/patch-completude-instalacao-nota.sql`
A Rodada 8 (ver seção própria abaixo) já está publicada no `index.html` e nos dados (`data/chunks/completude_instalacao-*.json`), mas depende de uma migração de banco que **ainda não foi rodada**. Sem isso, `completude_nota_instalacao` / `completude_qtd_falta_nota_3` aparecem como `null` no dashboard (célula de Instalação some) e `mrr_status` continua calculado do jeito antigo (`basic_value_score`).
- Rode `supabase/patch-completude-instalacao-nota.sql` inteiro no SQL Editor do Supabase (idempotente, pode rodar mais de uma vez sem problema). Precisa já ter rodado `patch-completude-instalacao.sql` e `patch-completude-instalacao-prazo.sql` antes.

## ⚠️ Ação pendente do Luiz: rodar `supabase/patch-rodada6.sql`
A Rodada 6 (lista abaixo) já está publicada no `index.html`, mas depende de uma migração de banco que **ainda não foi rodada**. Sem isso, convidar/editar um gestor_geral vai dar erro (squad ainda é obrigatória no banco) e as regras novas de permissão (insert/update/delete de `team_members`) ainda não estarão em vigor.
- Rode `supabase/patch-rodada6.sql` inteiro no SQL Editor do Supabase (idempotente, pode rodar mais de uma vez sem problema).
- Esse mesmo patch já inclui o vínculo pontual do `hubspot_owner_id` da Danielle Couto (199072037) -- ver item 8 abaixo.

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

## Novo pedido (2026-08-11, pós-Rodada 6) — só anotado, nada implementado ainda

### Reverter a paleta única de B.V. — na verdade era pro lado contrário
Luiz corrigiu o item "paleta de cor única por grau de B.V." da Rodada 6: eu troquei o card "Empresas por Basic Value de instalação" (`.grade-pill`) pra usar a rampa verde do gráfico de Evolução B.V. -- mas o pedido era o **inverso**.
- **Card de distribuição (`.grade-pill`)**: reverter pra cor de status como estava antes da Rodada 6 (risco/aviso/ok) -- não usar a rampa verde aqui.
- **Gráfico de Evolução B.V.**: trocar a rampa ordinal verde atual pelo mesmo padrão de cor de status (risco/aviso/ok) que o card de distribuição usava antes -- ou seja, o padrão de cor "vai" do card pro gráfico, não o contrário do que eu fiz.
- **Só backlog por enquanto** -- Luiz pediu explicitamente pra só anotar, não implementar agora.

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

### 4. Redesign da área de abas + filtros (toolbar)
- Luiz achou o layout atual "bem ruim", sem detalhar o que trocar. Fica pra pensar numa proposta concreta antes da próxima rodada.

### Squads extras permanentes (gestor_geral atribuir mais de uma squad a alguém, de forma permanente)
- Decisão do Luiz (2026-08-11): **fora por agora**. Ficou só o `access_grants` existente (cobertura temporária pessoa-a-pessoa) + o badge visual "cobrindo" (item 7 da Rodada 6, já implementado). Um recurso maior de squads extras permanentes (schema novo, tipo `extra_squads`, gerenciado pelo gestor_geral) fica pra uma rodada futura, se necessário.

### Investigar `deal_id` como identificador adicional
Ainda indisponível em qualquer fonte de dados sincronizada hoje.

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
