# dividegastos

App de página única para dividir os custos das viagens a São Paulo — combustível,
pedágio e estacionamento — e ver quem deve quanto a quem.

Um arquivo (`index.html`), sem build e sem dependências JS. Os dados ficam no
Supabase, com login por e-mail/senha e acesso restrito por RLS.

- `index.html` — o app inteiro.
- `supabase-setup.sql` — criação das tabelas, RLS e migração dos dados. Passos numerados.
- `HANDOFF.md` — arquitetura, modelo de dados, decisões e armadilhas conhecidas.

Publicação: site estático. Qualquer host serve (Vercel, Netlify, GitHub Pages).
