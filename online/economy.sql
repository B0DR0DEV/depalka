-- ======================================================================
-- Депость: серверная экономика (Сезон 1).
-- Всё, что стоит денег, считает сервер. Телефон только показывает анимацию.
-- Таблицы закрыты для сайта, доступ только через функции api_*.
-- ВНИМАНИЕ: удаляет старые онлайн-таблицы (players, feed, rooms, room_players).
-- ======================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- старые онлайн-таблицы (до Сезона 1) удаляются только один раз; файл можно запускать повторно
do $$ begin
  if to_regclass('public.players') is not null then
    drop function if exists public.spin_room(text);
    drop table if exists public.room_players cascade;
    drop table if exists public.rooms cascade;
    drop table if exists public.feed cascade;
    drop table if exists public.players cascade;
  end if;
end $$;

-- ---------- каталог ----------
create table if not exists public.catalog_items (
  id text primary key,
  name text not null,
  rarity smallint not null check (rarity between 0 and 4),
  set text not null,
  img text
);
-- у скинов CS2 своя рыночная цена; у мемов цена считается от редкости и множителя кейса
alter table public.catalog_items add column if not exists base_price bigint;
create table if not exists public.catalog_cases (
  id text primary key,
  name text not null,
  price bigint not null,
  weights int[] not null,
  mult numeric not null default 1,
  set text not null default 'mell',
  perk text,
  active boolean not null default true
);
-- у некоторых кейсов свой список предметов с весами: [[id, вес], ...]
alter table public.catalog_cases add column if not exists drops jsonb;

-- ---------- сезоны и игроки ----------
create table if not exists public.seasons (
  id int primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  winner uuid,
  winner_name text,
  finalized boolean not null default false
);
create table if not exists public.wallets (
  user_id uuid primary key references auth.users on delete cascade,
  name text not null default 'Игрок',
  color text not null default '#7565ff',
  balance bigint not null default 500 check (balance >= 0),
  cases int not null default 0,
  season int,
  season_points bigint not null default 0,
  best_item text,
  best_price bigint not null default 0,
  eggs int not null default 0,
  bonus_at timestamptz,
  streak int not null default 0,
  streak_day date,
  created_at timestamptz not null default now()
);
create table if not exists public.inventory (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  item_id text not null references public.catalog_items(id),
  price bigint not null,
  locked text,
  created_at timestamptz not null default now()
);
create index if not exists inventory_user on public.inventory (user_id);
create index if not exists inventory_locked on public.inventory (locked) where locked is not null;
create table if not exists public.free_log (user_id uuid not null, at timestamptz not null default now());
create index if not exists free_log_user on public.free_log (user_id, at);
create table if not exists public.perks (user_id uuid not null references auth.users on delete cascade, perk text not null, primary key (user_id, perk));
create table if not exists public.promo_codes (hash text primary key, perk text not null, used_by uuid, used_at timestamptz);

create table if not exists public.feed (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  name text not null,
  item_id text not null,
  price bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists feed_created on public.feed (created_at desc);

create table if not exists public.crash_games (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  bet bigint not null,
  auto numeric not null default 0,
  cp numeric not null,
  started_at timestamptz not null default clock_timestamp(),
  cashout numeric,
  win bigint not null default 0,
  done boolean not null default false
);

create table if not exists public.rooms (
  code text primary key,
  host uuid not null,
  kind text not null check (kind in ('dep','cb')),
  cases text[] not null default '{}',
  status text not null default 'open' check (status in ('open','done')),
  winner uuid,
  result jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.room_players (
  room text not null references public.rooms(code) on delete cascade,
  user_id uuid not null,
  name text not null,
  color text,
  coins bigint not null default 0,
  value bigint not null default 0,
  joined_at timestamptz not null default clock_timestamp(),
  primary key (room, user_id)
);
create table if not exists public.room_events (
  id bigint generated always as identity primary key,
  room text not null,
  user_id uuid not null,
  name text not null,
  emoji text not null,
  at timestamptz not null default now()
);

create table if not exists public.trades (
  id bigint generated always as identity primary key,
  from_user uuid not null,
  to_user uuid not null,
  give_items bigint[] not null default '{}',
  give_coins bigint not null default 0,
  want_items bigint[] not null default '{}',
  want_coins bigint not null default 0,
  snapshot jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open','done','declined','cancelled','failed')),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
create index if not exists trades_to on public.trades (to_user, status);
create index if not exists trades_from on public.trades (from_user, status);

create table if not exists public.quests (
  user_id uuid not null,
  day date not null,
  qid text not null,
  kind text not null,
  goal int not null,
  reward int not null,
  progress int not null default 0,
  claimed boolean not null default false,
  primary key (user_id, day, qid)
);

-- подписка на Telegram-канал: игра выдаёт ссылку на бота, бот проверяет подписку и подтверждает
create table if not exists public.subs (
  token text primary key,
  user_id uuid not null references auth.users on delete cascade,
  tg_id bigint unique,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create table if not exists public.bot_config (k text primary key, v text not null);
-- отписался от канала → плюшки забираются; потом можно подписаться снова
alter table public.subs add column if not exists revoked_at timestamptz;
alter table public.subs add column if not exists badge_id bigint;
alter table public.subs drop constraint if exists subs_tg_id_key;
create unique index if not exists subs_tg_active on public.subs (tg_id) where tg_id is not null and revoked_at is null;

-- общий чат игроков
create table if not exists public.chat (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  name text not null,
  color text,
  body text not null,
  created_at timestamptz not null default now()
);

-- админка: кто админ, события «админ абьюз», журнал действий
create table if not exists public.admins (user_id uuid primary key references auth.users on delete cascade, added_at timestamptz not null default now());
create table if not exists public.events (
  id bigint generated always as identity primary key,
  kind text not null,
  power numeric not null default 1,
  ends_at timestamptz not null,
  note text,
  by_name text,
  created_at timestamptz not null default now()
);
create table if not exists public.admin_log (id bigint generated always as identity primary key, admin uuid, action text, details jsonb, at timestamptz not null default now());
-- ежедневный кейс: день последнего открытия
alter table public.wallets add column if not exists daily_case date;

-- все таблицы закрыты: только функции api_* (они работают от владельца базы)
do $$ declare t text; begin
  foreach t in array array['catalog_items','catalog_cases','seasons','wallets','inventory','free_log','perks','promo_codes','feed','crash_games','rooms','room_players','room_events','trades','quests','subs','bot_config','chat','admins','events','admin_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ======================================================================
-- служебные функции
-- ======================================================================
create or replace function public.msk_today() returns date language sql stable as $$ select (now() at time zone 'Europe/Moscow')::date $$;
create or replace function public.base_price(r int) returns bigint language sql immutable as $$ select (array[15,60,200,800,4000])[r+1]::bigint $$;
create or replace function public.roll_price(r int, m numeric) returns bigint language sql volatile as $$ select greatest(1, round(public.base_price(r) * m * (0.8 + random()*0.4)))::bigint $$;
create or replace function public.item_price(it public.catalog_items, m numeric) returns bigint language sql volatile as $$
  select case when it.base_price is null then public.roll_price(it.rarity, m)
              when it.set = 'cs' then greatest(1, round(it.base_price * (0.85 + random()*0.3)))::bigint
              else it.base_price end $$;
create or replace function public.is_admin(u uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = u) $$;
-- сила активного события (удача ×N, скидка N%); 0 — события нет
create or replace function public.event_power(k text) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(max(power), 0) from public.events where kind = k and ends_at > now() $$;
create or replace function public.me() returns uuid language plpgsql stable as $$
begin if auth.uid() is null then raise exception 'not_signed_in'; end if; return auth.uid(); end $$;

create or replace function public.season_cur() returns int language plpgsql security definer set search_path = public as $$
declare s public.seasons; w record;
begin
  select * into s from public.seasons order by id desc limit 1;
  if s.id is not null and now() < s.ends_at then return s.id; end if;
  perform pg_advisory_xact_lock(4242);
  select * into s from public.seasons order by id desc limit 1;
  if s.id is null then
    insert into public.seasons(id, starts_at, ends_at) values (1, now(), now() + interval '7 days');
    return 1;
  end if;
  if now() < s.ends_at then return s.id; end if;
  if not s.finalized then
    select user_id, name into w from public.wallets where season = s.id and season_points > 0 order by season_points desc limit 1;
    if w.user_id is not null then
      insert into public.catalog_items(id, name, rarity, set) values ('crown-s' || s.id, '👑 Король сезона ' || s.id, 4, 'special') on conflict (id) do nothing;
      insert into public.inventory(user_id, item_id, price) values (w.user_id, 'crown-s' || s.id, 25000);
      update public.seasons set winner = w.user_id, winner_name = w.name where id = s.id;
    end if;
    update public.seasons set finalized = true where id = s.id;
  end if;
  insert into public.seasons(id, starts_at, ends_at) values (s.id + 1, now(), now() + interval '7 days') on conflict (id) do nothing;
  return s.id + 1;
end $$;

-- кошелёк текущего игрока (создаётся при первом заходе, сезонные очки сбрасываются)
create or replace function public.w_get() returns public.wallets language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); w public.wallets; s int := public.season_cur();
begin
  select * into w from public.wallets where user_id = u for update;
  if w.user_id is null then
    insert into public.wallets(user_id, season) values (u, s) returning * into w;
  elsif w.season is distinct from s then
    update public.wallets set season = s, season_points = 0 where user_id = u returning * into w;
  end if;
  return w;
end $$;

create or replace function public.has_perk(u uuid, k text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perks where user_id = u and perk = k) $$;

create or replace function public.pool_items(p_set text) returns setof public.catalog_items language sql stable security definer set search_path = public as $$
  select * from public.catalog_items
  where case when p_set = 'secret' then rarity >= 3 and set <> 'special' and set not like 'pk:%'
             when p_set = 'all' then set <> 'special'
             else set = p_set end $$;

create or replace function public.pick_item(p_set text, p_w int[]) returns public.catalog_items language plpgsql volatile security definer set search_path = public as $$
declare rs smallint[]; tot numeric := 0; x numeric; r smallint; chosen smallint; it public.catalog_items; lk numeric := greatest(1, public.event_power('luck'));
begin
  select array_agg(distinct i.rarity order by i.rarity) into rs from public.pool_items(p_set) i where coalesce(p_w[i.rarity + 1], 0) > 0;
  if rs is null then raise exception 'empty_case'; end if;
  -- во время «удачи» тайное и легенды выпадают в lk раз чаще
  foreach r in array rs loop tot := tot + p_w[r + 1] * case when r >= 3 then lk else 1 end; end loop;
  x := random() * tot;
  foreach r in array rs loop chosen := r; x := x - p_w[r + 1] * case when r >= 3 then lk else 1 end; exit when x <= 0; end loop;
  select * into it from public.pool_items(p_set) i where i.rarity = chosen order by random() limit 1;
  return it;
end $$;

create or replace function public.pick_case(c public.catalog_cases) returns public.catalog_items language plpgsql volatile security definer set search_path = public as $$
declare tot numeric; x numeric; d jsonb; it public.catalog_items; lk numeric := greatest(1, public.event_power('luck')); raw numeric;
begin
  if c.drops is null then return public.pick_item(c.set, c.weights); end if;
  select sum((e->>1)::numeric) into raw from jsonb_array_elements(c.drops) e;
  -- во время «удачи» самые редкие предметы (меньше 5% шанса) выпадают в lk раз чаще
  select sum((e->>1)::numeric * case when (e->>1)::numeric < raw * 0.05 then lk else 1 end) into tot from jsonb_array_elements(c.drops) e;
  x := random() * tot;
  for d in select * from jsonb_array_elements(c.drops) loop
    x := x - (d->>1)::numeric * case when (d->>1)::numeric < raw * 0.05 then lk else 1 end;
    if x <= 0 then select * into it from public.catalog_items where id = d->>0; return it; end if;
  end loop;
  select * into it from public.catalog_items where id = c.drops->0->>0; return it;
end $$;

-- выдать предмет: инвентарь + лучший дроп + LIVE
create or replace function public.give_item(u uuid, p_item text, p_price bigint, share boolean default true) returns bigint language plpgsql security definer set search_path = public as $$
declare nid bigint; r smallint; nm text;
begin
  insert into public.inventory(user_id, item_id, price) values (u, p_item, p_price) returning id into nid;
  update public.wallets set best_item = p_item, best_price = p_price where user_id = u and p_price > best_price;
  if share then
    select rarity into r from public.catalog_items where id = p_item;
    if r >= 2 or p_price >= 1000 then
      select name into nm from public.wallets where user_id = u;
      insert into public.feed(user_id, name, item_id, price) values (u, coalesce(nm, 'Игрок'), p_item, p_price);
    end if;
  end if;
  return nid;
end $$;

create or replace function public.add_points(u uuid, v bigint) returns void language sql security definer set search_path = public as $$
  update public.wallets set season_points = season_points + greatest(0, v) where user_id = u $$;

-- ежедневные задания
create or replace function public.ensure_quests(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare d date := public.msk_today();
begin
  if exists (select 1 from public.quests where user_id = u and day = d) then return; end if;
  insert into public.quests(user_id, day, qid, kind, goal, reward)
  select u, d, q.qid, q.kind, q.goal, q.reward from (values
    ('cases20','cases',20,300),('cases50','cases',50,600),('battle','battle',1,400),('crash3','crash',1,300),
    ('upgrade','upgrade',1,350),('sell','sell',2000,250),('contract','contract',1,300),('roulette','roulette',10,200)
  ) as q(qid, kind, goal, reward)
  order by md5(u::text || d::text || q.qid) limit 3;
end $$;
create or replace function public.quest_bump(u uuid, k text, amt int) returns void language sql security definer set search_path = public as $$
  update public.quests set progress = least(goal, progress + amt) where user_id = u and day = public.msk_today() and kind = k and not claimed $$;

create or replace function public.free_info(u uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('left', greatest(0, 100 - count(*)), 'reset_s', coalesce(ceil(extract(epoch from (min(at) + interval '10 minutes' - now()))), 0))
  from public.free_log where user_id = u and at > now() - interval '10 minutes' $$;

create or replace function public.inv_json(u uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'price', price, 'locked', locked) order by id), '[]'::jsonb)
  from public.inventory where user_id = u $$;

-- краш: настоящий множитель по серверному времени
create or replace function public.crash_m(g public.crash_games) returns numeric language sql volatile as $$
  select exp(0.16 * extract(epoch from (clock_timestamp() - g.started_at)))::numeric $$;
create or replace function public.crash_settle(g public.crash_games) returns public.crash_games language plpgsql security definer set search_path = public as $$
declare m numeric;
begin
  if g.done then return g; end if;
  m := public.crash_m(g);
  if g.cashout is null and g.auto > 0 and g.auto < g.cp and m >= g.auto then
    update public.crash_games set cashout = g.auto, win = round(g.bet * g.auto) where id = g.id returning * into g;
    update public.wallets set balance = balance + g.win where user_id = g.user_id;
    perform public.add_points(g.user_id, g.win - g.bet);
    if g.auto >= 3 then perform public.quest_bump(g.user_id, 'crash', 1); end if;
  end if;
  if m >= g.cp then update public.crash_games set done = true where id = g.id returning * into g; end if;
  return g;
end $$;

-- ======================================================================
-- API: состояние
-- ======================================================================
create or replace function public.api_hello(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; d date := public.msk_today(); daily jsonb := null; rew int; s public.seasons; lst public.seasons; g public.crash_games;
begin
  if p ? 'name' and char_length(trim(p->>'name')) between 2 and 24 then
    update public.wallets set name = trim(p->>'name') where user_id = u;
  end if;
  if p ? 'color' and (p->>'color') ~ '^#[0-9a-fA-F]{6}$' then update public.wallets set color = p->>'color' where user_id = u; end if;
  if p ? 'eggs' then update public.wallets set eggs = greatest(0, least(999, (p->>'eggs')::int)) where user_id = u; end if;
  if w.streak_day is null or w.streak_day < d then
    update public.wallets set streak = case when streak_day = d - 1 then streak + 1 else 1 end, streak_day = d where user_id = u returning * into w;
    rew := 100 * least(w.streak, 7) * case when public.has_perk(u, 'subscriber') then 3 else 2 end / 2;
    update public.wallets set balance = balance + rew where user_id = u;
    daily := jsonb_build_object('streak', w.streak, 'reward', rew);
  end if;
  for g in select * from public.crash_games where user_id = u and not done loop perform public.crash_settle(g); end loop;
  perform public.ensure_quests(u);
  select * into w from public.wallets where user_id = u;
  select * into s from public.seasons order by id desc limit 1;
  select * into lst from public.seasons where finalized order by id desc limit 1;
  return jsonb_build_object(
    'me', jsonb_build_object('id', u, 'name', w.name, 'color', w.color, 'bal', w.balance, 'cases', w.cases, 'points', w.season_points, 'streak', w.streak),
    'inv', public.inv_json(u),
    'perks', coalesce((select jsonb_agg(perk) from public.perks where user_id = u), '[]'::jsonb),
    'season', jsonb_build_object('id', s.id, 'ends_at', s.ends_at, 'last_winner', lst.winner_name, 'last_id', lst.id),
    'quests', coalesce((select jsonb_agg(jsonb_build_object('qid', qid, 'kind', kind, 'goal', goal, 'reward', reward, 'progress', progress, 'claimed', claimed) order by qid) from public.quests where user_id = u and day = d), '[]'::jsonb),
    'free', public.free_info(u),
    'daily', daily,
    'trades', (select count(*) from public.trades where to_user = u and status = 'open'),
    'admin', public.is_admin(u),
    'daily_ok', w.daily_case is distinct from d,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'power', power, 'ends_at', ends_at, 'note', note, 'by', by_name) order by id)
       from public.events where ends_at > now() or created_at > now() - interval '10 minutes'), '[]'::jsonb),
    'catalog', case when p ? 'lite' then null else jsonb_build_object(
      'items', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'r', rarity, 'set', set, 'img', img)) from public.catalog_items),
      'cases', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price', price, 'w', weights, 'mult', mult, 'set', set, 'perk', perk)) from public.catalog_cases where active)) end);
end $$;

create or replace function public.api_feed(p jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', id, 'name', name, 'item', item_id, 'price', price, 'at', created_at) x
    from public.feed order by created_at desc limit 20) t $$;

create or replace function public.api_top(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_by text := coalesce(p->>'by', 'season'); s int; res jsonb;
begin
  select id into s from public.seasons order by id desc limit 1;
  select coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb) into res from (
    select w.user_id as id, w.name, w.color, w.cases, w.best_price, w.best_item,
           case when w.season = s then w.season_points else 0 end as points,
           w.balance + coalesce((select sum(price) from public.inventory i where i.user_id = w.user_id and i.locked is null), 0) as wealth
    from public.wallets w
    order by case v_by when 'cases' then w.cases::numeric when 'best' then w.best_price::numeric
                     when 'wealth' then (w.balance + coalesce((select sum(price) from public.inventory i where i.user_id = w.user_id and i.locked is null), 0))::numeric
                     else (case when w.season = s then w.season_points else 0 end)::numeric end desc
    limit 50) t;
  return res;
end $$;

create or replace function public.api_profile(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid := (p->>'user')::uuid; w public.wallets; s int;
begin
  perform public.me();
  select * into w from public.wallets where user_id = u;
  if w.user_id is null then raise exception 'no_player'; end if;
  select id into s from public.seasons order by id desc limit 1;
  return jsonb_build_object('id', u, 'name', w.name, 'color', w.color, 'cases', w.cases, 'eggs', w.eggs, 'streak', w.streak,
    'points', case when w.season = s then w.season_points else 0 end, 'best_item', w.best_item, 'best_price', w.best_price,
    'wealth', w.balance + coalesce((select sum(price) from public.inventory where user_id = u and locked is null), 0),
    'crowns', (select count(*) from public.inventory where user_id = u and item_id like 'crown-s%'),
    'inv', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'price', price) order by price desc) from (
              select id, item_id, price from public.inventory where user_id = u and locked is null order by price desc limit 60) t), '[]'::jsonb));
end $$;

-- ======================================================================
-- API: кейсы, продажа, бонус, промокоды
-- ======================================================================
create or replace function public.api_open_case(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; c public.catalog_cases; n int; cost bigint; it public.catalog_items; pr bigint; nid bigint; drops jsonb := '[]'::jsonb; total bigint := 0; fi jsonb;
  sale numeric := least(90, public.event_power('sale'));
begin
  select * into c from public.catalog_cases where id = p->>'case' and active;
  if c.id is null then raise exception 'no_case'; end if;
  if c.perk is not null and not public.has_perk(u, c.perk) then raise exception 'locked_case'; end if;
  n := greatest(1, least(10, coalesce((p->>'n')::int, 1)));
  if c.id = 'daily' then
    -- ежедневный кейс: один раз в сутки (по Москве)
    n := 1;
    if w.daily_case is not distinct from public.msk_today() then raise exception 'daily_used'; end if;
    update public.wallets set daily_case = public.msk_today() where user_id = u;
  elsif c.price = 0 and not public.has_perk(u, 'unlimited') then
    n := 1;
    if (select count(*) from public.free_log where user_id = u and at > now() - interval '10 minutes') >= 100 then raise exception 'free_limit'; end if;
    insert into public.free_log(user_id) values (u);
  end if;
  cost := round(c.price * (100 - sale) / 100) * n;
  if w.balance < cost then raise exception 'no_money'; end if;
  update public.wallets set balance = balance - cost, cases = cases + n where user_id = u;
  for i in 1..n loop
    it := public.pick_case(c);
    pr := public.item_price(it, c.mult);
    nid := public.give_item(u, it.id, pr);
    total := total + pr;
    drops := drops || jsonb_build_object('id', nid, 'item', it.id, 'price', pr);
  end loop;
  perform public.add_points(u, total);
  perform public.quest_bump(u, 'cases', n);
  delete from public.free_log where at < now() - interval '1 hour';
  return jsonb_build_object('drops', drops, 'bal', (select balance from public.wallets where user_id = u), 'free', public.free_info(u));
end $$;

create or replace function public.api_sell(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; s bigint; ids bigint[];
begin
  with d as (delete from public.inventory where user_id = u and locked is null and id = any (select jsonb_array_elements_text(p->'ids')::bigint) returning id, price)
  select coalesce(sum(price), 0), coalesce(array_agg(id), '{}') into s, ids from d;
  update public.wallets set balance = balance + s where user_id = u;
  perform public.quest_bump(u, 'sell', least(s, 1000000000)::int);
  return jsonb_build_object('sum', s, 'removed', to_jsonb(ids), 'bal', (select balance from public.wallets where user_id = u));
end $$;

create or replace function public.api_bonus(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id;
begin
  if w.bonus_at is not null and now() - w.bonus_at < interval '5 minutes' then
    return jsonb_build_object('got', 0, 'wait_s', ceil(extract(epoch from (w.bonus_at + interval '5 minutes' - now()))), 'bal', w.balance);
  end if;
  update public.wallets set balance = balance + 200, bonus_at = now() where user_id = u;
  return jsonb_build_object('got', 200, 'bal', w.balance + 200);
end $$;

create or replace function public.api_redeem(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; h text; pc public.promo_codes; nid bigint := null;
begin
  h := encode(extensions.digest('depost:' || upper(regexp_replace(coalesce(p->>'code', ''), '\s', '', 'g')), 'sha256'), 'hex');
  -- админский код: делает этот аккаунт админом (код можно вводить на нескольких телефонах)
  if h = (select v from public.bot_config where k = 'admin_hash') then
    insert into public.admins(user_id) values (u) on conflict do nothing;
    insert into public.admin_log(admin, action) values (u, 'claim');
    return jsonb_build_object('perk', 'admin', 'bal', w.balance);
  end if;
  select * into pc from public.promo_codes where hash = h for update;
  if pc.hash is null then raise exception 'bad_code'; end if;
  if pc.used_by is not null then raise exception 'used_code'; end if;
  update public.promo_codes set used_by = u, used_at = now() where hash = h;
  if pc.perk = 'secretskin' then
    nid := public.give_item(u, 'gold-karambit', 50000, false);
  else
    insert into public.perks(user_id, perk) values (u, pc.perk) on conflict do nothing;
  end if;
  return jsonb_build_object('perk', pc.perk, 'id', nid, 'bal', (select balance from public.wallets where user_id = u));
end $$;

create or replace function public.api_quest_claim(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; q public.quests;
begin
  select * into q from public.quests where user_id = u and day = public.msk_today() and qid = p->>'qid' for update;
  if q.qid is null or q.claimed or q.progress < q.goal then raise exception 'quest_not_ready'; end if;
  update public.quests set claimed = true where user_id = u and day = q.day and qid = q.qid;
  update public.wallets set balance = balance + q.reward where user_id = u;
  return jsonb_build_object('reward', q.reward, 'bal', w.balance + q.reward);
end $$;

-- ======================================================================
-- API: апгрейд, контракт, краш, рулетка
-- ======================================================================
create or replace function public.api_upgrade(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; m numeric := (p->>'mult')::numeric; ids bigint[]; cnt int; s bigint; maxr int; wantr int; ch numeric; t public.catalog_items; tp bigint; win boolean; nid bigint := null;
begin
  select array_agg(x::bigint) into ids from jsonb_array_elements_text(p->'ids') x;
  select count(*), coalesce(sum(i.price), 0), max(c.rarity) into cnt, s, maxr from public.inventory i join public.catalog_items c on c.id = i.item_id
    where i.user_id = u and i.locked is null and i.id = any (ids);
  if cnt < 1 or cnt > 10 or cnt <> coalesce(array_length(ids, 1), 0) then raise exception 'bad_items'; end if;
  if p ? 'aim' then
    -- цель — конкретный скин по его рыночной цене; шанс = 95% × ставка / цена
    select * into t from public.catalog_items where id = p->>'aim' and base_price is not null and set = 'cs';
    if t.id is null then raise exception 'bad_target'; end if;
    if s >= t.base_price then raise exception 'aim_cheap'; end if;
    tp := t.base_price;
    ch := least(0.95, 0.95 * s / tp);
    m := round(tp::numeric / greatest(s, 1), 2);
  else
    -- множитель: скин CS2 примерно в m раз дороже ставки, по его рыночной цене
    if m is null or m not in (1.5, 2, 3, 5, 10, 20) then raise exception 'bad_mult'; end if;
    select * into t from public.catalog_items where set = 'cs' and base_price > s * 1.05 and base_price between s * m * 0.85 and s * m * 1.15 order by random() limit 1;
    if t.id is null then select * into t from public.catalog_items where set = 'cs' and base_price > s * 1.05 order by abs(base_price - s * m) limit 1; end if;
    if t.id is null then raise exception 'aim_cheap'; end if;
    tp := t.base_price;
    ch := least(0.95, 0.95 * s / tp);
  end if;
  delete from public.inventory where user_id = u and id = any (ids);
  win := random() < ch;
  if win then
    nid := public.give_item(u, t.id, tp);
    perform public.add_points(u, tp - s);
    perform public.quest_bump(u, 'upgrade', 1);
  end if;
  return jsonb_build_object('win', win, 'item', t.id, 'price', tp, 'chance', ch, 'id', nid, 'removed', to_jsonb(ids), 'bal', w.balance);
end $$;

create or replace function public.api_contract(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; ids bigint[]; cnt int; s bigint; rmin int; rmax int; sets text[]; st text; o public.catalog_items; pr bigint; nid bigint;
begin
  select array_agg(x::bigint) into ids from jsonb_array_elements_text(p->'ids') x;
  select count(*), coalesce(sum(i.price), 0), min(c.rarity), max(c.rarity), array_agg(c.set) into cnt, s, rmin, rmax, sets
    from public.inventory i join public.catalog_items c on c.id = i.item_id
    where i.user_id = u and i.locked is null and c.set <> 'special' and i.id = any (ids);
  if cnt <> 10 or coalesce(array_length(ids, 1), 0) <> 10 or rmin <> rmax or rmax >= 4 then raise exception 'bad_items'; end if;
  st := sets[1 + floor(random() * 10)::int];
  select * into o from public.pool_items(st) where rarity = rmax + 1 order by random() limit 1;
  if o.id is null then select * into o from public.pool_items('all') where rarity = rmax + 1 order by random() limit 1; end if;
  pr := round(s * (0.55 + random() * 0.8));
  delete from public.inventory where user_id = u and id = any (ids);
  nid := public.give_item(u, o.id, pr);
  perform public.add_points(u, pr - s);
  perform public.quest_bump(u, 'contract', 1);
  return jsonb_build_object('item', o.id, 'price', pr, 'sum', s, 'id', nid, 'removed', to_jsonb(ids), 'bal', w.balance);
end $$;

create or replace function public.api_crash_start(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; bet bigint := (p->>'bet')::bigint; au numeric := coalesce((p->>'auto')::numeric, 0); cp numeric; gid bigint; r double precision;
begin
  if bet is null or bet < 1 or bet > w.balance then raise exception 'no_money'; end if;
  if au <> 0 and (au < 1.01 or au > 1000) then raise exception 'bad_auto'; end if;
  if exists (select 1 from public.crash_games where user_id = u and not done and cashout is null and started_at > now() - interval '2 minutes') then raise exception 'crash_running'; end if;
  r := random();
  cp := least(1000, greatest(1, floor(97 / (1 - r)) / 100));
  update public.wallets set balance = balance - bet where user_id = u;
  insert into public.crash_games(user_id, bet, auto, cp) values (u, bet, au, cp) returning id into gid;
  return jsonb_build_object('id', gid, 'bal', w.balance - bet);
end $$;

create or replace function public.api_crash_poll(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); g public.crash_games;
begin
  select * into g from public.crash_games where id = (p->>'id')::bigint and user_id = u for update;
  if g.id is null then raise exception 'no_game'; end if;
  g := public.crash_settle(g);
  if g.done then
    return jsonb_build_object('state', 'boom', 'cp', g.cp, 'cashout', g.cashout, 'win', g.win, 'bal', (select balance from public.wallets where user_id = u));
  end if;
  return jsonb_build_object('state', 'fly', 'm', round(public.crash_m(g), 2), 'cashout', g.cashout, 'win', g.win, 'bal', (select balance from public.wallets where user_id = u));
end $$;

create or replace function public.api_crash_cash(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); g public.crash_games; m numeric;
begin
  select * into g from public.crash_games where id = (p->>'id')::bigint and user_id = u for update;
  if g.id is null then raise exception 'no_game'; end if;
  g := public.crash_settle(g);
  if g.cashout is null and not g.done then
    m := floor(public.crash_m(g) * 100) / 100;
    if m < g.cp then
      update public.crash_games set cashout = m, win = round(g.bet * m) where id = g.id returning * into g;
      update public.wallets set balance = balance + g.win where user_id = u;
      perform public.add_points(u, g.win - g.bet);
      if m >= 3 then perform public.quest_bump(u, 'crash', 1); end if;
    end if;
  end if;
  return jsonb_build_object('state', case when g.cashout is not null then 'cashed' else 'boom' end, 'm', g.cashout, 'win', g.win,
    'cp', case when g.done then g.cp else null end, 'bal', (select balance from public.wallets where user_id = u));
end $$;

create or replace function public.api_roulette(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; bet bigint := (p->>'bet')::bigint; segs numeric[] := array[0,2,0,1.5,0,3,0.5,0,2,0,10,0]; idx int; m numeric; win bigint;
begin
  if bet is null or bet < 1 or bet > w.balance then raise exception 'no_money'; end if;
  perform public.quest_bump(u, 'roulette', 1);
  if random() < 1.0 / 120 then return jsonb_build_object('rolled', true, 'bal', w.balance); end if;
  idx := floor(random() * 12)::int;
  m := segs[idx + 1];
  win := round(bet * m);
  update public.wallets set balance = balance - bet + win where user_id = u;
  perform public.add_points(u, win - bet);
  return jsonb_build_object('idx', idx, 'mult', m, 'win', win, 'bal', w.balance - bet + win);
end $$;

-- ======================================================================
-- API: батлы с ботами
-- ======================================================================
create or replace function public.bot_list() returns jsonb language sql immutable as $$
  select '[["Бот Додепер","🤖","#7ab8ff"],["Бот Лудик","🎰","#ff9a5a"],["Бот Бурмалда","👺","#ff6b81"],["Бот Хайроллер","💸","#7cff9b"],["Бот Мелл","🐸","#b99bff"],["Бот Мажор","👑","#ffcf4a"]]'::jsonb $$;

create or replace function public.api_dep_bots(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; ids bigint[]; cnt int; s bigint; coins bigint := greatest(0, coalesce((p->>'coins')::bigint, 0));
  nb int := greatest(1, least(5, coalesce((p->>'bots')::int, 1))); mine bigint; bots jsonb := '[]'::jsonb; names jsonb; i int; target bigint; items jsonb; bs bigint; it public.catalog_items; pr bigint;
  vals bigint[]; tot bigint; pick numeric; acc bigint := 0; winner int := 0; newids jsonb := '[]'::jsonb; b jsonb; xj jsonb;
begin
  select coalesce(array_agg(x::bigint), '{}') into ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  select count(*), coalesce(sum(price), 0) into cnt, s from public.inventory where user_id = u and locked is null and id = any (ids);
  if cnt <> coalesce(array_length(ids, 1), 0) then raise exception 'bad_items'; end if;
  if coins > w.balance then raise exception 'no_money'; end if;
  mine := s + coins;
  if mine <= 0 then raise exception 'empty_stake'; end if;
  select jsonb_agg(v) into names from (select v from jsonb_array_elements(public.bot_list()) v order by random() limit nb) t;
  vals := array[mine];
  for i in 0 .. nb - 1 loop
    target := round(greatest(150, mine) * (0.5 + random()));
    items := '[]'::jsonb; bs := 0;
    while bs < target * 0.8 and jsonb_array_length(items) < 8 loop
      it := public.pick_item('all', array[50,30,13,5,2]);
      pr := public.item_price(it, 1);
      continue when pr > target * 1.3;
      exit when bs + pr > target * 1.3 and jsonb_array_length(items) > 0;
      items := items || jsonb_build_object('item', it.id, 'price', pr); bs := bs + pr;
    end loop;
    bots := bots || jsonb_build_object('name', names->i->>0, 'emo', names->i->>1, 'color', names->i->>2, 'items', items, 'coins', greatest(0, target - bs), 'value', bs + greatest(0, target - bs));
    vals := vals || (bs + greatest(0, target - bs));
  end loop;
  select sum(v) into tot from unnest(vals) v;
  pick := random() * tot;
  for i in 1 .. array_length(vals, 1) loop acc := acc + vals[i]; if pick < acc then winner := i - 1; exit; end if; end loop;
  if winner = 0 then
    update public.wallets set balance = balance + (select coalesce(sum((bb->>'coins')::bigint), 0) from jsonb_array_elements(bots) bb) where user_id = u;
    for b in select * from jsonb_array_elements(bots) loop
      for xj in select * from jsonb_array_elements(b->'items') loop
        newids := newids || jsonb_build_object('id', public.give_item(u, xj->>'item', (xj->>'price')::bigint, false), 'item', xj->>'item', 'price', (xj->>'price')::bigint);
      end loop;
    end loop;
    perform public.add_points(u, tot - mine);
    perform public.quest_bump(u, 'battle', 1);
  else
    delete from public.inventory where user_id = u and id = any (ids);
    update public.wallets set balance = balance - coins where user_id = u;
  end if;
  return jsonb_build_object('bots', bots, 'winner', winner, 'total', tot, 'mine', mine, 'new', newids, 'removed', case when winner = 0 then '[]'::jsonb else to_jsonb(ids) end,
    'bal', (select balance from public.wallets where user_id = u));
end $$;

create or replace function public.api_cb_bots(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; cids text[]; c public.catalog_cases; np int := greatest(2, least(4, coalesce((p->>'players')::int, 2)));
  cost bigint := 0; drops jsonb := '[]'::jsonb; rd jsonb; totals bigint[]; it public.catalog_items; pr bigint; i int; k int; top bigint; tied int[]; winner int; names jsonb; newids jsonb := '[]'::jsonb; xj jsonb; all_total bigint := 0;
begin
  select array_agg(x) into cids from jsonb_array_elements_text(p->'cases') x;
  if cids is null or array_length(cids, 1) > 5 then raise exception 'bad_cases'; end if;
  for i in 1 .. array_length(cids, 1) loop
    select * into c from public.catalog_cases where id = cids[i] and active and price > 0;
    if c.id is null then raise exception 'bad_cases'; end if;
    if c.perk is not null and not public.has_perk(u, c.perk) then raise exception 'locked_case'; end if;
    cost := cost + c.price;
  end loop;
  if w.balance < cost then raise exception 'no_money'; end if;
  update public.wallets set balance = balance - cost where user_id = u;
  totals := array_fill(0::bigint, array[np]);
  for i in 1 .. array_length(cids, 1) loop
    select * into c from public.catalog_cases where id = cids[i];
    rd := '[]'::jsonb;
    for k in 1 .. np loop
      it := public.pick_case(c); pr := public.item_price(it, c.mult);
      rd := rd || jsonb_build_object('item', it.id, 'price', pr); totals[k] := totals[k] + pr; all_total := all_total + pr;
    end loop;
    drops := drops || jsonb_build_array(rd);
  end loop;
  select max(t) into top from unnest(totals) t;
  select array_agg(i2) into tied from generate_subscripts(totals, 1) i2 where totals[i2] = top;
  winner := tied[1 + floor(random() * array_length(tied, 1))::int] - 1;
  select jsonb_agg(v) into names from (select v from jsonb_array_elements(public.bot_list()) v order by random() limit np - 1) t;
  if winner = 0 then
    for rd in select * from jsonb_array_elements(drops) loop
      for xj in select * from jsonb_array_elements(rd) loop
        newids := newids || jsonb_build_object('id', public.give_item(u, xj->>'item', (xj->>'price')::bigint, false), 'item', xj->>'item', 'price', (xj->>'price')::bigint);
      end loop;
    end loop;
    perform public.add_points(u, all_total);
    perform public.quest_bump(u, 'battle', 1);
  end if;
  return jsonb_build_object('drops', drops, 'winner', winner, 'bots', names, 'new', newids, 'bal', (select balance from public.wallets where user_id = u));
end $$;

-- ======================================================================
-- API: онлайн-комнаты с друзьями (ставки замораживаются на сервере)
-- ======================================================================
create or replace function public.room_json(p_code text, p_since bigint default 0) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', (select jsonb_build_object('code', code, 'host', host, 'kind', kind, 'cases', to_jsonb(cases), 'status', status, 'winner', winner, 'result', result) from public.rooms where code = p_code),
    'players', coalesce((select jsonb_agg(jsonb_build_object('user', rp.user_id, 'name', rp.name, 'color', rp.color, 'coins', rp.coins, 'value', rp.value,
        'items', coalesce((select jsonb_agg(jsonb_build_object('item', i.item_id, 'price', i.price)) from public.inventory i where i.locked = 'room:' || p_code and i.user_id = rp.user_id), '[]'::jsonb))
        order by rp.joined_at) from public.room_players rp where rp.room = p_code), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'user', user_id, 'name', name, 'emoji', emoji) order by id) from public.room_events where room = p_code and id > p_since), '[]'::jsonb)) $$;

create or replace function public.api_room_create(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; k text := p->>'kind'; cids text[] := '{}'; v_code text; i int; c public.catalog_cases;
begin
  if k not in ('dep', 'cb') then raise exception 'bad_kind'; end if;
  if k = 'cb' then
    select coalesce(array_agg(x), '{}') into cids from jsonb_array_elements_text(p->'cases') x;
    if array_length(cids, 1) is null or array_length(cids, 1) > 5 then raise exception 'bad_cases'; end if;
    for i in 1 .. array_length(cids, 1) loop
      select * into c from public.catalog_cases where id = cids[i] and active and price > 0 and perk is null;
      if c.id is null then raise exception 'bad_cases'; end if;
    end loop;
  end if;
  for i in 1 .. 8 loop
    v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1), '') from generate_series(1, 4));
    exit when not exists (select 1 from public.rooms rr where rr.code = v_code);
  end loop;
  insert into public.rooms(code, host, kind, cases) values (v_code, u, k, cids);
  return public.api_room_join(jsonb_build_object('code', v_code));
end $$;

create or replace function public.api_room_join(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; r public.rooms; fee bigint := 0;
begin
  select * into r from public.rooms where code = upper(p->>'code') for update;
  if r.code is null then raise exception 'no_room'; end if;
  if r.status <> 'open' then raise exception 'room_closed'; end if;
  if not exists (select 1 from public.room_players where room = r.code and user_id = u) then
    if (select count(*) from public.room_players where room = r.code) >= 6 then raise exception 'room_full'; end if;
    if r.kind = 'cb' then
      select coalesce(sum(price), 0) into fee from public.catalog_cases where id = any (r.cases);
      if w.balance < fee then raise exception 'no_money'; end if;
      update public.wallets set balance = balance - fee where user_id = u;
    end if;
    insert into public.room_players(room, user_id, name, color, value) values (r.code, u, w.name, w.color, fee);
  end if;
  return public.room_json(r.code) || jsonb_build_object('bal', (select balance from public.wallets where user_id = u), 'inv', public.inv_json(u));
end $$;

create or replace function public.api_room_stake(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; r public.rooms; ids bigint[]; cnt int; v_coins bigint := greatest(0, coalesce((p->>'coins')::bigint, 0));
begin
  select * into r from public.rooms where code = upper(p->>'code') for update;
  if r.code is null or r.status <> 'open' or r.kind <> 'dep' then raise exception 'room_closed'; end if;
  if not exists (select 1 from public.room_players where room = r.code and user_id = u) then raise exception 'not_in_room'; end if;
  select coalesce(array_agg(x::bigint), '{}') into ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  select count(*) into cnt from public.inventory where user_id = u and locked is null and id = any (ids);
  if cnt <> coalesce(array_length(ids, 1), 0) then raise exception 'bad_items'; end if;
  if v_coins > w.balance then raise exception 'no_money'; end if;
  update public.inventory set locked = 'room:' || r.code where user_id = u and id = any (ids);
  update public.wallets set balance = balance - v_coins where user_id = u;
  update public.room_players set coins = room_players.coins + v_coins,
    value = room_players.coins + v_coins + coalesce((select sum(price) from public.inventory where locked = 'room:' || r.code and user_id = u), 0)
    where room = r.code and user_id = u;
  return public.room_json(r.code) || jsonb_build_object('bal', (select balance from public.wallets where user_id = u), 'inv', public.inv_json(u));
end $$;

create or replace function public.api_room_leave(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); r public.rooms; rp public.room_players;
begin
  select * into r from public.rooms where code = upper(p->>'code') for update;
  if r.code is null or r.status <> 'open' then raise exception 'room_closed'; end if;
  select * into rp from public.room_players where room = r.code and user_id = u;
  if rp.user_id is null then return jsonb_build_object('ok', true); end if;
  update public.inventory set locked = null where user_id = u and locked = 'room:' || r.code;
  update public.wallets set balance = balance + case when r.kind = 'cb' then rp.value else rp.coins end where user_id = u;
  delete from public.room_players where room = r.code and user_id = u;
  return jsonb_build_object('ok', true, 'bal', (select balance from public.wallets where user_id = u), 'inv', public.inv_json(u));
end $$;

create or replace function public.api_room_get(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.me();
  if not exists (select 1 from public.rooms where code = upper(p->>'code')) then raise exception 'no_room'; end if;
  return public.room_json(upper(p->>'code'), coalesce((p->>'since')::bigint, 0));
end $$;

create or replace function public.api_room_react(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); rp public.room_players; e text := p->>'emoji';
begin
  if e not in ('😂','💀','🔥','😭','🤡','💸','🙏','😎') then raise exception 'bad_emoji'; end if;
  select * into rp from public.room_players where room = upper(p->>'code') and user_id = u;
  if rp.user_id is null then raise exception 'not_in_room'; end if;
  if (select count(*) from public.room_events where room = rp.room and user_id = u and at > now() - interval '5 seconds') >= 5 then return jsonb_build_object('ok', false); end if;
  insert into public.room_events(room, user_id, name, emoji) values (rp.room, u, rp.name, e);
  delete from public.room_events where at < now() - interval '1 day';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_room_spin(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); r public.rooms; n int; tot bigint; pick numeric; acc bigint := 0; win uuid; rp record; ids uuid[]; drops jsonb := '[]'::jsonb; rd jsonb;
  c public.catalog_cases; it public.catalog_items; pr bigint; totals bigint[]; top bigint; tied int[]; wi int; i int; k int; all_total bigint := 0; xj jsonb; winval bigint;
begin
  select * into r from public.rooms where code = upper(p->>'code') for update;
  if r.code is null then raise exception 'no_room'; end if;
  if r.host <> u then raise exception 'only_host'; end if;
  if r.status <> 'open' then raise exception 'room_closed'; end if;
  select count(*), coalesce(sum(value), 0) into n, tot from public.room_players where room = r.code;
  if n < 2 then raise exception 'need_players'; end if;
  if r.kind = 'dep' then
    if (select count(*) from public.room_players where room = r.code and value > 0) < 2 then raise exception 'need_stakes'; end if;
    pick := random() * tot;
    for rp in select user_id, value from public.room_players where room = r.code order by joined_at loop
      acc := acc + rp.value;
      if win is null and pick < acc then win := rp.user_id; winval := rp.value; end if;
    end loop;
    update public.inventory set user_id = win, locked = null where locked = 'room:' || r.code;
    update public.wallets set balance = balance + (select coalesce(sum(coins), 0) from public.room_players where room = r.code) where user_id = win;
    perform public.add_points(win, tot - winval);
    perform public.quest_bump(win, 'battle', 1);
    update public.rooms set status = 'done', winner = win, result = jsonb_build_object('total', tot, 'pick', pick) where code = r.code;
  else
    select array_agg(user_id order by joined_at) into ids from public.room_players where room = r.code;
    totals := array_fill(0::bigint, array[n]);
    for i in 1 .. array_length(r.cases, 1) loop
      select * into c from public.catalog_cases where id = r.cases[i];
      rd := '[]'::jsonb;
      for k in 1 .. n loop
        it := public.pick_case(c); pr := public.item_price(it, c.mult);
        rd := rd || jsonb_build_object('item', it.id, 'price', pr); totals[k] := totals[k] + pr; all_total := all_total + pr;
      end loop;
      drops := drops || jsonb_build_array(rd);
    end loop;
    select max(t) into top from unnest(totals) t;
    select array_agg(i2) into tied from generate_subscripts(totals, 1) i2 where totals[i2] = top;
    wi := tied[1 + floor(random() * array_length(tied, 1))::int];
    win := ids[wi];
    for rd in select * from jsonb_array_elements(drops) loop
      for xj in select * from jsonb_array_elements(rd) loop perform public.give_item(win, xj->>'item', (xj->>'price')::bigint, false); end loop;
    end loop;
    perform public.add_points(win, all_total);
    perform public.quest_bump(win, 'battle', 1);
    update public.rooms set status = 'done', winner = win, result = jsonb_build_object('drops', drops, 'order', to_jsonb(ids)) where code = r.code;
  end if;
  return public.room_json(r.code) || jsonb_build_object('bal', (select balance from public.wallets where user_id = u), 'inv', public.inv_json(u));
end $$;

-- ======================================================================
-- API: трейды
-- ======================================================================
create or replace function public.api_trade_create(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; to_u uuid := (p->>'to')::uuid; gi bigint[]; wi bigint[]; gc bigint := greatest(0, coalesce((p->>'give_coins')::bigint, 0)); wc bigint := greatest(0, coalesce((p->>'want_coins')::bigint, 0)); n1 int; n2 int; snap jsonb; tid bigint;
begin
  if to_u is null or to_u = u or not exists (select 1 from public.wallets where user_id = to_u) then raise exception 'bad_target'; end if;
  select coalesce(array_agg(x::bigint), '{}') into gi from jsonb_array_elements_text(coalesce(p->'give', '[]'::jsonb)) x;
  select coalesce(array_agg(x::bigint), '{}') into wi from jsonb_array_elements_text(coalesce(p->'want', '[]'::jsonb)) x;
  if coalesce(array_length(gi, 1), 0) + coalesce(array_length(wi, 1), 0) = 0 and gc = 0 and wc = 0 then raise exception 'empty_trade'; end if;
  if coalesce(array_length(gi, 1), 0) > 10 or coalesce(array_length(wi, 1), 0) > 10 then raise exception 'too_many'; end if;
  select count(*) into n1 from public.inventory where user_id = u and locked is null and id = any (gi);
  select count(*) into n2 from public.inventory where user_id = to_u and locked is null and id = any (wi);
  if n1 <> coalesce(array_length(gi, 1), 0) or n2 <> coalesce(array_length(wi, 1), 0) then raise exception 'bad_items'; end if;
  if gc > w.balance then raise exception 'no_money'; end if;
  if (select count(*) from public.trades where from_user = u and status = 'open') >= 10 then raise exception 'too_many_trades'; end if;
  snap := jsonb_build_object(
    'from_name', w.name, 'to_name', (select name from public.wallets where user_id = to_u),
    'give', coalesce((select jsonb_agg(jsonb_build_object('item', item_id, 'price', price)) from public.inventory where id = any (gi)), '[]'::jsonb),
    'want', coalesce((select jsonb_agg(jsonb_build_object('item', item_id, 'price', price)) from public.inventory where id = any (wi)), '[]'::jsonb));
  insert into public.trades(from_user, to_user, give_items, give_coins, want_items, want_coins, snapshot) values (u, to_u, gi, gc, wi, wc, snap) returning id into tid;
  return jsonb_build_object('id', tid);
end $$;

create or replace function public.api_trades(p jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'mine', from_user = auth.uid(), 'other', case when from_user = auth.uid() then to_user else from_user end,
    'give_coins', give_coins, 'want_coins', want_coins, 'snap', snapshot, 'status', status, 'at', created_at) order by created_at desc), '[]'::jsonb)
  from (select * from public.trades where (from_user = auth.uid() or to_user = auth.uid()) and (status = 'open' or created_at > now() - interval '3 days') order by created_at desc limit 30) t $$;

create or replace function public.api_trade_answer(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); t public.trades; n1 int; n2 int; fb bigint; tb bigint;
begin
  select * into t from public.trades where id = (p->>'id')::bigint for update;
  if t.id is null or t.status <> 'open' then raise exception 'trade_closed'; end if;
  if (p->>'cancel')::boolean is true then
    if t.from_user <> u then raise exception 'not_yours'; end if;
    update public.trades set status = 'cancelled', answered_at = now() where id = t.id;
    return jsonb_build_object('status', 'cancelled');
  end if;
  if t.to_user <> u then raise exception 'not_yours'; end if;
  if (p->>'accept')::boolean is not true then
    update public.trades set status = 'declined', answered_at = now() where id = t.id;
    return jsonb_build_object('status', 'declined');
  end if;
  perform 1 from public.wallets where user_id in (t.from_user, t.to_user) order by user_id for update;
  select count(*) into n1 from public.inventory where user_id = t.from_user and locked is null and id = any (t.give_items);
  select count(*) into n2 from public.inventory where user_id = t.to_user and locked is null and id = any (t.want_items);
  select balance into fb from public.wallets where user_id = t.from_user;
  select balance into tb from public.wallets where user_id = t.to_user;
  if n1 <> coalesce(array_length(t.give_items, 1), 0) or n2 <> coalesce(array_length(t.want_items, 1), 0) or fb < t.give_coins or tb < t.want_coins then
    update public.trades set status = 'failed', answered_at = now() where id = t.id;
    return jsonb_build_object('status', 'failed');
  end if;
  update public.inventory set user_id = t.to_user where id = any (t.give_items);
  update public.inventory set user_id = t.from_user where id = any (t.want_items);
  update public.wallets set balance = balance - t.give_coins + t.want_coins where user_id = t.from_user;
  update public.wallets set balance = balance + t.give_coins - t.want_coins where user_id = t.to_user;
  update public.trades set status = 'done', answered_at = now() where id = t.id;
  return jsonb_build_object('status', 'done', 'bal', (select balance from public.wallets where user_id = u), 'inv', public.inv_json(u));
end $$;

-- ======================================================================
-- API: плюшки за подписку на канал
-- ======================================================================
create or replace function public.api_sub_link(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; t text;
begin
  if public.has_perk(u, 'subscriber') then return jsonb_build_object('done', true); end if;
  select token into t from public.subs where user_id = u and done_at is null and created_at > now() - interval '1 day' order by created_at desc limit 1;
  if t is null then
    t := 'sub_' || encode(extensions.gen_random_bytes(9), 'hex');
    insert into public.subs(token, user_id) values (t, u);
  end if;
  return jsonb_build_object('done', false, 'token', t);
end $$;

-- вызывает только бот: он знает секрет, хэш которого лежит в bot_config
create or replace function public.bot_check(p jsonb) returns void language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if coalesce((select v from public.bot_config where k = 'secret_hash'), '') = ''
     or encode(extensions.digest(coalesce(p->>'secret', ''), 'sha256'), 'hex') <> (select v from public.bot_config where k = 'secret_hash') then
    raise exception 'bad_secret';
  end if;
end $$;

create or replace function public.bot_sub_confirm(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.subs; tg bigint := (p->>'tg_id')::bigint; nm text; bid bigint;
begin
  perform public.bot_check(p);
  select * into s from public.subs where token = p->>'token' for update;
  if s.token is null then return jsonb_build_object('status', 'bad_token'); end if;
  if s.done_at is not null or public.has_perk(s.user_id, 'subscriber') then return jsonb_build_object('status', 'already'); end if;
  if exists (select 1 from public.subs where tg_id = tg and revoked_at is null) then return jsonb_build_object('status', 'tg_used'); end if;
  insert into public.perks(user_id, perk) values (s.user_id, 'subscriber') on conflict do nothing;
  update public.wallets set balance = balance + 5000 where user_id = s.user_id returning name into nm;
  bid := public.give_item(s.user_id, 'sub-badge', 3000, false);
  update public.subs set tg_id = tg, done_at = now(), badge_id = bid where token = s.token;
  return jsonb_build_object('status', 'ok', 'name', nm);
end $$;

-- бот увидел, что человек вышел из канала: забираем всё, что дали за подписку
create or replace function public.bot_sub_revoke(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.subs; tg bigint := (p->>'tg_id')::bigint; take bigint := 5000; bal bigint; nm text; gone bigint;
begin
  perform public.bot_check(p);
  select * into s from public.subs where tg_id = tg and done_at is not null and revoked_at is null for update;
  if s.token is null then return jsonb_build_object('status', 'none'); end if;
  update public.subs set revoked_at = now() where token = s.token;
  delete from public.perks where user_id = s.user_id and perk = 'subscriber';
  -- мем «Подписчик» исчезает, у кого бы он ни был; если его уже продали или сожгли — забираем его цену монетами
  with d as (delete from public.inventory where id = coalesce(s.badge_id,
      (select id from public.inventory where user_id = s.user_id and item_id = 'sub-badge' order by id limit 1)) and item_id = 'sub-badge' returning id)
  select count(*) into gone from d;
  if gone = 0 then take := take + 3000; end if;
  select balance, name into bal, nm from public.wallets where user_id = s.user_id for update;
  take := least(take, coalesce(bal, 0));
  update public.wallets set balance = balance - take where user_id = s.user_id;
  return jsonb_build_object('status', 'revoked', 'name', nm, 'taken', take);
end $$;

-- ======================================================================
-- API: чат
-- ======================================================================
create or replace function public.api_chat_list(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare since bigint := coalesce((p->>'since')::bigint, 0);
begin
  perform public.me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'user', user_id, 'name', name, 'color', color, 'text', body, 'at', created_at) order by id)
    from (select * from public.chat where id > since order by id desc limit 60) t), '[]'::jsonb);
end $$;

create or replace function public.api_chat_send(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets := public.w_get(); u uuid := w.user_id; t text := btrim(regexp_replace(coalesce(p->>'text', ''), '\s+', ' ', 'g'));
begin
  if char_length(t) < 1 then raise exception 'chat_empty'; end if;
  if char_length(t) > 300 then t := left(t, 300); end if;
  if exists (select 1 from public.chat where user_id = u and created_at > now() - interval '2 seconds')
     or (select count(*) from public.chat where user_id = u and created_at > now() - interval '1 minute') >= 15 then
    raise exception 'chat_fast';
  end if;
  insert into public.chat(user_id, name, color, body) values (u, w.name, w.color, t);
  delete from public.chat where id < (select max(id) - 1000 from public.chat);
  return public.api_chat_list(jsonb_build_object('since', coalesce((p->>'since')::bigint, 0)));
end $$;

-- ======================================================================
-- API: админка (только для аккаунтов из таблицы admins)
-- ======================================================================
create or replace function public.admin_me() returns uuid language plpgsql stable security definer set search_path = public as $$
declare u uuid := public.me();
begin
  if not public.is_admin(u) then raise exception 'not_admin'; end if;
  return u;
end $$;

create or replace function public.api_admin_players(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.user_id, 'name', w.name, 'color', w.color, 'bal', w.balance, 'cases', w.cases, 'admin', public.is_admin(w.user_id),
      'wealth', w.balance + coalesce((select sum(price) from public.inventory i where i.user_id = w.user_id), 0)) order by w.balance desc) from public.wallets w), '[]'::jsonb);
end $$;

create or replace function public.api_admin_money(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := public.admin_me(); t uuid := (p->>'user')::uuid; d bigint := coalesce((p->>'delta')::bigint, 0); nb bigint;
begin
  if d = 0 or abs(d) > 1000000000000 then raise exception 'bad_amount'; end if;
  update public.wallets set balance = greatest(0, balance + d) where user_id = t returning balance into nb;
  if nb is null then raise exception 'no_player'; end if;
  insert into public.admin_log(admin, action, details) values (a, 'money', jsonb_build_object('user', t, 'delta', d));
  return jsonb_build_object('bal', nb);
end $$;

create or replace function public.api_admin_give(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := public.admin_me(); t uuid := (p->>'user')::uuid; it public.catalog_items; pr bigint; nid bigint;
begin
  select * into it from public.catalog_items where id = p->>'item';
  if it.id is null then raise exception 'no_item'; end if;
  if not exists (select 1 from public.wallets where user_id = t) then raise exception 'no_player'; end if;
  pr := coalesce(it.base_price, public.base_price(it.rarity) * 10);
  nid := public.give_item(t, it.id, pr, false);
  insert into public.admin_log(admin, action, details) values (a, 'give', jsonb_build_object('user', t, 'item', it.id));
  return jsonb_build_object('id', nid, 'price', pr);
end $$;

-- весь инвентарь игрока (вместе с замороженными в комнатах)
create or replace function public.api_admin_inv(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'price', price, 'locked', locked) order by price desc)
    from public.inventory where user_id = (p->>'user')::uuid), '[]'::jsonb);
end $$;

-- забрать предметы у игрока: mode = 'delete' (удалить) или 'me' (забрать себе)
create or replace function public.api_admin_take(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := public.admin_me(); t uuid := (p->>'user')::uuid; md text := coalesce(p->>'mode', 'delete'); ids bigint[]; r record; n int := 0; s bigint := 0;
begin
  if md not in ('delete', 'me') then raise exception 'bad_kind'; end if;
  if p->>'all' = 'true' then select array_agg(id) into ids from public.inventory where user_id = t;
  else select array_agg(x::bigint) into ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x; end if;
  for r in select id, price, locked from public.inventory where user_id = t and id = any (coalesce(ids, '{}')) for update loop
    -- предмет стоял ставкой в комнате: уменьшаем ставку игрока
    if r.locked like 'room:%' then
      update public.room_players set value = greatest(0, value - r.price) where room = substr(r.locked, 6) and user_id = t;
    end if;
    if md = 'me' and t <> a then update public.inventory set user_id = a, locked = null where id = r.id;
    else delete from public.inventory where id = r.id; end if;
    n := n + 1; s := s + r.price;
  end loop;
  insert into public.admin_log(admin, action, details) values (a, 'take', jsonb_build_object('user', t, 'mode', md, 'count', n, 'sum', s));
  return jsonb_build_object('taken', n, 'sum', s);
end $$;

-- «админ абьюз» для всех: rain — монеты всем, drop — всем по предмету из кейса, luck — удача ×N на M минут, sale — скидка N% на кейсы, stop — выключить события
create or replace function public.api_admin_abuse(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := public.admin_me(); k text := p->>'kind'; pw numeric := coalesce((p->>'power')::numeric, 0); mins int := greatest(1, least(240, coalesce((p->>'minutes')::int, 10)));
  an text := coalesce((select name from public.wallets where user_id = a), 'Админ'); c public.catalog_cases; w record; it public.catalog_items; n int := 0; msg text;
begin
  if k = 'rain' then
    if pw < 1 or pw > 100000000 then raise exception 'bad_amount'; end if;
    update public.wallets set balance = balance + pw::bigint;
    get diagnostics n = row_count;
    msg := '💸 ДЕНЕЖНЫЙ ДОЖДЬ! Всем +' || replace(to_char(pw::bigint, 'FM999,999,999,999'), ',', ' ') || ' монет';
    insert into public.events(kind, power, ends_at, note, by_name) values ('rain', pw, now() + interval '1 minute', msg, an);
  elsif k = 'drop' then
    select * into c from public.catalog_cases where id = p->>'case' and active;
    if c.id is null then raise exception 'no_case'; end if;
    for w in select user_id from public.wallets loop
      it := public.pick_case(c);
      perform public.give_item(w.user_id, it.id, public.item_price(it, c.mult), true);
      n := n + 1;
    end loop;
    msg := '🎁 РАЗДАЧА! Всем по предмету из кейса «' || c.name || '»';
    insert into public.events(kind, power, ends_at, note, by_name) values ('drop', 1, now() + interval '1 minute', msg, an);
  elsif k = 'luck' then
    if pw < 2 or pw > 50 then raise exception 'bad_amount'; end if;
    msg := '🍀 УДАЧА ×' || pw || ' на ' || mins || ' мин: тайное и легенды выпадают в ' || pw || ' раз чаще';
    insert into public.events(kind, power, ends_at, note, by_name) values ('luck', pw, now() + make_interval(mins => mins), msg, an);
  elsif k = 'sale' then
    if pw < 5 or pw > 90 then raise exception 'bad_amount'; end if;
    msg := '🔥 СКИДКА ' || pw || '% на все кейсы на ' || mins || ' мин';
    insert into public.events(kind, power, ends_at, note, by_name) values ('sale', pw, now() + make_interval(mins => mins), msg, an);
  elsif k = 'stop' then
    update public.events set ends_at = now() where ends_at > now();
    msg := '⏹ Админ выключил все события';
  else
    raise exception 'bad_kind';
  end if;
  insert into public.chat(user_id, name, color, body) values (a, '⚡ АДМИН ' || an, '#ffcf4a', msg);
  insert into public.admin_log(admin, action, details) values (a, 'abuse', p);
  return jsonb_build_object('ok', true, 'players', n, 'msg', msg);
end $$;

-- ======================================================================
-- доступ: сайт может вызывать только api_*
-- ======================================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'api\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;
do $$ begin
  -- бот вызывает эти функции без входа (если они есть в базе)
  if to_regprocedure('public.bot_sub_confirm(jsonb)') is not null then grant execute on function public.bot_sub_confirm(jsonb) to anon, authenticated; end if;
  if to_regprocedure('public.bot_sub_revoke(jsonb)') is not null then grant execute on function public.bot_sub_revoke(jsonb) to anon, authenticated; end if;
end $$;
grant usage on schema public to anon, authenticated;
