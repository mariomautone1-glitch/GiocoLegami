-- GiocoLegami: giochi giocati, voti in coppe e recensioni.
-- Da eseguire UNA SOLA VOLTA nel progetto Supabase già usato da CineLegami:
-- Supabase > SQL Editor > New query > incolla tutto > Run.
-- Usa gli stessi account e profili di CineLegami e non tocca le tabelle dei film.

-- Giochi segnati come giocati (privati: li vede solo chi li ha segnati)
create table if not exists public.game_seen (
  user_id  uuid   not null references public.profiles(id) on delete cascade,
  game_id  bigint not null check (game_id > 0),
  title    text   not null default '' check (char_length(title) <= 200),
  year     text   check (year is null or year ~ '^[0-9]{4}$'),
  cover    text   check (cover is null or cover ~ '^[A-Za-z0-9_]{1,64}$'),
  seen_at  timestamptz not null default now(),
  primary key (user_id, game_id)
);

-- Voti (da 1 a 5 coppe) e recensioni (pubblici)
create table if not exists public.game_reviews (
  user_id    uuid   not null references public.profiles(id) on delete cascade,
  game_id    bigint not null check (game_id > 0),
  title      text   not null default '' check (char_length(title) <= 200),
  year       text   check (year is null or year ~ '^[0-9]{4}$'),
  cover      text   check (cover is null or cover ~ '^[A-Za-z0-9_]{1,64}$'),
  rating     smallint not null check (rating between 1 and 5),
  body       text   check (body is null or char_length(body) between 1 and 1500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, game_id)
);
create index if not exists game_reviews_game_idx on public.game_reviews (game_id, updated_at desc);

-- La data di modifica la mette il database, non il browser
create or replace function public.gl_touch() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists gl_touch_reviews on public.game_reviews;
create trigger gl_touch_reviews before update on public.game_reviews
  for each row execute function public.gl_touch();

-- Regole di accesso
alter table public.game_seen    enable row level security;
alter table public.game_reviews enable row level security;

drop policy if exists "giocati: solo i propri" on public.game_seen;
create policy "giocati: solo i propri" on public.game_seen
  for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "recensioni giochi: lettura pubblica" on public.game_reviews;
create policy "recensioni giochi: lettura pubblica" on public.game_reviews
  for select to anon, authenticated using (true);
drop policy if exists "recensioni giochi: scrive l'autore" on public.game_reviews;
create policy "recensioni giochi: scrive l'autore" on public.game_reviews
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "recensioni giochi: modifica l'autore" on public.game_reviews;
create policy "recensioni giochi: modifica l'autore" on public.game_reviews
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "recensioni giochi: elimina l'autore" on public.game_reviews;
create policy "recensioni giochi: elimina l'autore" on public.game_reviews
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Media dei voti per gioco
create or replace view public.game_stats with (security_invoker = true) as
  select game_id, count(*)::int as n, round(avg(rating)::numeric, 2) as avg
  from public.game_reviews group by game_id;

revoke all on public.game_seen, public.game_reviews, public.game_stats from anon, authenticated;
grant select, insert, update, delete on public.game_seen to authenticated;
grant select on public.game_reviews to anon;
grant select, insert, update, delete on public.game_reviews to authenticated;
grant select on public.game_stats to anon, authenticated;
