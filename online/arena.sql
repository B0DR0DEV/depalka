-- Depost Arena: additive migration. Does not alter wallets, inventory, catalog_items or existing game tables.
create table if not exists public.arena_loadouts (
  user_id uuid not null references auth.users(id) on delete cascade,
  slot text not null check (slot in ('primary')),
  inventory_item_id bigint references public.inventory(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key(user_id, slot)
);
create index if not exists arena_loadouts_inventory_item on public.arena_loadouts(inventory_item_id);
alter table public.arena_loadouts enable row level security;
drop policy if exists arena_loadouts_select_own on public.arena_loadouts;
create policy arena_loadouts_select_own on public.arena_loadouts for select to authenticated using (auth.uid() = user_id);
drop policy if exists arena_loadouts_insert_own on public.arena_loadouts;
create policy arena_loadouts_insert_own on public.arena_loadouts for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists arena_loadouts_update_own on public.arena_loadouts;
create policy arena_loadouts_update_own on public.arena_loadouts for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists arena_loadouts_delete_own on public.arena_loadouts;
create policy arena_loadouts_delete_own on public.arena_loadouts for delete to authenticated using (auth.uid() = user_id);
create or replace function public.arena_validate_loadout() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.inventory_item_id is not null and not exists(
    select 1 from public.inventory i
    where i.id=new.inventory_item_id and i.user_id=new.user_id and i.locked is null
  ) then raise exception 'arena_item_not_owned'; end if;
  new.updated_at=now();
  return new;
end $$;
drop trigger if exists arena_validate_loadout_trigger on public.arena_loadouts;
create trigger arena_validate_loadout_trigger before insert or update on public.arena_loadouts
for each row execute function public.arena_validate_loadout();

create table if not exists public.arena_match_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  match_id text not null,
  mode text not null check (mode in ('teams','ffa')),
  score integer not null default 0 check (score >= 0),
  team text not null default 'solo',
  won boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists arena_match_results_user_created on public.arena_match_results(user_id,created_at desc);
alter table public.arena_match_results enable row level security;
drop policy if exists arena_results_select_own on public.arena_match_results;
create policy arena_results_select_own on public.arena_match_results for select to authenticated using(auth.uid()=user_id);
drop policy if exists arena_results_insert_own on public.arena_match_results;
create policy arena_results_insert_own on public.arena_match_results for insert to authenticated with check(auth.uid()=user_id);

-- Explicit SQL privileges for authenticated users; RLS policies above still restrict rows to the owner.
grant select, insert, update, delete on public.arena_loadouts to authenticated;
grant select, insert on public.arena_match_results to authenticated;
