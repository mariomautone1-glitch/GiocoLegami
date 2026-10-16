-- GiocoLegami, aggiornamento 2: segnalazioni e utenti bloccati nelle recensioni dei giochi.
-- Da eseguire UNA SOLA VOLTA nel progetto Supabase di CineLegami, dopo giocolegami-supabase.sql:
-- Supabase > SQL Editor > New query > incolla tutto > Run.
-- Usa la tabella "blocks" che CineLegami ha già: chi blocchi su un sito è bloccato anche sull'altro.

-- 1. Recensioni nascoste dopo più segnalazioni
alter table public.game_reviews add column if not exists hidden boolean not null default false;

-- l'autore può cambiare voto e testo, ma non togliere da solo il "nascosta"
revoke update on public.game_reviews from authenticated;
grant update (user_id, game_id, title, year, cover, rating, body) on public.game_reviews to authenticated;

-- 2. Chi ho bloccato io (funzione di supporto usata dalle regole di lettura)
create or replace function public.gl_bloccato(autore uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.blocks b where b.blocker_id = (select auth.uid()) and b.blocked_id = autore)
$$;
revoke all on function public.gl_bloccato(uuid) from public;
grant execute on function public.gl_bloccato(uuid) to anon, authenticated;

-- 3. Lettura delle recensioni: niente recensioni nascoste (tranne le proprie) e niente utenti bloccati
drop policy if exists "recensioni giochi: lettura pubblica" on public.game_reviews;
create policy "recensioni giochi: lettura pubblica" on public.game_reviews
  for select to anon, authenticated
  using ((not hidden or user_id = (select auth.uid())) and not public.gl_bloccato(user_id));

-- 4. Segnalazioni (private: le leggi solo tu dal pannello di Supabase)
create table if not exists public.game_reports (
  id             bigint generated always as identity primary key,
  reporter_id    uuid   not null references public.profiles(id) on delete cascade,
  review_user_id uuid   not null,
  game_id        bigint not null,
  reason         text   not null check (reason in ('offensivo','spam','nome_foto','altro')),
  note           text   check (note is null or char_length(note) <= 300),
  created_at     timestamptz not null default now(),
  unique (reporter_id, review_user_id, game_id),
  foreign key (review_user_id, game_id) references public.game_reviews(user_id, game_id) on delete cascade,
  check (reporter_id <> review_user_id)
);
alter table public.game_reports enable row level security;
drop policy if exists "segnalazioni giochi: invia l'utente" on public.game_reports;
create policy "segnalazioni giochi: invia l'utente" on public.game_reports
  for insert to authenticated with check ((select auth.uid()) = reporter_id);
revoke all on public.game_reports from anon, authenticated;
grant insert (reporter_id, review_user_id, game_id, reason, note) on public.game_reports to authenticated;

-- al massimo 20 segnalazioni al giorno per persona
create or replace function public.gl_limite_segnalazioni() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.game_reports r
      where r.reporter_id = new.reporter_id and r.created_at > now() - interval '1 day') >= 20 then
    raise exception 'troppe segnalazioni, riprova domani';
  end if;
  return new;
end $$;
drop trigger if exists gl_limite_segnalazioni on public.game_reports;
create trigger gl_limite_segnalazioni before insert on public.game_reports
  for each row execute function public.gl_limite_segnalazioni();

-- con 3 segnalazioni di persone diverse la recensione viene nascosta agli altri
create or replace function public.gl_nascondi_segnalate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(distinct r.reporter_id) from public.game_reports r
      where r.review_user_id = new.review_user_id and r.game_id = new.game_id) >= 3 then
    update public.game_reviews set hidden = true
      where user_id = new.review_user_id and game_id = new.game_id;
  end if;
  return new;
end $$;
drop trigger if exists gl_nascondi_segnalate on public.game_reports;
create trigger gl_nascondi_segnalate after insert on public.game_reports
  for each row execute function public.gl_nascondi_segnalate();

-- Per rimettere visibile una recensione dopo averla controllata:
--   update public.game_reviews set hidden = false where user_id = '...' and game_id = ...;
