-- Depost username + password identities.
-- Run once in Supabase SQL Editor. Passwords are never stored in this table.
create table if not exists public.depost_auth_usernames (
  username text primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint depost_auth_username_format check (username ~ '^[a-z0-9_]{3,20}$')
);
alter table public.depost_auth_usernames enable row level security;
revoke all on public.depost_auth_usernames from anon, authenticated, public;
