-- Депость: права доступа для игроков.
-- Нужны, если в проекте Supabase новые таблицы не открываются для сайта автоматически
-- (ошибка «permission denied for table …»). Запускать можно сколько угодно раз.
grant usage on schema public to anon, authenticated;
grant select on public.players, public.feed, public.rooms, public.room_players to anon, authenticated;
grant insert, update on public.players to authenticated;
grant insert on public.feed to authenticated;
grant insert on public.rooms to authenticated;
grant insert, update, delete on public.room_players to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.spin_room(text) to authenticated;
