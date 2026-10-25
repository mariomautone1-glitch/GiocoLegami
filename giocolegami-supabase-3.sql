-- GiocoLegami, aggiornamento 3: consigli alla community e giochi simili secondo la community.
-- Da eseguire UNA SOLA VOLTA nel progetto Supabase di CineLegami, dopo giocolegami-supabase.sql e giocolegami-supabase-2.sql:
-- Supabase > SQL Editor > New query > incolla tutto > Run.
-- Non tocca le tabelle dei film.

-- 1. Consigli: «questo gioco vale la pena», con il perché (pubblici)
create table if not exists public.game_recos (
  user_id    uuid   not null references public.profiles(id) on delete cascade,
  game_id    bigint not null check (game_id > 0),
  title      text   not null default '' check (char_length(title) <= 200),
  year       text   check (year is null or year ~ '^[0-9]{4}$'),
  cover      text   check (cover is null or cover ~ '^[A-Za-z0-9_]{1,64}$'),
  fam        text[] not null default '{}' check (fam <@ array['ps','xbox','switch','pc']::text[] and cardinality(fam) <= 4),
  body       text   not null check (char_length(btrim(body)) between 10 and 500),
  hidden     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, game_id)
);
create index if not exists game_recos_game_idx on public.game_recos (game_id, updated_at desc);
drop trigger if exists gl_touch_recos on public.game_recos;
create trigger gl_touch_recos before update on public.game_recos
  for each row execute function public.gl_touch();

alter table public.game_recos enable row level security;
drop policy if exists "consigli giochi: lettura pubblica" on public.game_recos;
create policy "consigli giochi: lettura pubblica" on public.game_recos
  for select to anon, authenticated
  using ((not hidden or user_id = (select auth.uid())) and not public.gl_bloccato(user_id));
drop policy if exists "consigli giochi: scrive l'autore" on public.game_recos;
create policy "consigli giochi: scrive l'autore" on public.game_recos
  for insert to authenticated with check ((select auth.uid()) = user_id and not hidden);
drop policy if exists "consigli giochi: modifica l'autore" on public.game_recos;
create policy "consigli giochi: modifica l'autore" on public.game_recos
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "consigli giochi: elimina l'autore" on public.game_recos;
create policy "consigli giochi: elimina l'autore" on public.game_recos
  for delete to authenticated using ((select auth.uid()) = user_id);

-- quante persone consigliano ogni gioco (senza consigli nascosti né utenti bloccati)
drop view if exists public.game_reco_stats;
create view public.game_reco_stats with (security_invoker = true) as
  select game_id, count(*)::int as n,
         (array_agg(title order by updated_at desc))[1] as title,
         (array_agg(year  order by updated_at desc))[1] as year,
         (array_agg(cover order by updated_at desc))[1] as cover,
         (array_agg(array_to_string(fam, ',') order by updated_at desc))[1] as fam,
         max(updated_at) as last_at
  from public.game_recos group by game_id;

revoke all on public.game_recos, public.game_reco_stats from anon, authenticated;
grant select on public.game_recos to anon;
grant select, insert, delete on public.game_recos to authenticated;
grant update (user_id, game_id, title, year, cover, fam, body) on public.game_recos to authenticated;
grant select on public.game_reco_stats to anon, authenticated;

-- 2. Segnalazioni dei consigli (private)
create table if not exists public.game_reco_reports (
  id           bigint generated always as identity primary key,
  reporter_id  uuid   not null references public.profiles(id) on delete cascade,
  reco_user_id uuid   not null,
  game_id      bigint not null,
  reason       text   not null check (reason in ('offensivo','spam','nome_foto','altro')),
  note         text   check (note is null or char_length(note) <= 300),
  created_at   timestamptz not null default now(),
  unique (reporter_id, reco_user_id, game_id),
  foreign key (reco_user_id, game_id) references public.game_recos(user_id, game_id) on delete cascade,
  check (reporter_id <> reco_user_id)
);
alter table public.game_reco_reports enable row level security;
drop policy if exists "segnalazioni consigli giochi: invia l'utente" on public.game_reco_reports;
create policy "segnalazioni consigli giochi: invia l'utente" on public.game_reco_reports
  for insert to authenticated with check ((select auth.uid()) = reporter_id);
revoke all on public.game_reco_reports from anon, authenticated;
grant insert (reporter_id, reco_user_id, game_id, reason, note) on public.game_reco_reports to authenticated;

-- al massimo 20 segnalazioni al giorno per persona, contando recensioni e consigli insieme
create or replace function public.gl_limite_segnalazioni_consigli() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.game_reco_reports r
      where r.reporter_id = new.reporter_id and r.created_at > now() - interval '1 day')
   + (select count(*) from public.game_reports r
      where r.reporter_id = new.reporter_id and r.created_at > now() - interval '1 day') >= 20 then
    raise exception 'troppe segnalazioni, riprova domani';
  end if;
  return new;
end $$;
drop trigger if exists gl_limite_segnalazioni_consigli on public.game_reco_reports;
create trigger gl_limite_segnalazioni_consigli before insert on public.game_reco_reports
  for each row execute function public.gl_limite_segnalazioni_consigli();

-- con 3 segnalazioni di persone diverse il consiglio viene nascosto agli altri
create or replace function public.gl_nascondi_consigli() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(distinct r.reporter_id) from public.game_reco_reports r
      where r.reco_user_id = new.reco_user_id and r.game_id = new.game_id) >= 3 then
    update public.game_recos set hidden = true
      where user_id = new.reco_user_id and game_id = new.game_id;
  end if;
  return new;
end $$;
drop trigger if exists gl_nascondi_consigli on public.game_reco_reports;
create trigger gl_nascondi_consigli after insert on public.game_reco_reports
  for each row execute function public.gl_nascondi_consigli();

-- 3. «Questi due giochi si somigliano»: i voti di somiglianza (privati, contano solo i totali)
create table if not exists public.game_sim_votes (
  user_id  uuid   not null references public.profiles(id) on delete cascade,
  game_a   bigint not null check (game_a > 0),
  game_b   bigint not null check (game_b > 0),
  title_a  text   not null default '' check (char_length(title_a) <= 200),
  title_b  text   not null default '' check (char_length(title_b) <= 200),
  year_a   text   check (year_a is null or year_a ~ '^[0-9]{4}$'),
  year_b   text   check (year_b is null or year_b ~ '^[0-9]{4}$'),
  cover_a  text   check (cover_a is null or cover_a ~ '^[A-Za-z0-9_]{1,64}$'),
  cover_b  text   check (cover_b is null or cover_b ~ '^[A-Za-z0-9_]{1,64}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, game_a, game_b),
  check (game_a < game_b)
);
create index if not exists game_sim_a_idx on public.game_sim_votes (game_a);
create index if not exists game_sim_b_idx on public.game_sim_votes (game_b);
alter table public.game_sim_votes enable row level security;
drop policy if exists "somiglianze: solo le proprie" on public.game_sim_votes;
create policy "somiglianze: solo le proprie" on public.game_sim_votes
  for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
revoke all on public.game_sim_votes from anon, authenticated;
grant select, insert, delete on public.game_sim_votes to authenticated;

-- al massimo 100 somiglianze al giorno per persona (contro lo spam)
create or replace function public.gl_limite_somiglianze() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.game_sim_votes s
      where s.user_id = new.user_id and s.created_at > now() - interval '1 day') >= 100 then
    raise exception 'troppe somiglianze, riprova domani';
  end if;
  return new;
end $$;
drop trigger if exists gl_limite_somiglianze on public.game_sim_votes;
create trigger gl_limite_somiglianze before insert on public.game_sim_votes
  for each row execute function public.gl_limite_somiglianze();

-- serve per contare in fretta chi ha giocato un gioco
create index if not exists game_seen_game_idx on public.game_seen (game_id);

-- 4. Giochi simili secondo la community, per un gioco:
--    voti   = persone che hanno detto «si somigliano»
--    giocati = persone che li hanno giocati entrambi (solo se sono almeno 3, e mai chi sono)
--    piaciuti = persone che li hanno votati entrambi con almeno 4 coppe (solo se sono almeno 2)
create or replace function public.gl_simili_community(gid bigint)
returns table (game_id bigint, title text, year text, cover text, voti int, giocati int, piaciuti int)
language sql stable security definer set search_path = '' as $$
  with v as (
    select case when s.game_a = gid then s.game_b  else s.game_a  end as g,
           case when s.game_a = gid then s.title_b else s.title_a end as t,
           case when s.game_a = gid then s.year_b  else s.year_a  end as y,
           case when s.game_a = gid then s.cover_b else s.cover_a end as c,
           s.user_id
    from public.game_sim_votes s
    where (s.game_a = gid or s.game_b = gid) and not public.gl_bloccato(s.user_id)
  ), vv as (
    select g, count(distinct user_id)::int as n, max(t) as t, max(y) as y, max(c) as c from v group by g
  ), p as (
    select o.game_id as g, count(*)::int as n, max(o.title) as t, max(o.year) as y, max(o.cover) as c
    from public.game_seen me join public.game_seen o on o.user_id = me.user_id and o.game_id <> me.game_id
    where me.game_id = gid group by o.game_id having count(*) >= 3
  ), l as (
    select o.game_id as g, count(*)::int as n, max(o.title) as t, max(o.year) as y, max(o.cover) as c
    from public.game_reviews me join public.game_reviews o on o.user_id = me.user_id and o.game_id <> me.game_id
    where me.game_id = gid and me.rating >= 4 and o.rating >= 4 and not me.hidden and not o.hidden
      and not public.gl_bloccato(me.user_id)
    group by o.game_id having count(*) >= 2
  ), k as (select g from vv union select g from p union select g from l)
  select k.g, coalesce(nullif(vv.t,''), nullif(l.t,''), p.t, ''), coalesce(vv.y, l.y, p.y), coalesce(vv.c, l.c, p.c),
         coalesce(vv.n, 0), coalesce(p.n, 0), coalesce(l.n, 0)
  from k left join vv on vv.g = k.g left join p on p.g = k.g left join l on l.g = k.g
  where k.g <> gid
  order by coalesce(vv.n, 0) * 4 + coalesce(l.n, 0) * 2 + coalesce(p.n, 0) desc, k.g
  limit 24
$$;
revoke all on function public.gl_simili_community(bigint) from public;
grant execute on function public.gl_simili_community(bigint) to anon, authenticated;

-- Per rimettere visibile un consiglio dopo averlo controllato:
--   update public.game_recos set hidden = false where user_id = '...' and game_id = ...;
