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

-- все таблицы закрыты: только функции api_* (они работают от владельца базы)
do $$ declare t text; begin
  foreach t in array array['catalog_items','catalog_cases','seasons','wallets','inventory','free_log','perks','promo_codes','feed','crash_games','rooms','room_players','room_events','trades','quests','subs','bot_config'] loop
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
  select case when it.base_price is not null then greatest(1, round(it.base_price * (0.85 + random()*0.3)))::bigint else public.roll_price(it.rarity, m) end $$;
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
declare rs smallint[]; tot numeric := 0; x numeric; r smallint; chosen smallint; it public.catalog_items;
begin
  select array_agg(distinct i.rarity order by i.rarity) into rs from public.pool_items(p_set) i where coalesce(p_w[i.rarity + 1], 0) > 0;
  if rs is null then raise exception 'empty_case'; end if;
  foreach r in array rs loop tot := tot + p_w[r + 1]; end loop;
  x := random() * tot;
  foreach r in array rs loop chosen := r; x := x - p_w[r + 1]; exit when x <= 0; end loop;
  select * into it from public.pool_items(p_set) i where i.rarity = chosen order by random() limit 1;
  return it;
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
begin
  select * into c from public.catalog_cases where id = p->>'case' and active;
  if c.id is null then raise exception 'no_case'; end if;
  if c.perk is not null and not public.has_perk(u, c.perk) then raise exception 'locked_case'; end if;
  n := greatest(1, least(10, coalesce((p->>'n')::int, 1)));
  if c.price = 0 and not public.has_perk(u, 'unlimited') then
    n := 1;
    if (select count(*) from public.free_log where user_id = u and at > now() - interval '10 minutes') >= 100 then raise exception 'free_limit'; end if;
    insert into public.free_log(user_id) values (u);
  end if;
  cost := c.price * n;
  if w.balance < cost then raise exception 'no_money'; end if;
  update public.wallets set balance = balance - cost, cases = cases + n where user_id = u;
  for i in 1..n loop
    it := public.pick_item(c.set, c.weights);
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
    if m is null or m not in (1.5, 2, 3, 5, 10, 20) then raise exception 'bad_mult'; end if;
    ch := least(0.95, 0.95 / m);
    wantr := least(4, maxr + case when m >= 5 then 2 when m >= 2 then 1 else 0 end);
    -- по множителю выпадают только мемы: у скинов своя цена, в них целятся отдельно
    if p ? 'target' then select * into t from public.pool_items('all') where id = p->>'target' and rarity = wantr and base_price is null; end if;
    if t.id is null then select * into t from public.pool_items('all') where rarity = wantr and base_price is null order by random() limit 1; end if;
    if t.id is null then select * into t from public.pool_items('all') where base_price is null order by random() limit 1; end if;
    tp := round(s * m);
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
      it := public.pick_item(c.set, c.weights); pr := public.item_price(it, c.mult);
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
        it := public.pick_item(c.set, c.weights); pr := public.item_price(it, c.mult);
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
-- доступ: сайт может вызывать только api_*
-- ======================================================================
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'api\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;
grant execute on function public.bot_sub_confirm(jsonb) to anon, authenticated;
grant execute on function public.bot_sub_revoke(jsonb) to anon, authenticated;
grant usage on schema public to anon, authenticated;


-- Каталог Депости: предметы и кейсы. Сгенерировано build_catalog.py. Можно запускать повторно.
insert into public.catalog_items(id, name, rarity, set, base_price) values
  ('m:malyshochek.png', 'Зайчик бурмалдайчик', 4, 'mell', null),
  ('m:tazik.png', 'Я помылся', 4, 'mell', null),
  ('m:burmalda.png', 'БУРМАЛДА', 3, 'mell', null),
  ('m:omg.png', 'О май гад', 3, 'mell', null),
  ('m:dark-drun.png', 'Тёмный Друн', 3, 'mell', null),
  ('m:lysyi.png', 'Шо ты лысый', 2, 'mell', null),
  ('m:voznya.png', 'Я уже красный', 2, 'mell', null),
  ('m:kachok.png', 'МОГ', 2, 'mell', null),
  ('m:am-am-am.png', 'Ам-ам-ам', 1, 'mell', null),
  ('m:biznes.png', 'Что за бизнес', 1, 'mell', null),
  ('m:plaki.png', 'Ам-ам-ам', 1, 'mell', null),
  ('m:zanos.png', 'Танцуют все', 1, 'mell', null),
  ('m:normaldaki.png', 'Нормалдаки', 0, 'mell', null),
  ('m:smena.png', 'Вторая смена', 0, 'mell', null),
  ('m:eldzheevka.png', 'Мелл', 0, 'mell', null),
  ('m:67.png', 'Хз кто это', 0, 'mell', null),
  ('m:yt-1.jpg', 'Симп', 1, 'yt', null),
  ('m:yt-2.jpg', 'Донк', 2, 'yt', null),
  ('m:yt-3.jpg', 'Компот', 2, 'yt', null),
  ('m:yt-4.jpg', 'Мистер Бист', 3, 'yt', null),
  ('m:artemiy.jpg', 'Артемий', 4, 'yt', null),
  ('cs0', 'P250 | Sand Dune', 0, 'cs', 45),
  ('cs1', 'G3SG1 | Desert Storm', 0, 'cs', 60),
  ('cs2', 'MAG-7 | Storm', 0, 'cs', 50),
  ('cs3', 'Nova | Polar Mesh', 0, 'cs', 70),
  ('cs4', 'Glock-18 | Water Elemental', 1, 'cs', 450),
  ('cs5', 'MP7 | Bloodsport', 1, 'cs', 380),
  ('cs6', 'USP-S | Cortex', 1, 'cs', 300),
  ('cs7', 'AK-47 | Redline', 2, 'cs', 1200),
  ('cs8', 'M4A1-S | Printstream', 2, 'cs', 2400),
  ('cs9', 'Desert Eagle | Blaze', 2, 'cs', 1800),
  ('cs10', 'AWP | Asiimov', 3, 'cs', 6500),
  ('cs11', 'AK-47 | Fire Serpent', 3, 'cs', 9000),
  ('cs12', 'M4A4 | Howl', 3, 'cs', 45000),
  ('cs13', 'Karambit | Doppler', 4, 'cs', 55000),
  ('cs14', 'Butterfly Knife | Fade', 4, 'cs', 42000),
  ('cs15', 'Sport Gloves | Pandora''s Box', 4, 'cs', 38000),
  ('cs16', 'AWP | Dragon Lore', 4, 'cs', 62000),
  ('cs17', 'Karambit | Галактика', 4, 'cs', 22290),
  ('cs18', 'Karambit | Закат', 4, 'cs', 22150),
  ('cs19', 'Karambit | Рубин', 4, 'cs', 25350),
  ('cs20', 'Karambit | Тигр', 4, 'cs', 28080),
  ('cs21', 'Karambit | Изумруд', 4, 'cs', 35120),
  ('cs22', 'Karambit | Сапфир', 4, 'cs', 27670),
  ('cs23', 'Karambit | Ультрафиолет', 4, 'cs', 22090),
  ('cs24', 'Karambit | Ночь', 4, 'cs', 31610),
  ('cs25', 'Karambit | Кровавая паутина', 4, 'cs', 28880),
  ('cs26', 'Karambit | Багрянец', 4, 'cs', 26560),
  ('cs27', 'Butterfly | Неон', 4, 'cs', 28250),
  ('cs28', 'Butterfly | Янтарь', 4, 'cs', 29780),
  ('cs29', 'Штык-нож | Синяя сталь', 4, 'cs', 14030),
  ('cs30', 'Butterfly | Багровый', 4, 'cs', 32390),
  ('cs31', 'Штык-нож | Градиент', 4, 'cs', 15010),
  ('cs32', 'Штык-нож | Чёрный', 4, 'cs', 25530),
  ('cs33', 'Butterfly | Синий лёд', 4, 'cs', 27480),
  ('cs34', 'Нож Боуи | Ночь', 4, 'cs', 14700),
  ('cs35', 'Нож Боуи | Тигр', 4, 'cs', 12900),
  ('cs36', 'Нож Боуи | Сталь', 4, 'cs', 17350),
  ('cs37', 'Перчатки | Фиолетовый шторм', 4, 'cs', 10590),
  ('cs38', 'Перчатки | Красная лава', 4, 'cs', 14010),
  ('cs39', 'Перчатки | Янтарный змей', 4, 'cs', 17750),
  ('cs40', 'Перчатки | Белый мрамор', 4, 'cs', 17860),
  ('cs41', 'Перчатки | Кобальт', 4, 'cs', 10540),
  ('cs42', 'Перчатки | Алый', 4, 'cs', 12880),
  ('cs43', 'Перчатки | Лёд', 4, 'cs', 14110),
  ('cs44', 'Перчатки | Токсин', 4, 'cs', 16790),
  ('cs45', 'Перчатки | Камуфляж', 4, 'cs', 15760),
  ('cs46', 'Перчатки | Фиолет', 4, 'cs', 10050),
  ('cs47', 'AK-47 | Тёмный рубин', 1, 'cs', 250),
  ('cs48', 'AWP | Пламя', 3, 'cs', 4890),
  ('cs49', 'AK-47 | Джунгли', 2, 'cs', 1210),
  ('cs50', 'AWP | Пустынный змей', 2, 'cs', 670),
  ('cs51', 'AWP | Розовый туман', 3, 'cs', 3350),
  ('cs52', 'AK-47 | Ночной', 0, 'cs', 31),
  ('cs53', 'AK-47 | Сталь', 0, 'cs', 110),
  ('cs54', 'AK-47 | Неон-роза', 2, 'cs', 1710),
  ('cs55', 'AWP | Оранжевый код', 3, 'cs', 2660),
  ('cs56', 'AWP | Хром', 2, 'cs', 500),
  ('cs57', 'AK-47 | Токсичный', 2, 'cs', 1250),
  ('cs58', 'AK-47 | Ржавчина', 1, 'cs', 480),
  ('cs59', 'AK-47 | Розовый камуфляж', 2, 'cs', 1390),
  ('cs60', 'AK-47 | Сланец', 1, 'cs', 350),
  ('cs61', 'AK-47 | Песчаный тигр', 2, 'cs', 1090),
  ('cs62', 'AK-47 | Уголь', 0, 'cs', 34),
  ('cs63', 'AWP | Неон-райдер', 3, 'cs', 8920),
  ('cs64', 'M4A4 | Голубой лёд', 2, 'cs', 610),
  ('cs65', 'AK-47 | Аметист', 2, 'cs', 1660),
  ('cs66', 'AK-47 | Медь', 1, 'cs', 130),
  ('cs67', 'M4A4 | Кибер', 2, 'cs', 2060),
  ('cs68', 'M4A1-S | Тень', 0, 'cs', 55),
  ('cs69', 'M4A1-S | Призрак', 1, 'cs', 420),
  ('cs70', 'Desert Eagle | Бронза', 1, 'cs', 400),
  ('cs71', 'AK-47 | Красный дракон', 2, 'cs', 810),
  ('cs72', 'M4A4 | Неон-удар', 2, 'cs', 1130),
  ('cs73', 'Desert Eagle | Лавовый поток', 2, 'cs', 560),
  ('cs74', 'M4A1-S | Белый шум', 1, 'cs', 260),
  ('cs75', 'M4A4 | Красная сталь', 1, 'cs', 190),
  ('cs76', 'M4A1-S | Синий хром', 1, 'cs', 200),
  ('cs77', 'Glock-18 | Морская волна', 2, 'cs', 780),
  ('cs78', 'Glock-18 | Бирюзовый шторм', 2, 'cs', 670),
  ('cs79', 'Glock-18 | Багровая сетка', 1, 'cs', 260),
  ('cs80', 'Glock-18 | Хамелеон', 1, 'cs', 390),
  ('cs81', 'Glock-18 | Магма', 2, 'cs', 780),
  ('cs82', 'P250 | Песчаная змея', 0, 'cs', 25),
  ('cs83', 'Glock-18 | Огненный закат', 2, 'cs', 700),
  ('cs84', 'P250 | Сталь и кровь', 1, 'cs', 200),
  ('cs85', 'P2000 | Медовый', 1, 'cs', 250),
  ('cs86', 'Glock-18 | Фиолетовый дым', 2, 'cs', 830),
  ('cs87', 'Five-SeveN | Сумерки', 1, 'cs', 270),
  ('cs88', 'Five-SeveN | Карамель', 1, 'cs', 480),
  ('cs89', 'Glock-18 | Морской змей', 2, 'cs', 1160),
  ('cs90', 'P250 | Песок', 0, 'cs', 67),
  ('cs91', 'Glock-18 | Фуксия', 2, 'cs', 1770),
  ('cs92', 'MP9 | Пепел', 0, 'cs', 53),
  ('cs93', 'P2000 | Графит', 0, 'cs', 34),
  ('cs94', 'USP-S | Серая тень', 0, 'cs', 66),
  ('cs95', 'USP-S | Голограмма', 1, 'cs', 390),
  ('cs96', 'P2000 | Янтарный', 1, 'cs', 180),
  ('cs97', 'MP7 | Ржавый', 0, 'cs', 34),
  ('cs98', 'UMP-45 | Окоп', 0, 'cs', 40),
  ('cs99', 'MP5 | Глубина', 0, 'cs', 81),
  ('cs100', 'MP7 | Комикс', 1, 'cs', 150),
  ('cs101', 'MAC-10 | Ржавчина', 0, 'cs', 77),
  ('cs102', 'Glock-18 | Кислота', 2, 'cs', 1790),
  ('cs103', 'SG 553 | Кровь', 1, 'cs', 240),
  ('cs104', 'AK-47 | Серебро', 1, 'cs', 450),
  ('cs105', 'AK-47 | Песчаник', 0, 'cs', 77),
  ('cs106', 'PP-Bizon | Бронза', 0, 'cs', 30),
  ('cs107', 'AK-47 | Тигровый', 1, 'cs', 140),
  ('cs108', 'AK-47 | Мираж', 1, 'cs', 140),
  ('cs109', 'AK-47 | Розовая пантера', 2, 'cs', 1260),
  ('cs110', 'Nova | Охра', 0, 'cs', 85),
  ('cs111', 'M4A1-S | Медный', 1, 'cs', 270),
  ('cs112', 'MP5 | Синий камуфляж', 0, 'cs', 77),
  ('cs113', 'AK-47 | Киберпанк', 2, 'cs', 1570),
  ('cs114', 'USP-S | Лунный', 1, 'cs', 290),
  ('cs115', 'MP5 | Пустынный', 0, 'cs', 46),
  ('cs116', 'USP-S | Ржавый глушитель', 0, 'cs', 30),
  ('cs117', 'MP9 | Ультрамарин', 2, 'cs', 1670),
  ('cs118', 'AK-47 | Красная сетка', 1, 'cs', 320),
  ('cs119', 'M4A4 | Снежный камуфляж', 1, 'cs', 240),
  ('cs120', 'AK-47 | Песчаная буря', 0, 'cs', 38),
  ('cs121', 'MP9 | Оранжевая угроза', 2, 'cs', 540),
  ('cs122', 'MP5 | Пепельный', 0, 'cs', 60),
  ('cs123', 'M4A4 | Розовые шипы', 1, 'cs', 120),
  ('cs124', 'M4A4 | Апельсин', 1, 'cs', 130),
  ('cs125', 'AK-47 | Хаки', 0, 'cs', 100),
  ('cs126', 'M4A4 | Пламя', 1, 'cs', 360),
  ('cs127', 'Хантсмен | Ночь', 4, 'cs', 9140),
  ('cs128', 'Karambit | Глубина', 4, 'cs', 23110),
  ('cs129', 'Штык-нож | Вулкан', 4, 'cs', 22180),
  ('cs130', 'Karambit | Кровавая луна', 4, 'cs', 31660),
  ('cs131', 'Karambit | Янтарный тигр', 4, 'cs', 22600),
  ('cs132', 'Karambit | Мираж', 4, 'cs', 22100),
  ('cs133', 'Нож Боуи | Ржавый закат', 4, 'cs', 16600),
  ('cs134', 'Нож Боуи | Звёздная ночь', 4, 'cs', 14720),
  ('cs135', 'Butterfly | Пламя', 4, 'cs', 33610),
  ('cs136', 'Butterfly | Рубин', 4, 'cs', 30930),
  ('cs137', 'Боевые перчатки | Фиолет', 4, 'cs', 9660),
  ('cs138', 'Боевые перчатки | Красная сеть', 4, 'cs', 9040),
  ('cs139', 'Боевые перчатки | Кобальт', 4, 'cs', 9320),
  ('cs140', 'Боевые перчатки | Янтарь', 4, 'cs', 16660),
  ('cs141', 'Боевые перчатки | Графит', 4, 'cs', 11280),
  ('cs142', 'Боевые перчатки | Токсин', 4, 'cs', 14080),
  ('cs143', 'Боевые перчатки | Бирюза', 4, 'cs', 9020),
  ('cs144', 'Боевые перчатки | Белый камуфляж', 4, 'cs', 10990),
  ('cs145', 'Боевые перчатки | Леопард', 4, 'cs', 9040),
  ('cs146', 'Боевые перчатки | Полночь', 4, 'cs', 9030),
  ('cs147', 'Боевые перчатки | Сталь', 4, 'cs', 19140),
  ('cs148', 'Боевые перчатки | Кровь', 4, 'cs', 19710),
  ('cs149', 'AWP | Тихая ночь', 1, 'cs', 190),
  ('cs150', 'AWP | Неоновый сон', 3, 'cs', 2500),
  ('cs151', 'AWP | Огненный змей', 3, 'cs', 2530),
  ('cs152', 'AWP | Хаос', 3, 'cs', 8320),
  ('cs153', 'AWP | Пустынный лис', 1, 'cs', 120),
  ('cs154', 'AWP | Глубокий океан', 1, 'cs', 290),
  ('cs155', 'AK-47 | Розовый ящер', 2, 'cs', 2010),
  ('cs156', 'AK-47 | Снег', 0, 'cs', 85),
  ('cs157', 'AK-47 | Хамелеон', 2, 'cs', 620),
  ('cs158', 'AK-47 | Красный уголь', 1, 'cs', 430),
  ('cs159', 'AK-47 | Сафари', 1, 'cs', 120),
  ('cs160', 'AK-47 | Розовая вспышка', 2, 'cs', 900),
  ('cs161', 'M4A1-S | Арктика', 1, 'cs', 140),
  ('cs162', 'AK-47 | Малиновый', 1, 'cs', 400),
  ('cs163', 'AK-47 | Болото', 0, 'cs', 98),
  ('cs164', 'AK-47 | Кирпич', 0, 'cs', 64),
  ('cs165', 'M4A1-S | Платина', 1, 'cs', 210),
  ('cs166', 'AK-47 | Фиолетовая ночь', 1, 'cs', 200),
  ('cs167', 'M4A1-S | Сафари', 0, 'cs', 90),
  ('cs168', 'AK-47 | Тлеющий', 2, 'cs', 660),
  ('cs169', 'M4A4 | Сирень', 1, 'cs', 140),
  ('cs170', 'M4A1-S | Синий импульс', 2, 'cs', 810),
  ('cs171', 'M4A1-S | Олива', 0, 'cs', 88),
  ('cs172', 'M4A4 | Электрик', 2, 'cs', 520),
  ('cs173', 'Desert Eagle | Закат', 2, 'cs', 1390),
  ('cs174', 'P2000 | Ночной хром', 0, 'cs', 27),
  ('cs175', 'Desert Eagle | Синий кобальт', 2, 'cs', 2160),
  ('cs176', 'P2000 | Белый шум', 0, 'cs', 100),
  ('cs177', 'P250 | Акварель', 1, 'cs', 210),
  ('cs178', 'P250 | Пастель', 0, 'cs', 57),
  ('cs179', 'Desert Eagle | Магма', 2, 'cs', 940),
  ('cs180', 'P2000 | Градиент', 2, 'cs', 870),
  ('cs181', 'P250 | Мох', 0, 'cs', 69),
  ('cs182', 'P2000 | Тёмный', 0, 'cs', 52),
  ('cs183', 'Desert Eagle | Код красный', 2, 'cs', 1010),
  ('cs184', 'USP-S | Розовая лихорадка', 2, 'cs', 1430),
  ('cs185', 'MP7 | Лесной', 0, 'cs', 40),
  ('cs186', 'MP7 | Камуфляж', 0, 'cs', 53),
  ('cs187', 'P90 | Бирюзовый', 1, 'cs', 410),
  ('cs188', 'P90 | Кровавый', 1, 'cs', 190),
  ('cs189', 'MP9 | Шмель', 1, 'cs', 260),
  ('cs190', 'Tec-9 | Лава', 1, 'cs', 160),
  ('cs191', 'Tec-9 | Ржавчина', 0, 'cs', 73),
  ('cs192', 'Nova | Ржавый', 0, 'cs', 100),
  ('cs193', 'Galil AR | Джунгли', 1, 'cs', 380),
  ('cs194', 'Nova | Сталь', 0, 'cs', 25),
  ('cs195', 'Sawed-Off | Банан', 1, 'cs', 320),
  ('cs196', 'SG 553 | Ультрамарин', 2, 'cs', 1160),
  ('cs197', 'M4A4 | Конфетти', 1, 'cs', 370),
  ('cs198', 'M4A4 | Блюз', 1, 'cs', 350),
  ('cs199', 'M4A1-S | Пески', 0, 'cs', 25),
  ('cs200', 'M4A4 | Ночь', 0, 'cs', 83),
  ('cs201', 'SG 553 | Тьма', 0, 'cs', 56),
  ('cs202', 'M4A4 | Жёлтая угроза', 2, 'cs', 1370),
  ('cs203', 'AK-47 | Кофе', 0, 'cs', 79),
  ('cs204', 'M4A1-S | Фрост', 0, 'cs', 45),
  ('cs205', 'R8 Revolver | Ночь', 0, 'cs', 41),
  ('cs206', 'Tec-9 | Сталь', 0, 'cs', 50),
  ('cs207', 'CZ75 | Пламя', 1, 'cs', 140),
  ('cs208', 'MAC-10 | Болото', 0, 'cs', 37),
  ('cs209', 'Tec-9 | Пепел', 0, 'cs', 84),
  ('cs210', 'MP5 | Тень', 0, 'cs', 26),
  ('cs211', 'P250 | Хамелеон', 0, 'cs', 100),
  ('cs212', 'P2000 | Медь', 0, 'cs', 78),
  ('cs213', 'Glock-18 | Радиация', 2, 'cs', 550),
  ('cs214', 'MP9 | Ночной', 0, 'cs', 55),
  ('cs215', 'CZ75 | Болотный', 0, 'cs', 67),
  ('cs216', 'Karambit | Фламинго', 4, 'cs', 24580),
  ('cs217', 'Хантсмен | Ржавчина', 4, 'cs', 12890),
  ('cs218', 'Хантсмен | Красный', 4, 'cs', 9800),
  ('cs219', 'Хантсмен | Медь', 4, 'cs', 14660),
  ('cs220', 'Хантсмен | Сумрак', 4, 'cs', 14500),
  ('cs221', 'Хантсмен | Изумруд', 4, 'cs', 15280),
  ('cs222', 'Хантсмен | Сапфир', 4, 'cs', 16980),
  ('cs223', 'Хантсмен | Закат', 4, 'cs', 16340),
  ('cs224', 'Хантсмен | Аметист', 4, 'cs', 11520),
  ('cs225', 'Хантсмен | Морская гладь', 4, 'cs', 14410),
  ('cs226', 'Фальшион | Кровь', 4, 'cs', 14020),
  ('cs227', 'Фальшион | Аметист', 4, 'cs', 13210),
  ('cs228', 'Штык-нож | Янтарная рукоять', 4, 'cs', 21110),
  ('cs229', 'Фальшион | Космос', 4, 'cs', 14970),
  ('cs230', 'Штык-нож | Сталь', 4, 'cs', 21760),
  ('cs231', 'Спортивные перчатки | Ультрафиолет', 4, 'cs', 29200),
  ('cs232', 'Спортивные перчатки | Красный хаос', 4, 'cs', 25830),
  ('cs233', 'Karambit | Тигровый зуб', 4, 'cs', 25360),
  ('cs234', 'Karambit | Глубокий космос', 4, 'cs', 36160),
  ('cs235', 'Karambit | Закатный огонь', 4, 'cs', 35600),
  ('cs236', 'Karambit | Кровь', 4, 'cs', 26840),
  ('cs237', 'Боевые перчатки | Аметист', 4, 'cs', 15170),
  ('cs238', 'Спортивные перчатки | Кислота', 4, 'cs', 29360),
  ('cs239', 'Спортивные перчатки | Оранжевый', 4, 'cs', 27760),
  ('cs240', 'Перчатки | Пустынный камуфляж', 4, 'cs', 13360),
  ('cs241', 'Перчатки | Лаванда', 4, 'cs', 9010),
  ('cs242', 'AWP | Огненный дракон', 3, 'cs', 5850),
  ('cs243', 'AWP | Белый код', 3, 'cs', 5240),
  ('cs244', 'AWP | Ультрамарин', 3, 'cs', 4080),
  ('cs245', 'AWP | Аметист', 2, 'cs', 1620),
  ('cs246', 'Galil AR | Ржавый', 0, 'cs', 39),
  ('cs247', 'AK-47 | Граффити', 1, 'cs', 310),
  ('cs248', 'M4A1-S | Иней', 1, 'cs', 470),
  ('cs249', 'AK-47 | Кровавый', 1, 'cs', 120),
  ('cs250', 'AK-47 | Красный хаос', 1, 'cs', 470),
  ('cs251', 'AK-47 | Красная угроза', 2, 'cs', 520),
  ('cs252', 'AK-47 | Пламя', 1, 'cs', 230),
  ('cs253', 'AK-47 | Огонь', 1, 'cs', 350),
  ('cs254', 'FAMAS | Розовый неон', 1, 'cs', 220),
  ('cs255', 'AK-47 | Медный узор', 1, 'cs', 140),
  ('cs256', 'FAMAS | Ледник', 1, 'cs', 130),
  ('cs257', 'Glock-18 | Тёмная кровь', 1, 'cs', 230),
  ('cs258', 'AK-47 | Неоновая волна', 2, 'cs', 760),
  ('cs259', 'AK-47 | Терракота', 0, 'cs', 100),
  ('cs260', 'Glock-18 | Комикс', 2, 'cs', 500),
  ('cs261', 'P2000 | Синий хват', 0, 'cs', 38),
  ('cs262', 'MP7 | Красный шум', 1, 'cs', 120),
  ('cs263', 'MP9 | Молния', 2, 'cs', 640),
  ('cs264', 'MP9 | Фиолетовый разряд', 2, 'cs', 1490),
  ('cs265', 'Desert Eagle | Розовый мрамор', 2, 'cs', 1830),
  ('cs266', 'P2000 | Ржавый', 0, 'cs', 81),
  ('cs267', 'P250 | Ледяной камуфляж', 0, 'cs', 89),
  ('cs268', 'P250 | Граффити', 1, 'cs', 130),
  ('cs269', 'Glock-18 | Ночной клуб', 1, 'cs', 230),
  ('cs270', 'P2000 | Песчаный закат', 1, 'cs', 320),
  ('cs271', 'USP-S | Розовый кибер', 2, 'cs', 550),
  ('cs272', 'MP9 | Шершень', 1, 'cs', 130),
  ('cs273', 'UMP-45 | Пыль', 0, 'cs', 54),
  ('cs274', 'Nova | Цветы', 1, 'cs', 250),
  ('cs275', 'MP5 | Лес', 0, 'cs', 43),
  ('cs276', 'UMP-45 | Индиго', 0, 'cs', 49),
  ('cs277', 'Sawed-Off | Медь', 0, 'cs', 57),
  ('cs278', 'Nova | Бронза', 0, 'cs', 52),
  ('cs279', 'Sawed-Off | Карнавал', 1, 'cs', 340),
  ('cs280', 'M249 | Сафари', 0, 'cs', 83),
  ('cs281', 'XM1014 | Тень', 0, 'cs', 84),
  ('cs282', 'MP5 | Неон', 1, 'cs', 130),
  ('cs283', 'AUG | Ночь', 0, 'cs', 95),
  ('cs284', 'Negev | Жёлтая полоса', 0, 'cs', 66),
  ('cs285', 'Galil AR | Кирпич', 0, 'cs', 98),
  ('cs286', 'MP9 | Фиолетовый', 1, 'cs', 130),
  ('cs287', 'MP5 | Синтвейв', 2, 'cs', 1140),
  ('cs288', 'Dual Berettas | Мозаика', 1, 'cs', 160),
  ('cs289', 'MP9 | Глубина', 1, 'cs', 130),
  ('cs290', 'Dual Berettas | Ржавчина', 0, 'cs', 63),
  ('cs291', 'P250 | Белый камуфляж', 0, 'cs', 89),
  ('cs292', 'Desert Eagle | Чёрная кровь', 1, 'cs', 400),
  ('cs293', 'P2000 | Угли', 1, 'cs', 480),
  ('cs294', 'MP7 | Лава', 2, 'cs', 1760),
  ('cs295', 'P2000 | Тёмный рубин', 0, 'cs', 100),
  ('cs296', 'MP9 | Синий ток', 1, 'cs', 460),
  ('cs297', 'Desert Eagle | Вулкан', 2, 'cs', 1540),
  ('cs298', 'Штык-нож | Тигровое дерево', 4, 'cs', 20640),
  ('cs299', 'Нож Боуи | Кровь', 4, 'cs', 10640),
  ('cs300', 'Штык-нож | Тёмная сталь', 4, 'cs', 16870),
  ('cs301', 'Хантсмен | Ржавый тигр', 4, 'cs', 12350),
  ('cs302', 'Перчатки | Фуксия', 4, 'cs', 9100),
  ('cs303', 'Перчатки | Лесной камуфляж', 4, 'cs', 14260),
  ('cs304', 'Спортивные перчатки | Индиго', 4, 'cs', 28120),
  ('cs305', 'Перчатки | Тень', 4, 'cs', 13320),
  ('cs306', 'Перчатки | Синий шёлк', 4, 'cs', 17380),
  ('cs307', 'Хантсмен | Кровавый неон', 4, 'cs', 12550),
  ('cs308', 'Фальшион | Сталь', 4, 'cs', 16050),
  ('cs309', 'Karambit | Тень', 4, 'cs', 22120),
  ('cs310', 'Талон | Ночь', 4, 'cs', 21300),
  ('cs311', 'Талон | Огонь', 4, 'cs', 26180),
  ('cs312', 'Талон | Рубин', 4, 'cs', 23230),
  ('cs313', 'Karambit | Янтарь', 4, 'cs', 26240),
  ('cs314', 'Перчатки | Сумерки', 4, 'cs', 13760),
  ('cs315', 'Перчатки | Пустыня', 4, 'cs', 14450),
  ('cs316', 'Перчатки | Красный дракон', 4, 'cs', 13260),
  ('cs317', 'Перчатки | Лайм', 4, 'cs', 19190),
  ('cs318', 'Karambit | Дамаск', 4, 'cs', 25300),
  ('cs319', 'Five-SeveN | Бирюзовая молния', 2, 'cs', 650),
  ('cs320', 'Desert Eagle | Красный дракон', 3, 'cs', 6440),
  ('cs321', 'Glock-18 | Ледяной шторм', 2, 'cs', 1310),
  ('cs322', 'Desert Eagle | Королевский узор', 3, 'cs', 7940),
  ('cs323', 'P2000 | Фиолетовая плазма', 2, 'cs', 1160),
  ('cs324', 'Glock-18 | Токсичная молния', 2, 'cs', 610),
  ('cs325', 'Five-SeveN | Белый рыцарь', 2, 'cs', 1220),
  ('cs326', 'P250 | Оранжевый рывок', 1, 'cs', 350),
  ('cs327', 'Glock-18 | Большая волна', 3, 'cs', 7470),
  ('cs328', 'Desert Eagle | Медная гравировка', 2, 'cs', 1100),
  ('cs329', 'Desert Eagle | Фиолетовая молния', 2, 'cs', 1950),
  ('cs330', 'Desert Eagle | Пиксельный камуфляж', 1, 'cs', 430),
  ('cs331', 'P2000 | Серебряная гравюра', 2, 'cs', 500),
  ('cs332', 'Glock-18 | Синий тигр', 2, 'cs', 1620),
  ('cs333', 'P2000 | Красный разряд', 1, 'cs', 300),
  ('cs334', 'Five-SeveN | Сакура', 3, 'cs', 8730),
  ('gold-karambit', '★ Золотой Karambit | Депость', 4, 'special', null),
  ('sub-badge', '📢 Подписчик Депости', 3, 'special', null),
  ('pk:start:../../memes/normaldaki.png', 'Нормалдаки', 0, 'pk:start', null),
  ('pk:start:../../memes/biznes.png', 'Что за бизнес', 1, 'pk:start', null),
  ('pk:start:../../memes/lysyi.png', 'Шо ты лысый', 2, 'pk:start', null),
  ('pk:start:../../memes/burmalda.png', 'БУРМАЛДА', 3, 'pk:start', null),
  ('pk:start:../../memes/tazik.png', 'Я помылся', 4, 'pk:start', null)
on conflict (id) do update set name = excluded.name, rarity = excluded.rarity, set = excluded.set, base_price = excluded.base_price;
update public.catalog_cases set active = false;
insert into public.catalog_cases(id, name, price, weights, mult, set, perk, active) values
  ('free', 'Бесплатный', 0, array[60, 25, 10, 4, 1], 1, 'mell', null, true),
  ('murino', 'Мурино', 150, array[50, 30, 13, 5, 2], 1, 'mell', null, true),
  ('voznya', 'Пошла возня', 400, array[35, 35, 18, 9, 3], 1, 'mell', null, true),
  ('gold', 'Легендарный', 600, array[25, 33, 22, 14, 6], 1, 'mell', null, true),
  ('lux', 'Только редкие', 1500, array[0, 0, 55, 35, 10], 1, 'mell', null, true),
  ('cs', 'Скины CS2', 400, array[700, 220, 60, 16, 4], 1, 'cs', null, true),
  ('mytishchi', 'Мытищи', 2500, array[30, 32, 22, 12, 4], 6.0, 'mell', null, true),
  ('ytpro', 'Ютуберы PRO', 3000, array[0, 20, 35, 30, 15], 3.0, 'yt', null, true),
  ('burmalda', 'Бурмалда', 5000, array[20, 30, 28, 16, 6], 9.0, 'mell', null, true),
  ('cselite', 'CS2 Элитный', 3700, array[0, 30, 45, 18, 7], 1, 'cs', null, true),
  ('csknife', 'Нож или перчатки', 21500, array[0, 0, 0, 0, 1], 1, 'cs', null, true),
  ('dodep', 'Додеп', 10000, array[0, 30, 38, 22, 10], 12.0, 'mell', null, true),
  ('major', 'Мажор', 25000, array[0, 0, 50, 35, 15], 20.0, 'mell', null, true),
  ('millioner', 'Миллионер', 50000, array[0, 0, 30, 45, 25], 28.0, 'mell', null, true),
  ('secret', 'Секретный', 14500, array[0, 0, 0, 55, 45], 8.0, 'secret', 'secretcase', true),
  ('lastchance', 'Последний шанс', 100000, array[0, 0, 0, 60, 40], 38.0, 'mell', null, true),
  ('svoi', 'Для своих', 2200, array[30, 32, 22, 11, 5], 2.7, 'all', 'subscriber', true),
  ('yt', 'Ютуберы', 250, array[40, 30, 18, 9, 3], 1, 'yt', null, true),
  ('pk-start', 'Стартовый пак', 300, array[45, 30, 15, 7, 3], 1.0, 'pk:start', null, true)
on conflict (id) do update set name = excluded.name, price = excluded.price, weights = excluded.weights, mult = excluded.mult, set = excluded.set, perk = excluded.perk, active = true;
