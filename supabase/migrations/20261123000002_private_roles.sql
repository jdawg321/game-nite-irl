-- Roles become private.
-- Before: role lived on game_players, which every member of a game can read,
-- so a seeker could look up who the hider is. Now roles live in game_roles:
--   * you can always read your own role;
--   * the organizer can read everyone's role, EXCEPT while they are also a
--     player in that game and it has started (fair play for organizer-players).

create table public.game_roles (
  game_id uuid not null,
  user_id uuid not null,
  role public.player_role not null default 'pending',
  primary key (game_id, user_id),
  foreign key (game_id, user_id) references public.game_players(game_id, user_id) on delete cascade
);

insert into public.game_roles(game_id, user_id, role)
select game_id, user_id, role from public.game_players;

alter table public.game_roles enable row level security;
revoke insert, update, delete on public.game_roles from authenticated, anon;

create policy "read own role" on public.game_roles
  for select to authenticated using (user_id = (select auth.uid()));

create policy "organizer reads roles unless playing a started game" on public.game_roles
  for select to authenticated using (
    exists (
      select 1 from public.games g
       where g.id = game_id
         and g.organizer_id = (select auth.uid())
         and (g.status in ('DRAFT','LOBBY') or not public.is_game_member(g.id))
    )
  );

-- ---------- functions that touched game_players.role ----------
create or replace function public.join_game(code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p public.profiles;
  g public.games;
  n int;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into p from public.profiles where id = uid;
  if not p.is_adult or p.rules_ack_at is null or p.display_name is null then
    raise exception 'Finish your profile before joining' using errcode = 'P0001';
  end if;
  select * into g from public.games where join_code = upper(trim(code)) for update;
  if g.id is null then raise exception 'No game uses that code' using errcode = 'P0002'; end if;
  if g.status not in ('DRAFT','LOBBY') then
    raise exception 'This game has already started' using errcode = 'P0001';
  end if;
  if exists(select 1 from public.game_players where game_id = g.id and user_id = uid and status = 'removed') then
    raise exception 'The organizer removed you from this game' using errcode = 'P0001';
  end if;
  select count(*) into n from public.game_players where game_id = g.id and status = 'joined' and user_id <> uid;
  if n >= (g.config->>'capacity')::int then
    raise exception 'This game is full' using errcode = 'P0001';
  end if;
  insert into public.game_players(game_id, user_id) values (g.id, uid)
    on conflict (game_id, user_id) do update set status = 'joined', ready = false, joined_at = now();
  insert into public.game_roles(game_id, user_id) values (g.id, uid)
    on conflict (game_id, user_id) do update set role = 'pending';
  return g.id;
end $$;

create or replace function public.set_player_role(gid uuid, uid uuid, p_role public.player_role) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status not in ('DRAFT','LOBBY') then raise exception 'Roles are locked' using errcode = 'P0001'; end if;
  update public.game_roles set role = p_role where game_id = gid and user_id = uid;
  perform public.log_action(gid, 'set_role', jsonb_build_object('user', uid, 'role', p_role));
end $$;

create or replace function public.start_game(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  g public.games;
  n int;
  want int;
  method text;
begin
  g := public.require_organizer(gid);
  if g.status <> 'LOBBY' then raise exception 'Open the lobby first' using errcode = 'P0001'; end if;
  select count(*) into n from public.game_players where game_id = gid and status = 'joined';
  if n < (g.config->>'minPlayers')::int then
    raise exception 'Need at least % players (have %)', g.config->>'minPlayers', n using errcode = 'P0001';
  end if;
  want := least((g.config->>'hiders')::int, n - 1);
  method := g.config->>'method';

  -- Everyone who left or was removed goes back to pending.
  update public.game_roles r set role = 'pending'
    from public.game_players p
   where p.game_id = gid and p.status <> 'joined' and r.game_id = p.game_id and r.user_id = p.user_id;

  -- Start joined players as seekers (manual mode keeps the organizer's hider picks).
  update public.game_roles r set role = 'seeker'
    from public.game_players p
   where p.game_id = gid and p.status = 'joined' and r.game_id = p.game_id and r.user_id = p.user_id
     and (method <> 'manual' or r.role <> 'hider');

  if method = 'volunteer' then
    update public.game_roles set role = 'hider' where (game_id, user_id) in (
      select p.game_id, p.user_id from public.game_players p
       where p.game_id = gid and p.status = 'joined' and p.volunteer
       order by random() limit want);
  end if;

  -- Random, plus any shortfall from manual / volunteer, filled at random.
  update public.game_roles set role = 'hider' where (game_id, user_id) in (
    select r.game_id, r.user_id
      from public.game_roles r join public.game_players p using (game_id, user_id)
     where r.game_id = gid and p.status = 'joined' and r.role = 'seeker'
     order by random()
     limit greatest(0, want - (select count(*)
                                 from public.game_roles r2 join public.game_players p2 using (game_id, user_id)
                                where r2.game_id = gid and p2.status = 'joined' and r2.role = 'hider')));

  update public.games set status = 'PREPARING', started_at = now(), config_locked_at = now() where id = gid;
  perform public.log_action(gid, 'start_game', jsonb_build_object('players', n, 'config_version', g.config_version));
end $$;

alter table public.game_players drop column role;

alter publication supabase_realtime add table public.game_roles;
