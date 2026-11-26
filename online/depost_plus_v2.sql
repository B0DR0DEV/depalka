-- Depost+ V2: social hub, profiles, albums, messaging, activity and fixed weekly goals.
-- Run AFTER online/depost_plus.sql. Adds only Depost+ tables/functions.
alter table public.depost_plus_profiles
  add column if not exists bio text not null default '',
  add column if not exists theme text not null default 'violet',
  add column if not exists frame text not null default 'none',
  add column if not exists privacy text not null default 'public',
  add column if not exists showcase text[] not null default '{}';
alter table public.depost_plus_profiles
  drop constraint if exists depost_plus_profiles_bio_len,
  add constraint depost_plus_profiles_bio_len check (char_length(bio) <= 160),
  drop constraint if exists depost_plus_profiles_privacy_check,
  add constraint depost_plus_profiles_privacy_check check (privacy in ('public','friends','private')),
  drop constraint if exists depost_plus_profiles_theme_check,
  add constraint depost_plus_profiles_theme_check check (theme in ('violet','midnight','aurora','sunset')),
  drop constraint if exists depost_plus_profiles_frame_check,
  add constraint depost_plus_profiles_frame_check check (frame in ('none','glow','orbit','pixel')),
  drop constraint if exists depost_plus_profiles_showcase_check,
  add constraint depost_plus_profiles_showcase_check check (cardinality(showcase) <= 6);

create table if not exists public.depost_plus_blocks (
  blocker uuid not null references auth.users(id) on delete cascade,
  blocked uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
create table if not exists public.depost_plus_messages (
  id bigint generated always as identity primary key,
  sender uuid not null references auth.users(id) on delete cascade,
  recipient uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender <> recipient)
);
create index if not exists depost_plus_messages_pair on public.depost_plus_messages(sender,recipient,created_at desc);
create index if not exists depost_plus_messages_recipient on public.depost_plus_messages(recipient,created_at desc);
create table if not exists public.depost_plus_albums (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 48),
  description text not null default '' check (char_length(description) <= 180),
  item_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(item_ids) <= 20)
);
create index if not exists depost_plus_albums_user on public.depost_plus_albums(user_id,updated_at desc);
create table if not exists public.depost_plus_reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references auth.users(id) on delete cascade,
  reported uuid not null references auth.users(id) on delete cascade,
  reason text not null check (reason in ('spam','harassment','inappropriate','other')),
  details text not null default '' check (char_length(details) <= 300),
  created_at timestamptz not null default now(),
  status text not null default 'new' check (status in ('new','reviewed','closed')),
  check (reporter <> reported)
);
create index if not exists depost_plus_reports_status on public.depost_plus_reports(status,created_at desc);

alter table public.depost_plus_blocks enable row level security;
alter table public.depost_plus_messages enable row level security;
alter table public.depost_plus_albums enable row level security;
alter table public.depost_plus_reports enable row level security;
revoke all on public.depost_plus_blocks from anon,authenticated;
revoke all on public.depost_plus_messages from anon,authenticated;
revoke all on public.depost_plus_albums from anon,authenticated;
revoke all on public.depost_plus_reports from anon,authenticated;

-- Profile settings are constrained to known values; showcase can only contain catalog favorites.
create or replace function public.api_plus_profile_update(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  u uuid := public.me();
  v_bio text := left(trim(coalesce(p->>'bio','')),160);
  v_theme text := coalesce(p->>'theme','violet');
  v_frame text := coalesce(p->>'frame','none');
  v_privacy text := coalesce(p->>'privacy','public');
  v_showcase text[] := '{}';
  v_title text := coalesce(p->>'title','');
begin
  if v_theme not in ('violet','midnight','aurora','sunset') then raise exception 'bad_theme'; end if;
  if v_frame not in ('none','glow','orbit','pixel') then raise exception 'bad_frame'; end if;
  if v_privacy not in ('public','friends','private') then raise exception 'bad_privacy'; end if;
  if jsonb_typeof(coalesce(p->'showcase','[]'::jsonb)) <> 'array' then raise exception 'bad_showcase'; end if;
  select coalesce(array_agg(distinct value),'{}') into v_showcase
    from jsonb_array_elements_text(coalesce(p->'showcase','[]'::jsonb)) as x(value);
  if cardinality(v_showcase)>6 then raise exception 'showcase_limit'; end if;
  insert into public.depost_plus_profiles(user_id) values(u) on conflict(user_id) do nothing;
  if v_title <> '' and v_title not in ('Коллекционер','Исследователь','Хранитель каталога','Создатель витрины') then raise exception 'bad_plus_title'; end if;
  if exists (
    select 1 from unnest(v_showcase) sid
    where not exists (
      select 1 from public.depost_plus_profiles pr, unnest(pr.favorites) fav
      where pr.user_id=u and fav=sid
    )
  ) then raise exception 'showcase_must_be_favorite'; end if;
  update public.depost_plus_profiles set
    bio=v_bio, theme=v_theme, frame=v_frame, privacy=v_privacy, showcase=v_showcase,
    title=case when v_title='' then title else v_title end, updated_at=now()
  where user_id=u;
  insert into public.depost_plus_events(user_id,kind,detail)
    values(u,'profile_updated','Обновил витрину профиля');
  return public.api_plus_state('{}'::jsonb);
end $$;

create or replace function public.api_plus_feed(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',q.id,'user_id',q.user_id,'name',q.name,'kind',q.kind,'detail',q.detail,'at',q.created_at
    ) order by q.created_at desc)
    from (
      select e.id,e.user_id,w.name,e.kind,e.detail,e.created_at
      from public.depost_plus_events e
      join public.wallets w on w.user_id=e.user_id
      where e.user_id<>u
        and exists (
          select 1 from public.depost_plus_friendships f
          where f.status='accepted'
            and ((f.requester=u and f.recipient=e.user_id) or (f.recipient=u and f.requester=e.user_id))
        )
        and not exists (select 1 from public.depost_plus_blocks b where
          (b.blocker=u and b.blocked=e.user_id) or (b.blocker=e.user_id and b.blocked=u))
      order by e.created_at desc limit 50
    ) q
  ),'[]'::jsonb);
end $$;

create or replace function public.api_plus_public_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  u uuid := public.me();
  target uuid;
  pr public.depost_plus_profiles;
  is_friend boolean := false;
  w public.wallets;
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  select * into w from public.wallets where user_id=target;
  if w.user_id is null then raise exception 'no_player'; end if;
  if exists(select 1 from public.depost_plus_blocks b where
    (b.blocker=u and b.blocked=target) or (b.blocker=target and b.blocked=u)) then raise exception 'profile_unavailable'; end if;
  select * into pr from public.depost_plus_profiles where user_id=target;
  if pr.user_id is null then
    insert into public.depost_plus_profiles(user_id) values(target) on conflict(user_id) do nothing;
    select * into pr from public.depost_plus_profiles where user_id=target;
  end if;
  select exists(select 1 from public.depost_plus_friendships f where f.status='accepted'
    and ((f.requester=u and f.recipient=target) or (f.recipient=u and f.requester=target))) into is_friend;
  if target<>u and (pr.privacy='private' or (pr.privacy='friends' and not is_friend)) then raise exception 'profile_private'; end if;
  return jsonb_build_object(
    'user_id',target,'name',w.name,'color',w.color,'title',pr.title,'bio',pr.bio,
    'theme',pr.theme,'frame',pr.frame,'privacy',pr.privacy,'showcase',to_jsonb(pr.showcase),
    'favorites',to_jsonb(pr.favorites),'is_friend',is_friend,
    'albums',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'description',a.description,'item_ids',to_jsonb(a.item_ids),'updated_at',a.updated_at) order by a.updated_at desc)
      from public.depost_plus_albums a where a.user_id=target),'[]'::jsonb),
    'joined_at',w.created_at
  );
end $$;

create or replace function public.api_plus_album_list(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'description',a.description,'item_ids',to_jsonb(a.item_ids),'updated_at',a.updated_at) order by a.updated_at desc)
    from public.depost_plus_albums a where a.user_id=u),'[]'::jsonb);
end $$;

create or replace function public.api_plus_album_save(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  u uuid := public.me();
  aid bigint;
  v_title text := left(trim(coalesce(p->>'title','')),48);
  v_description text := left(trim(coalesce(p->>'description','')),180);
  v_items text[] := '{}';
begin
  if v_title='' then raise exception 'album_title_required'; end if;
  if jsonb_typeof(coalesce(p->'item_ids','[]'::jsonb))<>'array' then raise exception 'bad_album_items'; end if;
  select coalesce(array_agg(distinct value),'{}') into v_items
    from jsonb_array_elements_text(coalesce(p->'item_ids','[]'::jsonb)) x(value);
  if cardinality(v_items)>20 then raise exception 'album_items_limit'; end if;
  if exists(select 1 from unnest(v_items) sid where not exists(select 1 from public.catalog_items c where c.id=sid)) then
    raise exception 'album_item_not_found';
  end if;
  begin aid := nullif(p->>'id','')::bigint; exception when others then aid := null; end;
  if aid is null then
    if (select count(*) from public.depost_plus_albums where user_id=u)>=10 then raise exception 'album_limit'; end if;
    insert into public.depost_plus_albums(user_id,title,description,item_ids)
      values(u,v_title,v_description,v_items) returning id into aid;
    insert into public.depost_plus_events(user_id,kind,detail) values(u,'album_created',v_title);
  else
    update public.depost_plus_albums set title=v_title,description=v_description,item_ids=v_items,updated_at=now()
      where id=aid and user_id=u;
    if not found then raise exception 'album_not_found'; end if;
  end if;
  return public.api_plus_album_list('{}'::jsonb);
end $$;

create or replace function public.api_plus_album_delete(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); aid bigint;
begin
  begin aid := (p->>'id')::bigint; exception when others then raise exception 'bad_album'; end;
  delete from public.depost_plus_albums where id=aid and user_id=u;
  if not found then raise exception 'album_not_found'; end if;
  return public.api_plus_album_list('{}'::jsonb);
end $$;

create or replace function public.api_plus_message_send(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); target uuid; body_text text := left(trim(coalesce(p->>'body','')),500);
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  if target=u or body_text='' then raise exception 'bad_message'; end if;
  if not exists(select 1 from public.depost_plus_friendships f where f.status='accepted'
    and ((f.requester=u and f.recipient=target) or (f.recipient=u and f.requester=target))) then raise exception 'messages_friends_only'; end if;
  if exists(select 1 from public.depost_plus_blocks b where
    (b.blocker=u and b.blocked=target) or (b.blocker=target and b.blocked=u)) then raise exception 'user_blocked'; end if;
  if (select count(*) from public.depost_plus_messages m where m.sender=u and m.created_at>now()-interval '1 minute')>=10 then raise exception 'message_rate_limit'; end if;
  insert into public.depost_plus_messages(sender,recipient,body) values(u,target,body_text);
  return jsonb_build_object('sent',true);
end $$;

create or replace function public.api_plus_message_list(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); target uuid;
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  if not exists(select 1 from public.depost_plus_friendships f where f.status='accepted'
    and ((f.requester=u and f.recipient=target) or (f.recipient=u and f.requester=target))) then raise exception 'messages_friends_only'; end if;
  if exists(select 1 from public.depost_plus_blocks b where
    (b.blocker=u and b.blocked=target) or (b.blocker=target and b.blocked=u)) then raise exception 'user_blocked'; end if;
  update public.depost_plus_messages set read_at=now() where recipient=u and sender=target and read_at is null;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id',m.id,'sender',m.sender,'recipient',m.recipient,'body',m.body,'at',m.created_at,'read_at',m.read_at) order by m.created_at)
    from (select * from public.depost_plus_messages m where
      (m.sender=u and m.recipient=target) or (m.sender=target and m.recipient=u)
      order by m.created_at desc limit 50) m
  ),'[]'::jsonb);
end $$;

create or replace function public.api_plus_block(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); target uuid; do_block boolean := coalesce((p->>'block')::boolean,true);
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  if target=u then raise exception 'bad_target'; end if;
  if do_block then
    insert into public.depost_plus_blocks(blocker,blocked) values(u,target) on conflict do nothing;
    delete from public.depost_plus_friendships where
      (requester=u and recipient=target) or (requester=target and recipient=u);
  else
    delete from public.depost_plus_blocks where blocker=u and blocked=target;
  end if;
  return jsonb_build_object('blocked',do_block);
end $$;

create or replace function public.api_plus_report(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); target uuid; why text := coalesce(p->>'reason','other'); details_text text := left(trim(coalesce(p->>'details','')),300);
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  if target=u or why not in ('spam','harassment','inappropriate','other') then raise exception 'bad_report'; end if;
  if (select count(*) from public.depost_plus_reports r where r.reporter=u and r.created_at>now()-interval '24 hours')>=5 then raise exception 'report_rate_limit'; end if;
  insert into public.depost_plus_reports(reporter,reported,reason,details) values(u,target,why,details_text);
  return jsonb_build_object('reported',true);
end $$;

create or replace function public.api_plus_stats(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); w public.wallets;
begin
  select * into w from public.wallets where user_id=u;
  return jsonb_build_object(
    'joined_at',w.created_at,
    'favorites',(select cardinality(favorites) from public.depost_plus_profiles where user_id=u),
    'friends',(select count(*) from public.depost_plus_friendships f where f.status='accepted' and (f.requester=u or f.recipient=u)),
    'albums',(select count(*) from public.depost_plus_albums where user_id=u),
    'messages_sent',(select count(*) from public.depost_plus_messages where sender=u),
    'profile_events',(select count(*) from public.depost_plus_events where user_id=u)
  );
end $$;

create or replace function public.api_plus_weekly(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid := public.me(); fav int; friends int; albums int; customized boolean;
begin
  insert into public.depost_plus_profiles(user_id) values(u) on conflict(user_id) do nothing;
  select cardinality(favorites), (bio<>'' or theme<>'violet' or frame<>'none' or title<>'Коллекционер')
    into fav,customized from public.depost_plus_profiles where user_id=u;
  select count(*) into friends from public.depost_plus_friendships where status='accepted' and (requester=u or recipient=u);
  select count(*) into albums from public.depost_plus_albums where user_id=u;
  return jsonb_build_object(
    'week_start',date_trunc('week',now()),
    'goals',jsonb_build_object(
      'favorites_3',fav>=3,'custom_profile',customized,'album_created',albums>=1,'friend_added',friends>=1
    ),
    'completed',(case when fav>=3 then 1 else 0 end)+(case when customized then 1 else 0 end)+(case when albums>=1 then 1 else 0 end)+(case when friends>=1 then 1 else 0 end),
    'total',4,'reward','Значок недели создателя'
  );
end $$;

-- Extend the state payload with profile customization fields for the client.
create or replace function public.api_plus_state(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $
declare u uuid := public.me(); pr public.depost_plus_profiles; fav_count int;
begin
  insert into public.depost_plus_profiles(user_id) values (u) on conflict (user_id) do nothing;
  select * into pr from public.depost_plus_profiles where user_id = u;
  fav_count := cardinality(pr.favorites);
  return jsonb_build_object(
    'title',pr.title,'favorites',to_jsonb(pr.favorites),'favorite_count',fav_count,
    'bio',pr.bio,'theme',pr.theme,'frame',pr.frame,'privacy',pr.privacy,'showcase',to_jsonb(pr.showcase),
    'achievements',jsonb_build_object('profile_started',true,'favorites_3',fav_count>=3,'favorites_10',fav_count>=10,'has_title',pr.title<>'Коллекционер'),
    'weekly',jsonb_build_object('favorites_2',least(fav_count,2),'title_selected',pr.title<>'Коллекционер'),
    'history',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'detail',e.detail,'at',e.created_at) order by e.created_at desc)
      from (select id,kind,detail,created_at from public.depost_plus_events where user_id=u order by created_at desc limit 30)e),'[]'::jsonb),
    'friends',coalesce((select jsonb_agg(jsonb_build_object('user_id',w.user_id,'name',w.name,'color',w.color) order by w.name)
      from public.depost_plus_friendships f join public.wallets w on w.user_id=case when f.requester=u then f.recipient else f.requester end
      where f.status='accepted' and (f.requester=u or f.recipient=u)
      and not exists(select 1 from public.depost_plus_blocks b where
        (b.blocker=u and b.blocked=w.user_id) or (b.blocker=w.user_id and b.blocked=u))
    ),'[]'::jsonb),
    'incoming',coalesce((select jsonb_agg(jsonb_build_object('request_id',f.id,'user_id',f.requester,'name',w.name,'color',w.color) order by f.created_at desc)
      from public.depost_plus_friendships f join public.wallets w on w.user_id=f.requester where f.recipient=u and f.status='pending'),'[]'::jsonb),
    'outgoing',coalesce((select jsonb_agg(jsonb_build_object('request_id',f.id,'user_id',f.recipient,'name',w.name,'color',w.color) order by f.created_at desc)
      from public.depost_plus_friendships f join public.wallets w on w.user_id=f.recipient where f.requester=u and f.status='pending'),'[]'::jsonb)
  );
end $;

-- Compatibility RPC names used by the existing client (the original migration defines api_plus_*).
create or replace function public.plus_state(p jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_state(p) $$;
create or replace function public.plus_favorite(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_favorite(p) $$;
create or replace function public.plus_title(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_title(p) $$;
create or replace function public.plus_search(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_search(p) $$;
create or replace function public.plus_friend_request(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_friend_request(p) $$;
create or replace function public.plus_friend_respond(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_friend_respond(p) $$;
create or replace function public.plus_friend_remove(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_friend_remove(p) $$;
create or replace function public.plus_profile_update(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_profile_update(p) $$;
create or replace function public.plus_feed(p jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_feed(p) $$;
create or replace function public.plus_public_profile(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_public_profile(p) $$;
create or replace function public.plus_album_list(p jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_album_list(p) $$;
create or replace function public.plus_album_save(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_album_save(p) $$;
create or replace function public.plus_album_delete(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_album_delete(p) $$;
create or replace function public.plus_message_send(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_message_send(p) $$;
create or replace function public.plus_message_list(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_message_list(p) $$;
create or replace function public.plus_block(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_block(p) $$;
create or replace function public.plus_report(p jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_report(p) $$;
create or replace function public.plus_stats(p jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_stats(p) $$;
create or replace function public.plus_weekly(p jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path=public as $$ select public.api_plus_weekly(p) $$;

revoke all on function public.api_plus_profile_update(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_feed(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_public_profile(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_album_list(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_album_save(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_album_delete(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_message_send(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_message_list(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_block(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_report(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_stats(jsonb) from public,anon,authenticated;
revoke all on function public.api_plus_weekly(jsonb) from public,anon,authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'plus_state','plus_favorite','plus_title','plus_search','plus_friend_request','plus_friend_respond','plus_friend_remove',
    'plus_profile_update','plus_feed','plus_public_profile','plus_album_list','plus_album_save','plus_album_delete',
    'plus_message_send','plus_message_list','plus_block','plus_report','plus_stats','plus_weekly'
  ] loop
    execute format('revoke all on function public.%I(jsonb) from public,anon,authenticated',f);
    execute format('grant execute on function public.%I(jsonb) to authenticated',f);
  end loop;
end $$;
