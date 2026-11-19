-- Депость: онлайн (таблица лидеров, общий LIVE, онлайн-батлы).
-- Supabase → SQL Editor → New query → вставь всё целиком → Run.

-- ===== игроки и таблица лидеров =====
create table if not exists public.players (
  id uuid primary key default auth.uid() references auth.users on delete cascade,
  name text not null check (char_length(name) between 2 and 24),
  color text default '#7565ff',
  balance bigint not null default 0,
  inv_value bigint not null default 0,
  cases int not null default 0,
  best_name text,
  best_price bigint not null default 0,
  best_img text,
  updated_at timestamptz not null default now()
);
alter table public.players add column if not exists wealth bigint not null default 0;
create index if not exists players_wealth on public.players (wealth desc);
alter table public.players enable row level security;
drop policy if exists "players read" on public.players;
drop policy if exists "players insert own" on public.players;
drop policy if exists "players update own" on public.players;
create policy "players read" on public.players for select using (true);
create policy "players insert own" on public.players for insert with check (auth.uid() = id);
create policy "players update own" on public.players for update using (auth.uid() = id);

-- ===== общий LIVE =====
create table if not exists public.feed (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  item text not null,
  rarity smallint not null,
  price bigint not null,
  img text,
  created_at timestamptz not null default now()
);
alter table public.feed enable row level security;
drop policy if exists "feed read" on public.feed;
drop policy if exists "feed insert own" on public.feed;
create policy "feed read" on public.feed for select using (true);
create policy "feed insert own" on public.feed for insert with check (auth.uid() = user_id);
create index if not exists feed_created on public.feed (created_at desc);

-- ===== комнаты онлайн-батлов =====
create table if not exists public.rooms (
  code text primary key,
  host uuid not null default auth.uid() references auth.users on delete cascade,
  kind text not null check (kind in ('dep','cb')),
  config jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open','spinning','done')),
  winner uuid,
  result jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.room_players (
  room text not null references public.rooms(code) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  color text,
  stake jsonb not null default '{}'::jsonb,
  value bigint not null default 0,
  joined_at timestamptz not null default now(),
  primary key (room, user_id)
);
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
drop policy if exists "rooms read" on public.rooms;
drop policy if exists "rooms create" on public.rooms;
drop policy if exists "rp read" on public.room_players;
drop policy if exists "rp join" on public.room_players;
drop policy if exists "rp update own" on public.room_players;
drop policy if exists "rp leave" on public.room_players;
create policy "rooms read" on public.rooms for select using (true);
create policy "rooms create" on public.rooms for insert with check (auth.uid() = host);
create policy "rp read" on public.room_players for select using (true);
create policy "rp join" on public.room_players for insert with check (
  auth.uid() = user_id and exists (select 1 from public.rooms r where r.code = room and r.status = 'open'));
create policy "rp update own" on public.room_players for update using (
  auth.uid() = user_id and exists (select 1 from public.rooms r where r.code = room and r.status = 'open'));
create policy "rp leave" on public.room_players for delete using (
  auth.uid() = user_id and exists (select 1 from public.rooms r where r.code = room and r.status = 'open'));

-- Крутить комнату может только её создатель. Победителя выбирает сервер, а не телефон.
create or replace function public.spin_room(p_code text)
returns public.rooms
language plpgsql security definer set search_path = public as $$
declare
  r public.rooms;
  total bigint;
  pick double precision;
  acc bigint := 0;
  w uuid;
  rp record;
begin
  select * into r from public.rooms where code = p_code for update;
  if r is null then raise exception 'room not found'; end if;
  if r.host <> auth.uid() then raise exception 'only host can start'; end if;
  if r.status <> 'open' then raise exception 'already started'; end if;
  if (select count(*) from public.room_players where room = p_code) < 2 then raise exception 'need 2 players'; end if;

  if r.kind = 'dep' then
    select coalesce(sum(value), 0) into total from public.room_players where room = p_code;
    if total <= 0 then raise exception 'empty pot'; end if;
    pick := random() * total;
    for rp in select user_id, value from public.room_players where room = p_code order by joined_at loop
      acc := acc + rp.value;
      if w is null and pick < acc then w := rp.user_id; end if;
    end loop;
    update public.rooms set status = 'done', winner = w,
      result = jsonb_build_object('pick', pick, 'total', total)
      where code = p_code returning * into r;
  else
    -- кейс-батл: сервер выдаёт общее зерно, все телефоны одинаково прокручивают по нему кейсы
    update public.rooms set status = 'done',
      result = jsonb_build_object('seed', floor(random() * 2147483647)::bigint)
      where code = p_code returning * into r;
  end if;
  return r;
end $$;
grant execute on function public.spin_room(text) to authenticated;

-- ===== живые обновления =====
do $$ begin
  begin alter publication supabase_realtime add table public.feed; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.rooms; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.room_players; exception when duplicate_object then null; end;
end $$;
