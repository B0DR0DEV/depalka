-- Депость: расширение профиля, коллекций, достижений, друзей, витрины и истории.
-- Применять ОДИН РАЗ после установленного depost-install.sql / online/install.sql.
-- Миграция не удаляет и не переинициализирует существующие таблицы или баланс.

begin;

create table if not exists public.player_progress (
  user_id uuid primary key references auth.users on delete cascade,
  xp bigint not null default 0 check (xp >= 0),
  selected_title text not null default 'Новичок',
  selected_frame text not null default 'base',
  updated_at timestamptz not null default now()
);

create table if not exists public.collection_discoveries (
  user_id uuid not null references auth.users on delete cascade,
  item_id text not null references public.catalog_items(id) on delete cascade,
  first_seen timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index if not exists collection_discoveries_user_seen
  on public.collection_discoveries(user_id, first_seen desc);

create table if not exists public.achievement_claims (
  user_id uuid not null references auth.users on delete cascade,
  code text not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, code)
);

create table if not exists public.weekly_event_claims (
  user_id uuid not null references auth.users on delete cascade,
  week_start date not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, week_start)
);

create table if not exists public.profile_showcase (
  user_id uuid not null references auth.users on delete cascade,
  slot smallint not null check (slot between 1 and 3),
  inventory_id bigint not null references public.inventory(id) on delete cascade,
  primary key (user_id, slot),
  unique (inventory_id)
);

create table if not exists public.friendships (
  user_id uuid not null references auth.users on delete cascade,
  friend_id uuid not null references auth.users on delete cascade,
  status text not null check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
create index if not exists friendships_incoming on public.friendships(friend_id, status);

create table if not exists public.game_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  kind text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists game_history_user_created
  on public.game_history(user_id, created_at desc);

-- Существующие предметы тоже считаются уже найденными. Баланс и инвентарь не меняются.
insert into public.collection_discoveries(user_id, item_id, first_seen)
select user_id, item_id, min(created_at)
from public.inventory
group by user_id, item_id
on conflict (user_id, item_id) do nothing;

insert into public.player_progress(user_id, xp)
select user_id, count(*)::bigint * 10
from public.collection_discoveries
group by user_id
on conflict (user_id) do update
set xp = greatest(public.player_progress.xp, excluded.xp),
    updated_at = now();

-- Таблицы приватны: клиент работает только через функции api_*.
do $$
declare t text;
begin
  foreach t in array array[
    'player_progress','collection_discoveries','achievement_claims',
    'weekly_event_claims','profile_showcase','friendships','game_history'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

create or replace function public.extra_inventory_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare fresh boolean;
begin
  insert into public.collection_discoveries(user_id, item_id)
  values (new.user_id, new.item_id)
  on conflict (user_id, item_id) do nothing;
  fresh := found;

  if fresh then
    insert into public.player_progress(user_id, xp)
    values (new.user_id, 10)
    on conflict (user_id) do update
      set xp = public.player_progress.xp + 10, updated_at = now();
  else
    insert into public.player_progress(user_id)
    values (new.user_id)
    on conflict (user_id) do nothing;
  end if;

  insert into public.game_history(user_id, kind, details)
  values (new.user_id, 'item_get',
    jsonb_build_object('item', new.item_id, 'price', new.price, 'new_discovery', fresh));

  return new;
end $$;

create or replace function public.extra_inventory_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.game_history(user_id, kind, details)
  values (old.user_id, 'item_removed',
    jsonb_build_object('item', old.item_id, 'price', old.price));
  return old;
end $$;

drop trigger if exists extra_inventory_insert_trg on public.inventory;
create trigger extra_inventory_insert_trg
after insert on public.inventory
for each row execute function public.extra_inventory_insert();

drop trigger if exists extra_inventory_delete_trg on public.inventory;
create trigger extra_inventory_delete_trg
after delete on public.inventory
for each row execute function public.extra_inventory_delete();

create or replace function public.extra_crash_history()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.game_history(user_id, kind, details)
    values (new.user_id, 'crash_start', jsonb_build_object('bet', new.bet));
    return new;
  end if;

  if old.cashout is null and new.cashout is not null then
    insert into public.game_history(user_id, kind, details)
    values (new.user_id, 'crash_cashout',
      jsonb_build_object('bet', new.bet, 'multiplier', new.cashout, 'win', new.win));
  end if;

  if not old.done and new.done then
    insert into public.game_history(user_id, kind, details)
    values (new.user_id, case when new.cashout is null then 'crash_loss' else 'crash_end' end,
      jsonb_build_object('bet', new.bet, 'crash_point', new.cp, 'multiplier', new.cashout, 'win', new.win));
  end if;

  return new;
end $$;

drop trigger if exists extra_crash_insert_trg on public.crash_games;
create trigger extra_crash_insert_trg
after insert on public.crash_games
for each row execute function public.extra_crash_history();

drop trigger if exists extra_crash_update_trg on public.crash_games;
create trigger extra_crash_update_trg
after update of cashout, done on public.crash_games
for each row execute function public.extra_crash_history();

-- Коллекции, уровень, цепочки достижений и событие недели.
create or replace function public.api_extra_hub(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  u uuid := public.me();
  w public.wallets;
  pr public.player_progress;
  cnt int;
  total int;
  v_week date := date_trunc('week', now())::date;
  week_cnt int;
  level_no int;
  achievements jsonb;
  discoveries jsonb;
  showcase jsonb;
  unlocked_titles jsonb;
  event_title text;
  event_desc text;
begin
  select * into w from public.wallets where user_id = u;
  if w.user_id is null then raise exception 'no_player'; end if;

  insert into public.player_progress(user_id) values (u) on conflict do nothing;
  select * into pr from public.player_progress where user_id = u;

  select count(*) into cnt from public.collection_discoveries where user_id = u;
  select count(*) into total from public.catalog_items where set <> 'special';
  select count(*) into week_cnt
    from public.collection_discoveries
    where user_id = u and first_seen >= v_week and first_seen < v_week + 7;

  level_no := floor(sqrt(pr.xp::numeric / 100))::int + 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'item', d.item_id, 'name', c.name, 'rarity', c.rarity, 'set', c.set, 'first_seen', d.first_seen
  ) order by c.rarity desc, c.name), '[]'::jsonb)
  into discoveries
  from public.collection_discoveries d
  join public.catalog_items c on c.id = d.item_id
  where d.user_id = u;

  select coalesce(jsonb_agg(jsonb_build_object(
    'code', a.code, 'title', a.title, 'description', a.description,
    'goal', a.goal, 'progress', least(a.goal, a.progress), 'reward_xp', a.reward_xp,
    'claimed', exists(select 1 from public.achievement_claims x where x.user_id = u and x.code = a.code)
  ) order by a.sort_order), '[]'::jsonb)
  into achievements
  from (
    select d.*, case
      when d.code like 'collect_%' then cnt
      when d.code like 'cases_%' then w.cases
      else w.streak
    end as progress
    from (values
      ('collect_5','Первый альбом','Найди 5 разных предметов',5,40,1),
      ('collect_25','Коллекционер','Найди 25 разных предметов',25,100,2),
      ('collect_100','Архивариус','Найди 100 разных предметов',100,300,3),
      ('cases_10','Разогрев','Открой 10 кейсов',10,50,4),
      ('cases_50','Охотник за дропами','Открой 50 кейсов',50,150,5),
      ('streak_7','Постоянный','Заходи 7 дней подряд',7,200,6)
    ) as d(code,title,description,goal,reward_xp,sort_order)
  ) a;

  select coalesce(jsonb_agg(jsonb_build_object(
    'slot', s.slot, 'id', i.id, 'item', i.item_id, 'price', i.price
  ) order by s.slot), '[]'::jsonb)
  into showcase
  from public.profile_showcase s
  join public.inventory i on i.id = s.inventory_id and i.user_id = u;

  select coalesce(jsonb_agg(t.title order by t.rank), '[]'::jsonb)
  into unlocked_titles
  from (values
    ('Новичок',0,''),
    ('Собиратель',1,'collect_5'),
    ('Коллекционер',2,'collect_25'),
    ('Архивариус',3,'collect_100'),
    ('Открывашка',4,'cases_10'),
    ('Мастер кейсов',5,'cases_50'),
    ('Постоянный',6,'streak_7')
  ) t(title,rank,code)
  where t.code = '' or exists(select 1 from public.achievement_claims a where a.user_id=u and a.code=t.code);

  if extract(week from v_week)::int % 3 = 0 then
    event_title := 'Неделя коллекционера';
    event_desc := 'Найди 3 разных предмета за эту неделю.';
  elsif extract(week from week)::int % 3 = 1 then
    event_title := 'Неделя открытий';
    event_desc := 'Пополняй коллекцию новыми предметами.';
  else
    event_title := 'Неделя редкостей';
    event_desc := 'Открывай новые редкости и собирай коллекцию.';
  end if;

  return jsonb_build_object(
    'xp', pr.xp, 'level', level_no, 'title', pr.selected_title, 'frame', pr.selected_frame,
    'xp_current', pr.xp - ((level_no - 1) * (level_no - 1) * 100),
    'xp_next', (level_no * level_no * 100) - ((level_no - 1) * (level_no - 1) * 100),
    'collection_count', cnt, 'collection_total', total, 'collection', discoveries,
    'achievements', achievements, 'unlocked_titles', unlocked_titles,
    'showcase', showcase,
    'weekly', jsonb_build_object(
      'week_start', v_week, 'title', event_title, 'description', event_desc,
      'progress', least(3, week_cnt), 'goal', 3, 'reward_xp', 75,
      'claimed', exists(select 1 from public.weekly_event_claims x where x.user_id=u and x.week_start=v_week)
    )
  );
end $$;

create or replace function public.api_extra_claim(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := public.me();
  code text := coalesce(p->>'code','');
  w public.wallets;
  week date := date_trunc('week', now())::date;
  progress_now int := 0;
  goal_now int := 0;
  reward int := 0;
begin
  select * into w from public.wallets where user_id=u;
  if w.user_id is null then raise exception 'no_player'; end if;

  if code = 'weekly' then
    select count(*) into progress_now from public.collection_discoveries
      where user_id=u and first_seen>=v_week and first_seen<v_week+7;
    if progress_now < 3 then raise exception 'quest_not_ready'; end if;
    insert into public.weekly_event_claims(user_id,week_start) values(u,week)
      on conflict do nothing;
    if not found then raise exception 'already_claimed'; end if;
    reward := 75;
  else
    case code
      when 'collect_5' then select count(*) into progress_now from public.collection_discoveries where user_id=u; goal_now:=5; reward:=40;
      when 'collect_25' then select count(*) into progress_now from public.collection_discoveries where user_id=u; goal_now:=25; reward:=100;
      when 'collect_100' then select count(*) into progress_now from public.collection_discoveries where user_id=u; goal_now:=100; reward:=300;
      when 'cases_10' then progress_now:=w.cases; goal_now:=10; reward:=50;
      when 'cases_50' then progress_now:=w.cases; goal_now:=50; reward:=150;
      when 'streak_7' then progress_now:=w.streak; goal_now:=7; reward:=200;
      else raise exception 'bad_code';
    end case;
    if progress_now < goal_now then raise exception 'quest_not_ready'; end if;
    insert into public.achievement_claims(user_id,code) values(u,code)
      on conflict do nothing;
    if not found then raise exception 'already_claimed'; end if;
  end if;

  insert into public.player_progress(user_id,xp) values(u,reward)
    on conflict(user_id) do update set xp=public.player_progress.xp+reward, updated_at=now();

  return jsonb_build_object('reward_xp',reward,'xp',(select xp from public.player_progress where user_id=u));
end $$;

create or replace function public.api_extra_profile(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  target uuid := coalesce((p->>'user')::uuid, public.me());
  w public.wallets;
  pr public.player_progress;
  cnt int;
  show jsonb;
begin
  perform public.me();
  select * into w from public.wallets where user_id=target;
  if w.user_id is null then raise exception 'no_player'; end if;
  select * into pr from public.player_progress where user_id=target;
  select count(*) into cnt from public.collection_discoveries where user_id=target;
  select coalesce(jsonb_agg(jsonb_build_object(
    'slot',s.slot,'id',i.id,'item',i.item_id,'price',i.price
  ) order by s.slot),'[]'::jsonb)
  into show
  from public.profile_showcase s
  join public.inventory i on i.id=s.inventory_id and i.user_id=target;
  return jsonb_build_object(
    'id',target,'xp',coalesce(pr.xp,0),'level',floor(sqrt(coalesce(pr.xp,0)::numeric/100))::int+1,
    'title',coalesce(pr.selected_title,'Новичок'),'frame',coalesce(pr.selected_frame,'base'),
    'collection_count',cnt,'showcase',show
  );
end $$;

create or replace function public.api_extra_showcase(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := public.me();
  ids bigint[];
  cnt int;
begin
  select coalesce(array_agg(x::bigint order by ordinality),'{}')
  into ids
  from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) with ordinality as a(x,ordinality);
  if coalesce(array_length(ids,1),0)>3 then raise exception 'too_many'; end if;
  select count(*) into cnt from public.inventory
    where user_id=u and locked is null and id=any(ids);
  if cnt<>coalesce(array_length(ids,1),0) then raise exception 'bad_items'; end if;

  delete from public.profile_showcase where user_id=u;
  insert into public.profile_showcase(user_id,slot,inventory_id)
  select u, ordinality::smallint, x::bigint
  from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) with ordinality as a(x,ordinality);
  return public.api_extra_profile(jsonb_build_object('user',u));
end $$;

create or replace function public.api_extra_set_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := public.me();
  title_in text := coalesce(p->>'title','Новичок');
  frame_in text := coalesce(p->>'frame','base');
  need_code text;
begin
  need_code := case title_in
    when 'Новичок' then ''
    when 'Собиратель' then 'collect_5'
    when 'Коллекционер' then 'collect_25'
    when 'Архивариус' then 'collect_100'
    when 'Открывашка' then 'cases_10'
    when 'Мастер кейсов' then 'cases_50'
    when 'Постоянный' then 'streak_7'
    else null end;
  if need_code is null then raise exception 'bad_title'; end if;
  if need_code<>'' and not exists(select 1 from public.achievement_claims where user_id=u and code=need_code) then
    raise exception 'title_locked';
  end if;
  if frame_in not in ('base','violet','gold') then raise exception 'bad_frame'; end if;
  if frame_in='violet' and not exists(select 1 from public.achievement_claims where user_id=u and code='collect_25') then raise exception 'frame_locked'; end if;
  if frame_in='gold' and not exists(select 1 from public.achievement_claims where user_id=u and code='collect_100') then raise exception 'frame_locked'; end if;

  insert into public.player_progress(user_id,selected_title,selected_frame)
    values(u,title_in,frame_in)
    on conflict(user_id) do update set selected_title=excluded.selected_title,
      selected_frame=excluded.selected_frame,updated_at=now();
  return public.api_extra_profile(jsonb_build_object('user',u));
end $$;

create or replace function public.api_extra_history(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid := public.me(); lim int := greatest(1,least(100,coalesce((p->>'limit')::int,40)));
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'details',details,'at',created_at) order by created_at desc)
    from (select id,kind,details,created_at from public.game_history
      where user_id=u order by created_at desc limit lim) q
  ),'[]'::jsonb);
end $$;

create or replace function public.api_friends(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid := public.me(); friends_json jsonb; incoming_json jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',w.user_id,'name',w.name,'color',w.color,'wealth',w.balance +
      coalesce((select sum(i.price) from public.inventory i where i.user_id=w.user_id and i.locked is null),0),
    'points',w.season_points,'level',floor(sqrt(coalesce(pr.xp,0)::numeric/100))::int+1,
    'title',coalesce(pr.selected_title,'Новичок')
  ) order by w.season_points desc,w.name),'[]'::jsonb)
  into friends_json
  from public.friendships f join public.wallets w on w.user_id=f.friend_id
  left join public.player_progress pr on pr.user_id=w.user_id
  where f.user_id=u and f.status='accepted';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',w.user_id,'name',w.name,'color',w.color
  ) order by f.created_at),'[]'::jsonb)
  into incoming_json
  from public.friendships f join public.wallets w on w.user_id=f.user_id
  where f.friend_id=u and f.status='pending';

  return jsonb_build_object('friends',friends_json,'incoming',incoming_json);
end $$;

create or replace function public.api_friend_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); target uuid := (p->>'user')::uuid;
begin
  if target is null or target=u or not exists(select 1 from public.wallets where user_id=target) then
    raise exception 'bad_target';
  end if;
  if exists(select 1 from public.friendships where user_id=u and friend_id=target and status='accepted') then
    return jsonb_build_object('status','accepted');
  end if;

  if exists(select 1 from public.friendships where user_id=target and friend_id=u and status='pending') then
    update public.friendships set status='accepted',accepted_at=now()
      where user_id=target and friend_id=u;
    insert into public.friendships(user_id,friend_id,status,accepted_at)
      values(u,target,'accepted',now())
      on conflict(user_id,friend_id) do update set status='accepted',accepted_at=now();
    return jsonb_build_object('status','accepted');
  end if;

  insert into public.friendships(user_id,friend_id,status)
    values(u,target,'pending')
    on conflict(user_id,friend_id) do nothing;
  return jsonb_build_object('status','pending');
end $$;

create or replace function public.api_friend_answer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); requester uuid := (p->>'user')::uuid; ok boolean := coalesce((p->>'accept')::boolean,false);
begin
  if not exists(select 1 from public.friendships where user_id=requester and friend_id=u and status='pending') then
    raise exception 'no_request';
  end if;
  if ok then
    update public.friendships set status='accepted',accepted_at=now()
      where user_id=requester and friend_id=u;
    insert into public.friendships(user_id,friend_id,status,accepted_at)
      values(u,requester,'accepted',now())
      on conflict(user_id,friend_id) do update set status='accepted',accepted_at=now();
  else
    delete from public.friendships where user_id=requester and friend_id=u and status='pending';
  end if;
  return jsonb_build_object('status',case when ok then 'accepted' else 'rejected' end);
end $$;

create or replace function public.api_friend_remove(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); target uuid := (p->>'user')::uuid;
begin
  delete from public.friendships where (user_id=u and friend_id=target) or (user_id=target and friend_id=u);
  return jsonb_build_object('ok',true);
end $$;

-- Та же серверная рулетка, что и в основной установке, плюс запись результата в журнал.
create or replace function public.api_roulette(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w public.wallets := public.w_get();
  u uuid := w.user_id;
  bet bigint := (p->>'bet')::bigint;
  segs numeric[] := array[0,2,0,1.5,0,3,0.5,0,2,0,10,0];
  idx int;
  m numeric;
  win bigint;
begin
  if bet is null or bet < 1 or bet > w.balance then raise exception 'no_money'; end if;
  perform public.quest_bump(u,'roulette',1);
  if random()<1.0/120 then
    insert into public.game_history(user_id,kind,details)
      values(u,'roulette_return',jsonb_build_object('bet',bet));
    return jsonb_build_object('rolled',true,'bal',w.balance);
  end if;

  idx := floor(random()*12)::int;
  m := segs[idx+1];
  win := round(bet*m);
  update public.wallets set balance=balance-bet+win where user_id=u;
  perform public.add_points(u,win-bet);
  insert into public.game_history(user_id,kind,details)
    values(u,'roulette',jsonb_build_object('bet',bet,'multiplier',m,'win',win,'segment',idx));
  return jsonb_build_object('idx',idx,'mult',m,'win',win,'bal',w.balance-bet+win);
end $$;

-- Функции API доступны только вошедшим игрокам.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      'api_extra_hub','api_extra_claim','api_extra_profile','api_extra_showcase',
      'api_extra_set_profile','api_extra_history','api_friends',
      'api_friend_request','api_friend_answer','api_friend_remove','api_roulette'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated',f.sig);
    execute format('grant execute on function %s to authenticated',f.sig);
  end loop;
end $$;

commit;
