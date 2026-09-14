# Divisor de Viagem — Handoff técnico

App de página única (um arquivo `index.html`) para um casal dividir os custos das idas semanais a São Paulo (combustível, pedágio, estacionamento) e ver quem deve quanto a quem. Sincroniza entre aparelhos via Supabase, com login por e-mail/senha e RLS por usuário.

Este documento descreve o estado atual do app, as decisões, os problemas já resolvidos e o que falta. Escrito para continuar o trabalho no Claude Code.

---

## 1. Como rodar / publicar

- É **um único arquivo HTML** (`index.html`), sem build, sem framework, sem dependências além de:
  - Google Fonts (Plus Jakarta Sans + Space Grotesk) via `<link>`.
  - APIs REST do Supabase (`/auth/v1` e `/rest/v1`) via `fetch` — nenhuma biblioteca JS externa.
- Rodar local: basta abrir o arquivo no navegador.
- Publicar: é site estático puro. Repositório Git na pasta → GitHub → importar no Vercel (deploy automático a cada push). Netlify/GitHub Pages funcionam igual.
- **Não depende** de rodar dentro do Claude. Funciona em qualquer host estático.
- O setup do banco está em `supabase-setup.sql` — passos numerados pra rodar no SQL Editor.
- Ícone: na aba é um SVG embutido no `<head>`; para atalho na tela inicial do celular existem `icon-180.png` (iOS), `icon-192/512.png` + `manifest.webmanifest` (Android). Os PNGs são quadrados inteiros — cada sistema arredonda por conta própria. Para regenerar, é o mesmo desenho do SVG (coração + duas rodinhas em `#2C55E0`/`#DE8410`/branco).

---

## 2. O que o app faz (funcionalidades)

- **Viagens** com nome editável e data editável (`<input type="date">`).
- **Lançamento de despesas** por viagem, em dois modos:
  - **Combustível**: informa km rodados, média km/L e preço R$/L; o custo é **calculado** (`litros = km / kmPerL`, `custo = litros * pricePerL`) e mostrado ao vivo antes de salvar. A última média e preço ficam salvos como sugestão do próximo lançamento (`lastFuel`).
  - **Valor direto**: um ou vários valores somados num lançamento só (para pedágio com várias praças). Guarda os componentes em `parts[]`.
- **Pessoas e categorias** totalmente editáveis (adicionar, renomear, remover). Nada é fixo.
- **Acerto de contas**: mostra quanto cada um pagou, o saldo (+/−) e "Fulano paga Beltrano R$ X". Divisão igualitária (50/50 com duas pessoas).
- **Filtro de período**: Tudo / Mês / Semana, com navegação ‹ › entre períodos. O total e o acerto recalculam para a janela selecionada. Semana = domingo a sábado.
- **Marcar como pago** por período, com derivação hierárquica (ver seção 6).
- **Agrupamento por mês** na lista de viagens, com título de mês e total do mês.
- **Aba Análise**: gasto por mês (barras), categorias empilhadas por mês, e comparativo mês-a-mês por categoria com variação %.
- **Backup**: exportar (copia o JSON do estado) e importar (cola um JSON e substitui).
- **Confirmações e avisos próprios** (modal + toast), porque `confirm()`/`alert()` nativos são bloqueados no sandbox do artifact.
- **Login** por e-mail/senha (Supabase Auth) e botão Sair. Ver seção 9.

---

## 3. Arquitetura

- Vanilla JS, tudo em `<script>` no fim do `<body>`. CSS no `<style>` no `<head>`.
- Padrão: um objeto `state` global; funções `render*` reconstroem o HTML a partir do `state`; mutações alteram `state`, chamam `save()` e re-renderizam.
- Delegação de eventos: um único `document.addEventListener("click", async e => {...})` trata quase tudo via `data-*` attributes. Há também listeners de `input`, `change`, `visibilitychange` e `focus`.
- Estado transitório (não persistido): `mode` (modo do form por viagem), `openMap` (sanfona aberta/fechada por viagem), `view` (aba ativa), `period` (filtro atual), `unlocked`.

### Principais funções
- Sessão: `signIn`, `refreshSession`, `signOut`, `start`, `tryUnlock`, `api` (wrapper de `fetch` que injeta o token e tenta renovar em 401).
- Armazenamento: `fetchState`, `fromRows`, `load`, `write`, `putTrip`, `dropTrip`, `putSettings`, `putPaid`, `dropPaid`, `pushAll`, `local.get/set`, `reloadFromStore`, `debounce`.
- Cálculo: `compute(trips)`, `settleUp(net)`.
- Período: `tripsInPeriod`, `periodKey`, `periodLabel`, `scopeLabel`, `startOfWeek`.
- Pago: `paidStatus`, `isMonthPaid`, `weeksOfMonthKey`, `monthKeyOf`.
- Render: `renderCluster`, `renderCfg`, `renderTrips` (contém `tripCard`), `renderInsights`, `renderAll`, `updateReadout`, `updateFlatSum`.
- Análise: `aggregate`, `monthLabel`, `monthTitle`, `catColor`, `fmtShort`, `compRow`.
- UI utilitária: `confirmBox`, `toast`, `tryUnlock` (desativada).

---

## 4. Modelo de dados (`state`)

Em memória o formato continua exatamente o mesmo de antes. O que mudou é **onde ele fica**: não é mais um blob único, e sim linhas nas tabelas `trip`, `settings` e `paid` (ver seção 5). `fromRows()` remonta este objeto na leitura. Cache local sob a chave `"divisor-viagem-v2"`; a sessão fica em `"divisor-viagem-session"`.

```js
state = {
  people: [ { id, name } ],                 // ids gerados por uid()
  cats: [ "Combustível", "Pedágio", ... ],  // strings; expense.cat guarda o nome no momento do lançamento
  lastFuel: { kmPerL: "12", pricePerL: "5,79" }, // sugestões do último combustível (strings com vírgula)
  paid: {                                   // chaves de período pagas
    "all": { at: "2026-09-12" },
    "month:2026-08": { at: "..." },
    "week:2026-08-23": { at: "..." }        // week: usa a data de início da semana (domingo), ISO
  },
  trips: [
    {
      id, name, dateISO: "2026-08-11",      // dateISO pode faltar em viagens muito antigas -> caem em "Sem data"
      expenses: [
        { id, type: "fuel", cat, payer, km, kmPerL, pricePerL, amount },
        { id, type: "flat", cat, payer, amount, parts: [12.8, 9.6] } // parts = valores somados (pedágio)
      ]
    }
  ]
}
```

- `payer` = `people[].id`.
- `amount` sempre já é o valor final em reais (para combustível, já calculado).

---

## 5. Armazenamento e sincronização

Fonte de verdade = **Supabase**, com uma linha por entidade. Local = cache de leitura offline.

- `load()` → `fetchState()`: descobre o `household_id` do usuário logado (`household_member`) e faz 3 GETs em paralelo (`trip`, `settings`, `paid`); `fromRows()` remonta o `state`. Se a rede falhar, cai no cache local e avisa por toast. Se a *sessão* falhar, propaga `AuthError` e volta pro login.
- **Escrita pontual**: cada mutação grava só a linha afetada — `putTrip(t)`, `dropTrip(id)`, `putSettings()`, `putPaid(k)`, `dropPaid(k)`. Todas passam por `write()`, que captura erro, avisa por toast e sempre atualiza o cache local.
- `pushAll()`: reescreve tudo. Usado só em "Apagar tudo" e na importação de backup.
- Edições vindas de digitação (nome de pessoa/categoria/viagem, data) passam por `debounce(key, fn)` de 400 ms, para não gerar uma requisição por tecla.
- `reloadFromStore()`: relê o estado e re-renderiza **só se mudou** (comparação por JSON). Roda a cada 15 s (`pollT`) e em `focus`/`visibilitychange`. Pula se houver input focado ou escrita pendente no debounce.

### Por que uma linha por viagem
O clobber que existia (dois editando quase juntos, um sobrescrevendo o outro) só sobrevive agora se os dois mexerem **na mesma viagem** dentro da mesma janela de segundos. Editar viagens diferentes, ou um mexer em viagem e outro em categoria, não colide mais. As `expenses` continuam em jsonb dentro da linha da viagem — resolver colisão dentro de uma mesma viagem exigiria uma tabela por despesa.

### Limitações conhecidas de sync
- Atualização ao vivo é por consulta a cada 15 s, não WebSocket. O atraso máximo é isso.
- Duas pessoas editando a **mesma** viagem ao mesmo tempo: ainda vence quem salvar por último.
- `window.storage` é **por conta/navegador**; continua sendo só cache.

---

## 6. Lógica de "pago" (derivação hierárquica)

`state.paid` guarda marcações explícitas por chave de período (`all`, `month:YYYY-MM`, `week:YYYY-MM-DD`).

`paidStatus()` decide se o período atual está pago:
- **Semana**: paga só se marcada explicitamente.
- **Mês** (`isMonthPaid`): pago se marcado explicitamente **ou** se **todas as semanas com viagem daquele mês** estão pagas (inclui o caso de mês com uma única semana).
- **Tudo**: pago se marcado explicitamente **ou** se **todos os meses com viagem** estão pagos (cada mês avaliado por `isMonthPaid`).

O selo indica a origem: "Pago · mês · pelas semanas" ou "Pago · tudo · pelos meses" (derivado, sem botão desfazer); quando explícito, mostra a data e o "desfazer".

`weeksOfMonthKey(mk)` = conjunto de datas de início de semana (domingo) das viagens daquele mês.

---

## 7. Lógica de acerto (settlement)

- `compute(trips)`: soma `total`, calcula `perHead = total / nºpessoas`, e para cada pessoa `{ name, paid, net }` onde `net = paid - perHead`.
- `settleUp(net)`: casa quem tem saldo negativo (deve) com quem tem positivo (recebe), minimizando transferências. Para duas pessoas, gera uma transferência = metade da diferença entre o que cada um pagou.
- **Importante (já foi ponto de dúvida da usuária)**: o valor do acerto é **metade da diferença**, não o total pago. Isso é o correto para 50/50 — é o que zera a conta. O painel mostra "pagou R$ X" de cada um justamente para deixar o valor real visível.
- A divisão é **igualitária entre todas as pessoas cadastradas**. Não há split por porcentagem nem despesa atribuída a uma pessoa só. (Possível próximo passo se precisarem.)

---

## 8. Supabase

- **Project URL**: `https://cvhqxltumqlklszvdute.supabase.co`
- **Publishable key** (no código, segura para browser): `sb_publishable_wRG0y9x90PRJI058-m883Q_AU34o-mM`
- A **secret key nunca foi usada** e não deve ir para o front.

### Configuração no painel
- Authentication → Sign In / Providers → **Email** habilitado, e **"Allow new users to sign up" desligado** (ninguém cria conta sozinho).
- Authentication → Users → **Add user → Create new user**, informando e-mail + senha e marcando **"Auto Confirm User"**.
- **Não use "Invite user"**: o link do convite aponta para a Site URL do projeto (por padrão `localhost`) e o app não tem tela para receber convite nem definir senha. Contas se criam à mão, com senha, e a senha se troca pelo painel.
- Toda vez que um usuário for criado ou recriado, rode de novo o PASSO 3 do `supabase-setup.sql` — ele liga as contas ao `household`. Sem isso a pessoa loga mas vê "Esta conta não tem acesso aos dados do casal".

### Tabelas e RLS
Tudo em `supabase-setup.sql`, em 5 passos numerados. Resumo:

- `household` / `household_member` — o grupo do casal e quem pertence a ele.
- `trip` (PK `id` text, mesmo id gerado por `uid()` no front), `settings` (PK `household_id`), `paid` (PK `household_id,key`).
- Função `is_member(h uuid)` em `security definer` — evita recursão nas policies.
- Policies só para o papel `authenticated`, sempre `using (is_member(household_id))`. **Nenhuma policy para `anon`**: quem não logar não lê nem escreve, mesmo com a publishable key em mãos.
- A tabela antiga `app_state` continua existindo como backup, mas sem a policy `acesso_publico`.

### Endpoints usados (REST)
- Login: `POST {URL}/auth/v1/token?grant_type=password` (body `{email,password}`); renovação com `grant_type=refresh_token`.
- Dados: `GET/POST/DELETE {URL}/rest/v1/<tabela>` com `apikey: <publishable>` e `Authorization: Bearer <access_token do usuário>`.
- Upsert: `Prefer: resolution=merge-duplicates,return=minimal`.

---

## 9. Login

- O overlay `#lock` virou formulário de verdade: e-mail + senha → Supabase Auth.
- A sessão (`access_token`, `refresh_token`, `expires_at`) fica em `localStorage` sob `"divisor-viagem-session"`; ao abrir o app ela é reaproveitada e renovada se estiver vencida. Botão **Sair** no rodapé.
- A senha antiga hardcoded (`PASSWORD`) foi **removida**. A segurança agora é o RLS no banco, não a tela.
- Quem loga com uma conta que não está em nenhum `household` recebe "Esta conta não tem acesso aos dados do casal" — é sinal de que o PASSO 3 do SQL não rodou pra esse e-mail.

---

## 10. Problemas já resolvidos (para não repetir)

- **`confirm()`/`alert()` nativos são bloqueados no sandbox** do artifact → botões "Apagar tudo" e "excluir viagem" pareciam não funcionar. Substituídos por `confirmBox()` (modal próprio, Promise) e `toast()`.
- **CSS vencendo o atributo `hidden`**: `.modal{display:grid}` sobrepunha o `hidden`, deixando o modal invisível cobrindo a tela e engolindo todos os cliques ("nenhum botão funciona"). Corrigido com regras `[hidden]{display:none}` para `.modal`, `.toast` e `.vx`. **Atenção**: qualquer elemento que use o atributo `hidden` e também tenha `display` no CSS precisa de `.classe[hidden]{display:none}`.
- **Dados "sumiram"** ao trocar armazenamento pessoal → compartilhado: os dados não sumiram, ficaram no armazenamento pessoal. `load()` faz fallback + migração. Depois migramos de vez para o Supabase.
- **Combustível** deixou de ser valor digitado e passou a ser calculado por km/consumo/preço.

---

## 11. Limitações / armadilhas conhecidas

- **Não rode mais como artifact do Claude**: o sandbox bloqueia `fetch`, e o app agora depende de rede já no login. Use o deploy estático.
- Cache do navegador pode servir versão velha depois de um deploy (testar em aba anônima).
- Viagens sem `dateISO` não entram nos filtros de período nem na análise (caem em "Sem data").
- Categoria renomeada não migra lançamentos antigos (eles guardam o nome antigo em `expense.cat`).

---

## 12. Próximos passos sugeridos

1. ~~Segurança real~~ — feito (Supabase Auth + RLS por household).
2. ~~Sincronização robusta~~ — feito (uma linha por viagem + consulta a cada 15 s).
3. ~~Deploy versionado~~ — feito (repositório Git + Vercel).
4. **Supabase Realtime** no lugar da consulta de 15 s, se o atraso incomodar. Exige WebSocket (protocolo Phoenix) ou a biblioteca `supabase-js`.
5. **Split não-igualitário** (por %, ou despesa atribuída a uma pessoa), se o casal precisar.
6. **Indicador de pago na aba Análise** (marcar meses quitados nas barras) — ficou pendente.
7. **Recuperação de senha** — hoje, se alguém esquecer, troca-se pelo painel do Supabase.

---

## 13. Design (referência)

- Tema claro "porcelana": fundo `#E8EBEF`, cartões brancos, tinta `#1B2333`, acento cobalto `#2C55E0`, âmbar `#DE8410` (custo de combustível/soma), verde `#1E9E5A` (quitado), vermelho `#D9573F` (deve).
- Fontes: Plus Jakarta Sans (texto), Space Grotesk (números/títulos).
- Sem bibliotecas de UI ou gráfico; os gráficos da Análise são SVG/CSS próprios.
