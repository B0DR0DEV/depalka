-- Depost+ server sync migration
-- Run once in Supabase SQL Editor AFTER online/install.sql.
-- Only adds Depost+ tables and API functions; does not alter existing game data.

create table if not exists public.depost_plus_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  title text not null default 'Коллекционер'
    check (title in ('Коллекционер','Исследователь','Хранитель каталога','Создатель витрины')),
  favorites text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(favorites) <= 50)
);
create table if not exists public.depost_plus_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('favorite_added','favorite_removed','title_changed','friend_added','friend_removed')),
  detail text not null,
  created_at timestamptz not null default now()
);
create index if not exists depost_plus_events_user_created on public.depost_plus_events(user_id, created_at desc);
create table if not exists public.depost_plus_friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references auth.users(id) on delete cascade,
  recipient uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester <> recipient),
  unique(requester, recipient)
);
create index if not exists depost_plus_friendships_recipient_status on public.depost_plus_friendships(recipient, status);
create index if not exists depost_plus_friendships_requester_status on public.depost_plus_friendships(requester, status);

alter table public.depost_plus_profiles enable row level security;
alter table public.depost_plus_events enable row level security;
alter table public.depost_plus_friendships enable row level security;
revoke all on public.depost_plus_profiles from anon, authenticated;
revoke all on public.depost_plus_events from anon, authenticated;
revoke all on public.depost_plus_friendships from anon, authenticated;

create or replace function public.api_plus_state(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); pr public.depost_plus_profiles; fav_count int;
begin
  insert into public.depost_plus_profiles(user_id) values (u) on conflict (user_id) do nothing;
  select * into pr from public.depost_plus_profiles where user_id = u;
  fav_count := cardinality(pr.favorites);
  return jsonb_build_object(
    'title', pr.title, 'favorites', to_jsonb(pr.favorites), 'favorite_count', fav_count,
    'achievements', jsonb_build_object(
      'profile_started', true, 'favorites_3', fav_count >= 3,
      'favorites_10', fav_count >= 10, 'has_title', pr.title <> 'Коллекционер'),
    'weekly', jsonb_build_object('favorites_2', least(fav_count, 2), 'title_selected', pr.title <> 'Коллекционер'),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'detail', e.detail, 'at', e.created_at) order by e.created_at desc)
      from (select id, kind, detail, created_at from public.depost_plus_events
            where user_id = u order by created_at desc limit 30) e
    ), '[]'::jsonb),
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', w.user_id, 'name', w.name, 'color', w.color) order by w.name)
      from public.depost_plus_friendships f
      join public.wallets w on w.user_id = case when f.requester = u then f.recipient else f.requester end
      where f.status = 'accepted' and (f.requester = u or f.recipient = u)
    ), '[]'::jsonb),
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object('request_id', f.id, 'user_id', f.requester, 'name', w.name, 'color', w.color) order by f.created_at desc)
      from public.depost_plus_friendships f join public.wallets w on w.user_id = f.requester
      where f.recipient = u and f.status = 'pending'
    ), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object('request_id', f.id, 'user_id', f.recipient, 'name', w.name, 'color', w.color) order by f.created_at desc)
      from public.depost_plus_friendships f join public.wallets w on w.user_id = f.recipient
      where f.requester = u and f.status = 'pending'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.api_plus_favorite(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := public.me(); item_key text := left(coalesce(p->>'item_id',''), 160);
  action_name text := coalesce(p->>'action',''); pr public.depost_plus_profiles; item_name text;
begin
  if item_key = '' or action_name not in ('add','remove') then raise exception 'bad_plus_favorite'; end if;
  select name into item_name from public.catalog_items where id = item_key;
  if item_name is null then raise exception 'plus_item_not_found'; end if;
  insert into public.depost_plus_profiles(user_id) values (u) on conflict (user_id) do nothing;
  select * into pr from public.depost_plus_profiles where user_id = u for update;
  if action_name = 'add' then
    if not (item_key = any(pr.favorites)) then
      if cardinality(pr.favorites) >= 50 then raise exception 'plus_favorites_limit'; end if;
      update public.depost_plus_profiles set favorites = array_append(favorites, item_key), updated_at = now() where user_id = u;
      insert into public.depost_plus_events(user_id, kind, detail) values (u, 'favorite_added', item_name);
    end if;
  else
    if item_key = any(pr.favorites) then
      update public.depost_plus_profiles set favorites = array_remove(favorites, item_key), updated_at = now() where user_id = u;
      insert into public.depost_plus_events(user_id, kind, detail) values (u, 'favorite_removed', item_name);
    end if;
  end if;
  return public.api_plus_state('{}'::jsonb);
end;
$$;

create or replace function public.api_plus_title(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); new_title text := coalesce(p->>'title','');
begin
  if new_title not in ('Коллекционер','Исследователь','Хранитель каталога','Создатель витрины') then raise exception 'bad_plus_title'; end if;
  insert into public.depost_plus_profiles(user_id) values (u) on conflict (user_id) do nothing;
  if (select title from public.depost_plus_profiles where user_id = u) is distinct from new_title then
    update public.depost_plus_profiles set title = new_title, updated_at = now() where user_id = u;
    insert into public.depost_plus_events(user_id, kind, detail) values (u, 'title_changed', new_title);
  end if;
  return public.api_plus_state('{}'::jsonb);
end;
$$;

create or replace function public.api_plus_search(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); q text := left(trim(coalesce(p->>'query','')), 40);
begin
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', x.name, 'color', x.color))
    from (select w.user_id, w.name, w.color from public.wallets w
          where w.user_id <> u and w.name ilike '%' || replace(replace(q, E'\\', E'\\\\'), '%', E'\\%') || '%'
          order by w.name limit 20) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.api_plus_friend_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); target uuid;
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  if target = u then raise exception 'bad_target'; end if;
  if not exists (select 1 from public.wallets where user_id = target) then raise exception 'no_player'; end if;
  if exists (select 1 from public.depost_plus_friendships where status = 'accepted'
    and ((requester = u and recipient = target) or (requester = target and recipient = u))) then raise exception 'already_friends'; end if;
  if exists (select 1 from public.depost_plus_friendships where status = 'pending'
    and ((requester = u and recipient = target) or (requester = target and recipient = u))) then raise exception 'friend_request_exists'; end if;
  if (select count(*) from public.depost_plus_friendships where requester = u and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'friend_request_limit';
  end if;
  insert into public.depost_plus_friendships(requester, recipient) values (u, target);
  return public.api_plus_state('{}'::jsonb);
end;
$$;

create or replace function public.api_plus_friend_respond(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); rid bigint; accept_it boolean := coalesce((p->>'accept')::boolean, false); other_user uuid;
begin
  begin rid := (p->>'request_id')::bigint; exception when others then raise exception 'bad_friend_request'; end;
  select requester into other_user from public.depost_plus_friendships
  where id = rid and recipient = u and status = 'pending' for update;
  if other_user is null then raise exception 'friend_request_not_found'; end if;
  update public.depost_plus_friendships set status = case when accept_it then 'accepted' else 'declined' end,
    updated_at = now() where id = rid;
  if accept_it then
    insert into public.depost_plus_events(user_id, kind, detail)
      values (u, 'friend_added', (select name from public.wallets where user_id = other_user));
    insert into public.depost_plus_events(user_id, kind, detail)
      values (other_user, 'friend_added', (select name from public.wallets where user_id = u));
  end if;
  return public.api_plus_state('{}'::jsonb);
end;
$$;

create or replace function public.api_plus_friend_remove(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.me(); target uuid; target_name text;
begin
  begin target := (p->>'user_id')::uuid; exception when others then raise exception 'bad_target'; end;
  select name into target_name from public.wallets where user_id = target;
  delete from public.depost_plus_friendships where status = 'accepted'
    and ((requester = u and recipient = target) or (requester = target and recipient = u));
  if found then insert into public.depost_plus_events(user_id, kind, detail)
    values (u, 'friend_removed', coalesce(target_name, 'Игрок')); end if;
  return public.api_plus_state('{}'::jsonb);
end;
$$;

revoke all on function public.api_plus_state(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_favorite(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_title(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_search(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_friend_request(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_friend_respond(jsonb) from public, anon, authenticated;
revoke all on function public.api_plus_friend_remove(jsonb) from public, anon, authenticated;
grant execute on function public.api_plus_state(jsonb) to authenticated;
grant execute on function public.api_plus_favorite(jsonb) to authenticated;
grant execute on function public.api_plus_title(jsonb) to authenticated;
grant execute on function public.api_plus_search(jsonb) to authenticated;
grant execute on function public.api_plus_friend_request(jsonb) to authenticated;
grant execute on function public.api_plus_friend_respond(jsonb) to authenticated;
grant execute on function public.api_plus_friend_remove(jsonb) to authenticated;
