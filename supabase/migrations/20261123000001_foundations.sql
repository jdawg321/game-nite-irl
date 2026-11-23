-- Game Nite — Stage 1 foundations
-- Profiles, games (one Sardines game per event in V1), players, audit log.
-- Clients never write game tables directly: every change goes through the
-- security-definer functions below, so the server is the source of truth.

-- ---------- types ----------
create type public.game_status as enum ('DRAFT','LOBBY','PREPARING','ACTIVE','PAUSED','FINISHED','TERMINATED');
create type public.player_role as enum ('pending','seeker','hider');
create type public.player_status as enum ('joined','left','removed');

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) between 2 and 24),
  is_adult boolean not null default false,
  rules_ack_at timestamptz,
  replay_consent boolean not null default false,
  is_organizer boolean not null default false,
  created_at timestamptz not null default now()
);

-- A profile row is created for every new auth user.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- games ----------
create table public.games (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 60),
  kind text not null default 'scheduled' check (kind in ('scheduled','instant')),
  starts_at timestamptz,
  location_name text not null default '',
  join_code text not null unique,
  status public.game_status not null default 'DRAFT',
  config jsonb not null,
  config_version int not null default 1,
  config_locked_at timestamptz,
  organizer_id uuid not null references public.profiles(id),
  lobby_opened_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz not null default now()
);
create index games_status_idx on public.games(status);
create index games_organizer_idx on public.games(organizer_id);

-- ---------- players ----------
create table public.game_players (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.player_role not null default 'pending',
  status public.player_status not null default 'joined',
  ready boolean not null default false,
  volunteer boolean not null default false,
  joined_at timestamptz not null default now(),
  found_at timestamptz,
  primary key (game_id, user_id)
);
create index game_players_user_idx on public.game_players(user_id);

-- ---------- audit log ----------
create table public.audit_log (
  id bigint generated always as identity primary key,
  game_id uuid references public.games(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create index audit_log_game_idx on public.audit_log(game_id, at desc);

-- ---------- helpers ----------
create function public.is_organizer() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select is_organizer from public.profiles where id = (select auth.uid())), false)
$$;

create function public.is_game_member(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.game_players
                where game_id = gid and user_id = (select auth.uid()) and status = 'joined')
$$;

create function public.default_config() returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'hiders',1,'method','random','headStart',true,'headStartMin',3,
    'startMode','manual','durationMin',20,'reveal','proximity','revealEveryMin',2,
    'threshold',15,'accuracyMax',20,'seekersSeeSeekers',false,'hidersSeeSeekers',true,
    'capacity',50,'minPlayers',4,'distRef','origin','hiderRank','separate')
$$;

create function public.new_join_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
begin
  loop
    code := 'GN-';
    for i in 1..4 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists(select 1 from public.games where join_code = code);
  end loop;
  return code;
end $$;

create function public.log_action(gid uuid, act text, det jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_log(game_id, actor_id, action, detail) values (gid, (select auth.uid()), act, det)
$$;

create function public.require_organizer(gid uuid) returns public.games
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  select * into g from public.games where id = gid for update;
  if g.id is null then raise exception 'Game not found' using errcode = 'P0002'; end if;
  if g.organizer_id <> (select auth.uid()) or not public.is_organizer() then
    raise exception 'Only this game''s organizer can do that' using errcode = '42501';
  end if;
  return g;
end $$;

-- ---------- row-level security ----------
alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.game_players enable row level security;
alter table public.audit_log enable row level security;

-- Profiles: anyone signed in can read display names; you can only edit your own,
-- and only the player-facing columns (never is_organizer).
create policy "profiles readable by signed-in users" on public.profiles
  for select to authenticated using (true);
create policy "edit own profile" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
revoke update on public.profiles from authenticated, anon;
grant update (display_name, is_adult, rules_ack_at, replay_consent) on public.profiles to authenticated;

-- Games: every signed-in user can see published games; organizers see their own.
create policy "games readable" on public.games
  for select to authenticated using (true);

-- Players: you see the roster of games you're in; organizers see their games' rosters.
create policy "roster readable by members and organizer" on public.game_players
  for select to authenticated using (
    public.is_game_member(game_id)
    or user_id = (select auth.uid())
    or exists(select 1 from public.games g where g.id = game_id and g.organizer_id = (select auth.uid()))
  );

-- Audit log: organizer of the game only.
create policy "audit readable by organizer" on public.audit_log
  for select to authenticated using (
    exists(select 1 from public.games g where g.id = game_id and g.organizer_id = (select auth.uid()))
  );

revoke insert, update, delete on public.games, public.game_players, public.audit_log from authenticated, anon;

-- ---------- player functions ----------
create function public.join_game(code text) returns uuid
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
  return g.id;
end $$;

create function public.leave_game(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.game_players set status = 'left', ready = false
   where game_id = gid and user_id = (select auth.uid()) and status = 'joined'
     and (select status from public.games where id = gid) in ('DRAFT','LOBBY');
end $$;

create function public.set_ready(gid uuid, is_ready boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.game_players set ready = is_ready
   where game_id = gid and user_id = (select auth.uid()) and status = 'joined';
end $$;

create function public.set_volunteer(gid uuid, is_volunteer boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.game_players set volunteer = is_volunteer
   where game_id = gid and user_id = (select auth.uid()) and status = 'joined'
     and (select status from public.games where id = gid) in ('DRAFT','LOBBY');
end $$;

-- ---------- organizer functions ----------
create function public.create_game(p_title text, p_kind text, p_starts_at timestamptz,
                                   p_location text, p_config jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if not public.is_organizer() then raise exception 'Organizers only' using errcode = '42501'; end if;
  insert into public.games(title, kind, starts_at, location_name, join_code, config, organizer_id)
  values (p_title, coalesce(p_kind,'scheduled'), p_starts_at, coalesce(p_location,''),
          public.new_join_code(), public.default_config() || coalesce(p_config,'{}'::jsonb), (select auth.uid()))
  returning id into gid;
  perform public.log_action(gid, 'create_game', jsonb_build_object('title', p_title));
  return gid;
end $$;

create function public.update_game_config(gid uuid, p_config jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.config_locked_at is not null then
    raise exception 'Rules are locked once the game starts' using errcode = 'P0001';
  end if;
  update public.games set config = config || p_config, config_version = config_version + 1 where id = gid;
  perform public.log_action(gid, 'update_config', p_config);
end $$;

create function public.open_lobby(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status <> 'DRAFT' then raise exception 'Lobby can only open from Draft' using errcode = 'P0001'; end if;
  update public.games set status = 'LOBBY', lobby_opened_at = now() where id = gid;
  perform public.log_action(gid, 'open_lobby');
end $$;

create function public.set_player_role(gid uuid, uid uuid, p_role public.player_role) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status not in ('DRAFT','LOBBY') then raise exception 'Roles are locked' using errcode = 'P0001'; end if;
  update public.game_players set role = p_role where game_id = gid and user_id = uid;
  perform public.log_action(gid, 'set_role', jsonb_build_object('user', uid, 'role', p_role));
end $$;

create function public.remove_player(gid uuid, uid uuid, reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if coalesce(trim(reason),'') = '' then raise exception 'A reason is required' using errcode = 'P0001'; end if;
  update public.game_players set status = 'removed', ready = false where game_id = gid and user_id = uid;
  perform public.log_action(gid, 'remove_player', jsonb_build_object('user', uid, 'reason', reason));
end $$;

create function public.start_game(gid uuid) returns void
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

  -- Keep organizer picks for manual; otherwise start everyone as seeker.
  if method <> 'manual' then
    update public.game_players set role = 'seeker' where game_id = gid and status = 'joined';
  else
    update public.game_players set role = 'seeker' where game_id = gid and status = 'joined' and role <> 'hider';
  end if;

  if method = 'volunteer' then
    update public.game_players set role = 'hider' where (game_id, user_id) in (
      select game_id, user_id from public.game_players
       where game_id = gid and status = 'joined' and volunteer order by random() limit want);
  end if;
  -- Random (and any shortfall from manual / volunteer) is filled at random.
  update public.game_players set role = 'hider' where (game_id, user_id) in (
    select game_id, user_id from public.game_players
     where game_id = gid and status = 'joined' and role = 'seeker'
     order by random()
     limit greatest(0, want - (select count(*) from public.game_players
                                where game_id = gid and status = 'joined' and role = 'hider')));

  update public.games set status = 'PREPARING', started_at = now(), config_locked_at = now() where id = gid;
  perform public.log_action(gid, 'start_game', jsonb_build_object('players', n, 'config_version', g.config_version));
end $$;

create function public.terminate_game(gid uuid, reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status in ('FINISHED','TERMINATED') then return; end if;
  if coalesce(trim(reason),'') = '' then raise exception 'A reason is required' using errcode = 'P0001'; end if;
  update public.games set status = 'TERMINATED', ended_at = now(), end_reason = reason where id = gid;
  perform public.log_action(gid, 'terminate_game', jsonb_build_object('reason', reason));
end $$;

-- ---------- function privileges ----------
-- Only Game Nite's own functions (other apps' functions in this schema are left alone).
revoke execute on function
  public.handle_new_user(), public.is_organizer(), public.is_game_member(uuid), public.default_config(),
  public.new_join_code(), public.log_action(uuid, text, jsonb), public.require_organizer(uuid),
  public.join_game(text), public.leave_game(uuid), public.set_ready(uuid, boolean),
  public.set_volunteer(uuid, boolean), public.create_game(text, text, timestamptz, text, jsonb),
  public.update_game_config(uuid, jsonb), public.open_lobby(uuid),
  public.set_player_role(uuid, uuid, public.player_role), public.remove_player(uuid, uuid, text),
  public.start_game(uuid), public.terminate_game(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.join_game(text), public.leave_game(uuid), public.set_ready(uuid, boolean),
  public.set_volunteer(uuid, boolean), public.create_game(text, text, timestamptz, text, jsonb),
  public.update_game_config(uuid, jsonb), public.open_lobby(uuid),
  public.set_player_role(uuid, uuid, public.player_role), public.remove_player(uuid, uuid, text),
  public.start_game(uuid), public.terminate_game(uuid, text),
  public.is_organizer(), public.is_game_member(uuid)
to authenticated;

-- ---------- realtime ----------
alter publication supabase_realtime add table public.games, public.game_players;
