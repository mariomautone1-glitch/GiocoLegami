-- GiocoLegami, aggiornamento 4: voto in percentuale (da 0 a 100%) al posto delle coppe.
-- Da eseguire UNA SOLA VOLTA nel progetto Supabase di CineLegami, dopo giocolegami-supabase-3.sql:
-- Supabase > SQL Editor > New query > incolla tutto > Run.
-- I voti già dati restano: 1 coppa = 20%, 2 = 40%, 3 = 60%, 4 = 80%, 5 = 100%.

-- 1. Il voto in percentuale (la colonna "rating" da 1 a 5 resta, calcolata dal sito, per compatibilità)
alter table public.game_reviews add column if not exists score smallint
  check (score is null or score between 0 and 100);
grant update (score) on public.game_reviews to authenticated;

-- 2. Media per gioco: anche in percentuale
create or replace view public.game_stats with (security_invoker = true) as
  select game_id, count(*)::int as n, round(avg(rating)::numeric, 2) as avg,
         round(avg(coalesce(score, rating * 20))::numeric, 0)::int as avg_pct
  from public.game_reviews group by game_id;
grant select on public.game_stats to anon, authenticated;

-- 3. Giochi simili: «fan in comune» = chi li ha votati entrambi almeno 70%
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
    where me.game_id = gid and coalesce(me.score, me.rating * 20) >= 70 and coalesce(o.score, o.rating * 20) >= 70
      and not me.hidden and not o.hidden
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
