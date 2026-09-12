-- ============================================================
-- Divisor de Viagem — login + RLS + uma linha por viagem
-- Rodar no SQL Editor do Supabase, na ordem, de cima pra baixo.
-- ANTES DE COMEÇAR: abra o app antigo, clique em "Backup / transferir
-- dados" -> "Copiar" e salve esse texto num arquivo. Rede de segurança.
-- ============================================================


-- ------------------------------------------------------------
-- PASSO 1 — Tabelas
-- ------------------------------------------------------------
create table if not exists household (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Casal'
);

create table if not exists household_member (
  household_id uuid not null references household(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (household_id, user_id)
);

create table if not exists trip (
  id text primary key,
  household_id uuid not null references household(id) on delete cascade,
  name text,
  date_iso date,
  expenses jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists trip_household_idx on trip(household_id);

create table if not exists settings (
  household_id uuid primary key references household(id) on delete cascade,
  people jsonb not null default '[]'::jsonb,
  cats jsonb not null default '[]'::jsonb,
  last_fuel jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists paid (
  household_id uuid not null references household(id) on delete cascade,
  key text not null,
  at date,
  primary key (household_id, key)
);


-- ------------------------------------------------------------
-- PASSO 2 — RLS: só quem está logado E pertence ao grupo enxerga
-- ------------------------------------------------------------
create or replace function is_member(h uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(
    select 1 from household_member m
    where m.household_id = h and m.user_id = auth.uid()
  );
$$;

alter table household        enable row level security;
alter table household_member enable row level security;
alter table trip             enable row level security;
alter table settings         enable row level security;
alter table paid             enable row level security;

drop policy if exists h_sel     on household;
drop policy if exists hm_sel    on household_member;
drop policy if exists trip_all  on trip;
drop policy if exists set_all   on settings;
drop policy if exists paid_all  on paid;

create policy h_sel  on household        for select to authenticated using (is_member(id));
create policy hm_sel on household_member for select to authenticated using (user_id = auth.uid());

create policy trip_all on trip for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
create policy set_all on settings for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
create policy paid_all on paid for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
-- Nenhuma policy para o papel "anon": quem não estiver logado não lê nem
-- escreve nada, mesmo tendo a chave publishable que está no código.


-- ------------------------------------------------------------
-- PASSO 3 — Criar o grupo e ligar as contas
--
-- ANTES de rodar este passo, crie os usuários no painel:
--   Authentication -> Users -> Add user -> Create new user
--   Informe e-mail + senha e marque "Auto Confirm User".
--   NÃO use "Invite user": o link do e-mail aponta para um endereço
--   que não existe e o app não tem tela para receber convite.
--
-- Este bloco não pede e-mail nenhum: ele liga TODAS as contas do projeto
-- ao grupo. Isso é seguro porque o cadastro público está desligado, então
-- as únicas contas que existem são as que você criou à mão.
-- Rode de novo sempre que criar ou recriar um usuário.
-- ------------------------------------------------------------
insert into household(name)
select 'Casal' where not exists (select 1 from household);

with alvo as (
  select coalesce(
    (select household_id from trip group by household_id order by count(*) desc limit 1),
    (select id from household order by id limit 1)
  ) as id
)
insert into household_member(household_id, user_id)
select alvo.id, u.id from alvo, auth.users u
on conflict do nothing;

-- Confira: todo e-mail precisa ter um household_id preenchido.
-- Se algum vier vazio, essa pessoa verá "Esta conta não tem acesso aos
-- dados do casal" ao entrar.
select u.email, m.household_id
from auth.users u left join household_member m on m.user_id = u.id;


-- ------------------------------------------------------------
-- PASSO 4 — Migrar os dados que já existem (app_state -> tabelas novas)
-- Nada é apagado: o app_state continua lá como backup.
-- ------------------------------------------------------------
do $$
declare hid uuid; s jsonb;
begin
  select id into hid from household limit 1;
  select data into s from app_state where id = 'shared';
  if s is null then
    raise notice 'Nada em app_state para migrar.';
    return;
  end if;

  insert into settings(household_id, people, cats, last_fuel)
  values (hid,
          coalesce(s->'people',   '[]'::jsonb),
          coalesce(s->'cats',     '[]'::jsonb),
          coalesce(s->'lastFuel', '{}'::jsonb))
  on conflict (household_id) do update
    set people = excluded.people, cats = excluded.cats, last_fuel = excluded.last_fuel;

  insert into trip(id, household_id, name, date_iso, expenses)
  select t->>'id', hid, t->>'name',
         nullif(t->>'dateISO','')::date,
         coalesce(t->'expenses','[]'::jsonb)
  from jsonb_array_elements(coalesce(s->'trips','[]'::jsonb)) t
  on conflict (id) do nothing;

  insert into paid(household_id, key, at)
  select hid, e.k, nullif(e.v->>'at','')::date
  from jsonb_each(coalesce(s->'paid','{}'::jsonb)) as e(k, v)
  on conflict do nothing;
end $$;

-- Confira que veio tudo (compare com o app antigo antes de seguir):
select (select count(*) from trip) as viagens,
       (select count(*) from paid) as periodos_pagos,
       (select jsonb_array_length(people) from settings) as pessoas;


-- ------------------------------------------------------------
-- PASSO 5 — Fechar a porta antiga
-- Só rode DEPOIS de entrar no app novo e confirmar que está tudo lá.
-- Isso não apaga o app_state, só tira o acesso público a ele.
-- ------------------------------------------------------------
-- drop policy if exists "acesso_publico" on app_state;
