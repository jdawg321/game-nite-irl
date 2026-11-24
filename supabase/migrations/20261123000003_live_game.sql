-- Game Nite — Stage 2: the live game.
-- Positions are private tables (no client SELECT at all). Players only ever get
-- what visible_positions() / my_clue() decide they may see, computed on the server
-- from the game's rules, their role and the game state. Pausing or ending a game
-- hides every position immediately because those functions return nothing then.

-- ---------- game timeline + area ----------
alter table public.games
  add column start_lat double precision,
  add column start_lng double precision,
  add column boundary_m int not null default 600 check (boundary_m between 100 and 5000),
  add column seek_starts_at timestamptz,
  add column ends_at timestamptz,
  add column paused_at timestamptz,
  add column pause_reason text,
  add column emergency boolean not null default false,
  add column origin_lat double precision,
  add column origin_lng double precision;

-- ---------- private location tables ----------
create table public.player_positions (
  game_id uuid not null,
  user_id uuid not null,
  lat double precision not null,
  lng double precision not null,
  accuracy_m double precision not null,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  out_of_bounds boolean not null default false,
  best_distance_m double precision,
  best_at timestamptz,
  primary key (game_id, user_id),
  foreign key (game_id, user_id) references public.game_players(game_id, user_id) on delete cascade
);

create table public.location_samples (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  accuracy_m double precision not null,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  on_demand boolean not null default false
);
create index location_samples_game_user_idx on public.location_samples(game_id, user_id, recorded_at);

alter table public.player_positions enable row level security;
alter table public.location_samples enable row level security;
-- No policies on purpose: clients can't read or write these directly.
revoke all on public.player_positions, public.location_samples from authenticated, anon;

-- ---------- finds ----------
create type public.find_status as enum ('confirming','verified','review','rejected');

create table public.finds (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  seeker_id uuid not null references public.profiles(id) on delete cascade,
  accuracy_m double precision not null,
  distance_m double precision,
  status public.find_status not null,
  reason text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null
);
create index finds_game_idx on public.finds(game_id, status);
alter table public.finds enable row level security;
revoke insert, update, delete on public.finds from authenticated, anon;

-- ---------- helpers ----------
create function public.dist_m(lat1 double precision, lng1 double precision,
                              lat2 double precision, lng2 double precision) returns double precision
language sql immutable set search_path = '' as $$
  select 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))
$$;

-- Hiding group = initial hiders + seekers who have found them.
create function public.in_hiding_group(gid uuid, uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.game_roles r join public.game_players p using (game_id, user_id)
                 where r.game_id = gid and r.user_id = uid and p.status = 'joined'
                   and (r.role = 'hider' or p.found_at is not null))
$$;

-- Caller-only version for RLS: answers about yourself, never about other players.
create function public.am_in_hiding_group(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.in_hiding_group(gid, (select auth.uid()))
$$;

create policy "seekers see own finds" on public.finds
  for select to authenticated using (seeker_id = (select auth.uid()));
create policy "hiding group sees finds to confirm" on public.finds
  for select to authenticated using (status = 'confirming' and public.am_in_hiding_group(game_id));
create policy "organizer sees finds" on public.finds
  for select to authenticated using (
    exists(select 1 from public.games g where g.id = game_id and g.organizer_id = (select auth.uid())));

-- Nearest fresh, accurate hiding-group position to a point (null if none).
create function public.nearest_hider_m(gid uuid, plat double precision, plng double precision) returns double precision
language sql stable security definer set search_path = '' as $$
  select min(public.dist_m(plat, plng, pp.lat, pp.lng))
    from public.player_positions pp
    join public.games g on g.id = pp.game_id
   where pp.game_id = gid
     and public.in_hiding_group(gid, pp.user_id)
     and pp.recorded_at > now() - interval '90 seconds'
     and pp.accuracy_m <= (g.config->>'accuracyMax')::double precision
$$;

create function public.finish_game(gid uuid, why text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.games set status = 'FINISHED', ended_at = now(), end_reason = why, paused_at = null
   where id = gid and status not in ('FINISHED','TERMINATED');
  -- Raw samples are only kept for players who opted in to replays.
  delete from public.location_samples s using public.profiles p
   where s.game_id = gid and p.id = s.user_id and not p.replay_consent;
end $$;

-- Moves the game along its timeline. Safe to call any time, by anyone in the game.
create function public.tick_game(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  select * into g from public.games where id = gid for update;
  if g.id is null then return; end if;

  if g.status = 'PREPARING' and now() >= g.started_at + interval '10 seconds' then
    update public.games set status = 'ACTIVE' where id = gid;
    g.status := 'ACTIVE';
  end if;

  if g.status = 'ACTIVE' then
    -- Freeze the original hiding spot when seeking begins (for distRef = origin).
    if g.origin_lat is null and now() >= g.seek_starts_at then
      update public.games set (origin_lat, origin_lng) = (
        select pp.lat, pp.lng from public.player_positions pp
          join public.game_roles r using (game_id, user_id)
         where pp.game_id = gid and r.role = 'hider'
         order by pp.recorded_at desc limit 1)
       where id = gid;
    end if;
    if now() >= g.ends_at then
      perform public.finish_game(gid, 'Time expired');
    end if;
    -- A find nobody in the hiding group confirmed within 60 s goes to the organizer.
    update public.finds set status = 'review', reason = 'No hider confirmed within 60 seconds'
     where game_id = gid and status = 'confirming' and created_at < now() - interval '60 seconds';
  end if;
end $$;

-- ---------- start / pause / resume ----------
create or replace function public.start_game(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  g public.games;
  n int;
  want int;
  method text;
  seek_at timestamptz;
begin
  g := public.require_organizer(gid);
  if g.status <> 'LOBBY' then raise exception 'Open the lobby first' using errcode = 'P0001'; end if;
  select count(*) into n from public.game_players where game_id = gid and status = 'joined';
  if n < (g.config->>'minPlayers')::int then
    raise exception 'Need at least % players (have %)', g.config->>'minPlayers', n using errcode = 'P0001';
  end if;
  want := least((g.config->>'hiders')::int, n - 1);
  method := g.config->>'method';

  update public.game_roles r set role = 'pending'
    from public.game_players p
   where p.game_id = gid and p.status <> 'joined' and r.game_id = p.game_id and r.user_id = p.user_id;
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
  update public.game_roles set role = 'hider' where (game_id, user_id) in (
    select r.game_id, r.user_id
      from public.game_roles r join public.game_players p using (game_id, user_id)
     where r.game_id = gid and p.status = 'joined' and r.role = 'seeker'
     order by random()
     limit greatest(0, want - (select count(*)
                                 from public.game_roles r2 join public.game_players p2 using (game_id, user_id)
                                where r2.game_id = gid and p2.status = 'joined' and r2.role = 'hider')));

  -- 10 s countdown, then the head start (if any), then seeking for durationMin.
  seek_at := now() + interval '10 seconds'
           + case when (g.config->>'headStart')::boolean
                  then make_interval(mins => (g.config->>'headStartMin')::int) else interval '0' end;
  update public.games
     set status = 'PREPARING', started_at = now(), config_locked_at = now(),
         seek_starts_at = seek_at, ends_at = seek_at + make_interval(mins => (g.config->>'durationMin')::int)
   where id = gid;
  perform public.log_action(gid, 'start_game', jsonb_build_object('players', n, 'config_version', g.config_version));
end $$;

create function public.pause_game(gid uuid, reason text, is_emergency boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status not in ('PREPARING','ACTIVE') then raise exception 'Only a running game can be paused' using errcode = 'P0001'; end if;
  if coalesce(trim(reason),'') = '' then raise exception 'A reason is required' using errcode = 'P0001'; end if;
  update public.games set status = 'PAUSED', paused_at = now(), pause_reason = reason, emergency = is_emergency where id = gid;
  perform public.log_action(gid, case when is_emergency then 'emergency_pause' else 'pause_game' end,
                            jsonb_build_object('reason', reason));
end $$;

create function public.resume_game(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  g public.games;
  gap interval;
begin
  g := public.require_organizer(gid);
  if g.status <> 'PAUSED' then raise exception 'The game isn''t paused' using errcode = 'P0001'; end if;
  gap := now() - g.paused_at;
  -- The clock stops while paused: push the remaining phases back by the pause length.
  update public.games
     set status = 'ACTIVE', paused_at = null, pause_reason = null, emergency = false,
         ends_at = ends_at + gap,
         seek_starts_at = case when seek_starts_at > g.paused_at then seek_starts_at + gap else seek_starts_at end,
         started_at = case when started_at + interval '10 seconds' > g.paused_at then started_at + gap else started_at end
   where id = gid;
  perform public.log_action(gid, 'resume_game', jsonb_build_object('paused_seconds', extract(epoch from gap)::int));
end $$;

create or replace function public.terminate_game(gid uuid, reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.status in ('FINISHED','TERMINATED') then return; end if;
  if coalesce(trim(reason),'') = '' then raise exception 'A reason is required' using errcode = 'P0001'; end if;
  update public.games set status = 'TERMINATED', ended_at = now(), end_reason = reason, paused_at = null where id = gid;
  delete from public.location_samples s using public.profiles p
   where s.game_id = gid and p.id = s.user_id and not p.replay_consent;
  perform public.log_action(gid, 'terminate_game', jsonb_build_object('reason', reason));
end $$;

create function public.set_start_point(gid uuid, lat double precision, lng double precision, radius_m int) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.games;
begin
  g := public.require_organizer(gid);
  if g.config_locked_at is not null then raise exception 'The game area is locked once the game starts' using errcode = 'P0001'; end if;
  update public.games set start_lat = lat, start_lng = lng, boundary_m = radius_m where id = gid;
  perform public.log_action(gid, 'set_start_point', jsonb_build_object('radius_m', radius_m));
end $$;

-- ---------- location reporting ----------
create function public.report_location(gid uuid, lat double precision, lng double precision,
                                       accuracy_m double precision, recorded_at timestamptz,
                                       on_demand boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare
  uid uuid := (select auth.uid());
  g public.games;
  oob boolean := false;
  d double precision;
  seeker boolean;
begin
  if not public.is_game_member(gid) then raise exception 'You''re not in this game' using errcode = '42501'; end if;
  perform public.tick_game(gid);
  select * into g from public.games where id = gid;
  if g.status not in ('PREPARING','ACTIVE','PAUSED') then
    return jsonb_build_object('tracking', false, 'status', g.status);
  end if;
  if recorded_at > now() + interval '30 seconds' or recorded_at < now() - interval '10 minutes' then
    raise exception 'Location time is out of range' using errcode = 'P0001';
  end if;
  if accuracy_m < 0 or abs(lat) > 90 or abs(lng) > 180 then
    raise exception 'Invalid location' using errcode = 'P0001';
  end if;

  if g.start_lat is not null then
    oob := public.dist_m(lat, lng, g.start_lat, g.start_lng) > g.boundary_m;
  end if;

  insert into public.location_samples(game_id, user_id, lat, lng, accuracy_m, recorded_at, on_demand)
  values (gid, uid, lat, lng, accuracy_m, recorded_at, on_demand);

  insert into public.player_positions as pp (game_id, user_id, lat, lng, accuracy_m, recorded_at, received_at, out_of_bounds)
  values (gid, uid, lat, lng, accuracy_m, recorded_at, now(), oob)
  on conflict (game_id, user_id) do update
    set lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m,
        recorded_at = excluded.recorded_at, received_at = now(), out_of_bounds = excluded.out_of_bounds
    where pp.recorded_at <= excluded.recorded_at;

  -- Ranking for seekers who don't finish: closest valid distance reached while seeking.
  select exists(select 1 from public.game_roles r join public.game_players p using (game_id, user_id)
                 where r.game_id = gid and r.user_id = uid and r.role = 'seeker' and p.found_at is null)
    into seeker;
  if seeker and g.status = 'ACTIVE' and now() >= g.seek_starts_at
     and accuracy_m <= (g.config->>'accuracyMax')::double precision then
    if g.config->>'distRef' = 'nearest' then
      d := public.nearest_hider_m(gid, lat, lng);
    elsif g.origin_lat is not null then
      d := public.dist_m(lat, lng, g.origin_lat, g.origin_lng);
    end if;
    if d is not null then
      update public.player_positions
         set best_distance_m = d, best_at = recorded_at
       where game_id = gid and user_id = uid and (best_distance_m is null or d < best_distance_m);
    end if;
  end if;

  return jsonb_build_object('tracking', true, 'status', g.status, 'out_of_bounds', oob);
end $$;

-- ---------- what each player may see ----------
create function public.visible_positions(gid uuid)
returns table(user_id uuid, display_name text, lat double precision, lng double precision,
              accuracy_m double precision, recorded_at timestamptz, stale boolean, grp text, out_of_bounds boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  g public.games;
  playing boolean;
  hiding boolean;
begin
  select * into g from public.games where id = gid;
  if g.id is null or g.status <> 'ACTIVE' then return; end if;   -- paused / over: nothing
  playing := public.is_game_member(gid);
  if not playing and g.organizer_id <> uid then return; end if;
  hiding := playing and public.in_hiding_group(gid, uid);

  return query
  select pp.user_id, pr.display_name, pp.lat, pp.lng, pp.accuracy_m, pp.recorded_at,
         pp.recorded_at < now() - interval '90 seconds',
         case when pp.user_id = uid then 'me'
              when public.in_hiding_group(gid, pp.user_id) then 'hiding' else 'seeker' end,
         pp.out_of_bounds
    from public.player_positions pp
    join public.game_players gp on gp.game_id = pp.game_id and gp.user_id = pp.user_id and gp.status = 'joined'
    join public.profiles pr on pr.id = pp.user_id
   where pp.game_id = gid
     and (
       pp.user_id = uid
       or (not playing)                                                     -- organizer watching, not playing
       or (hiding and public.in_hiding_group(gid, pp.user_id))              -- the hiding group sees itself
       or (hiding and not public.in_hiding_group(gid, pp.user_id) and (g.config->>'hidersSeeSeekers')::boolean)
       or (not hiding and not public.in_hiding_group(gid, pp.user_id) and (g.config->>'seekersSeeSeekers')::boolean)
     );
end $$;

-- The seeker's clue, computed here so hiders' exact positions never reach seekers.
create function public.my_clue(gid uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  g public.games;
  me public.player_positions;
  d double precision;
  h record;
  bucket bigint;
  every_s int;
  into_cycle int;
  jitter_m double precision;
  ang double precision;
  radius_m constant double precision := 60;
begin
  select * into g from public.games where id = gid;
  if g.id is null or not public.is_game_member(gid) then return null; end if;
  if g.status = 'PAUSED' then return jsonb_build_object('mode','paused','reason', g.pause_reason, 'emergency', g.emergency); end if;
  if g.status = 'PREPARING' then return jsonb_build_object('mode','countdown','seek_starts_at', g.seek_starts_at); end if;
  if g.status <> 'ACTIVE' then return jsonb_build_object('mode','over'); end if;
  if public.in_hiding_group(gid, uid) then
    return jsonb_build_object('mode','hiding','seek_starts_at', g.seek_starts_at, 'ends_at', g.ends_at);
  end if;
  if now() < g.seek_starts_at then
    return jsonb_build_object('mode','head_start','seek_starts_at', g.seek_starts_at, 'ends_at', g.ends_at);
  end if;

  -- Reference point: the freshest hiding-group position.
  select pp.lat, pp.lng into h from public.player_positions pp
   where pp.game_id = gid and public.in_hiding_group(gid, pp.user_id)
   order by pp.recorded_at desc limit 1;
  if not found then return jsonb_build_object('mode','no_signal','ends_at', g.ends_at); end if;

  if g.config->>'reveal' = 'proximity' then
    select * into me from public.player_positions where game_id = gid and user_id = uid;
    if me.user_id is null then return jsonb_build_object('mode','proximity','band','unknown','ends_at', g.ends_at); end if;
    d := public.dist_m(me.lat, me.lng, h.lat, h.lng);
    return jsonb_build_object('mode','proximity','ends_at', g.ends_at,
      'band', case when d < 25 then 'very_close' when d < 75 then 'close' when d < 200 then 'warm' else 'far' end);
  end if;

  if g.config->>'reveal' = 'periodic' then
    every_s := (g.config->>'revealEveryMin')::int * 60;
    into_cycle := (extract(epoch from now() - g.seek_starts_at)::int) % every_s;
    if into_cycle >= 45 then
      return jsonb_build_object('mode','periodic_hidden','next_in_s', every_s - into_cycle, 'ends_at', g.ends_at);
    end if;
  end if;

  -- Shaded area: a 60 m circle that contains the group but isn't centred on it.
  -- The offset changes every 30 s and is the same for every seeker.
  bucket := floor(extract(epoch from now()) / 30);
  jitter_m := 15 + (('x' || substr(md5(gid::text || bucket::text), 1, 6))::bit(24)::int % 30);
  ang := radians(('x' || substr(md5(bucket::text || gid::text), 1, 6))::bit(24)::int % 360);
  return jsonb_build_object('mode','area','ends_at', g.ends_at, 'radius_m', radius_m,
    'lat', h.lat + (jitter_m * cos(ang)) / 111320.0,
    'lng', h.lng + (jitter_m * sin(ang)) / (111320.0 * cos(radians(h.lat))));
end $$;

-- ---------- finds ----------
create function public.request_find(gid uuid, lat double precision, lng double precision,
                                    accuracy_m double precision, recorded_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare
  uid uuid := (select auth.uid());
  g public.games;
  d double precision;
  fid uuid;
  max_acc double precision;
begin
  perform public.report_location(gid, lat, lng, accuracy_m, recorded_at, true);
  select * into g from public.games where id = gid;
  if g.status <> 'ACTIVE' or now() < g.seek_starts_at then
    raise exception 'Seeking hasn''t started' using errcode = 'P0001';
  end if;
  if not exists(select 1 from public.game_roles r join public.game_players p using (game_id, user_id)
                 where r.game_id = gid and r.user_id = uid and r.role = 'seeker' and p.found_at is null) then
    raise exception 'Only seekers who are still looking can report a find' using errcode = 'P0001';
  end if;
  if exists(select 1 from public.finds where game_id = gid and seeker_id = uid and status in ('confirming','review')) then
    raise exception 'You already have a find waiting' using errcode = 'P0001';
  end if;
  if recorded_at < now() - interval '90 seconds' then
    raise exception 'Your GPS reading is too old. Try again.' using errcode = 'P0001';
  end if;

  max_acc := (g.config->>'accuracyMax')::double precision;
  d := public.nearest_hider_m(gid, lat, lng);

  if accuracy_m > max_acc then
    insert into public.finds(game_id, seeker_id, accuracy_m, distance_m, status, reason)
    values (gid, uid, accuracy_m, d, 'review', format('Your GPS accuracy (±%s m) is worse than the %s m limit', round(accuracy_m), round(max_acc)))
    returning id into fid;
    return jsonb_build_object('result','review','find_id', fid);
  end if;
  if d is null then
    insert into public.finds(game_id, seeker_id, accuracy_m, status, reason)
    values (gid, uid, accuracy_m, 'review', 'No recent location from the hiding group')
    returning id into fid;
    return jsonb_build_object('result','review','find_id', fid);
  end if;
  if d > (g.config->>'threshold')::double precision then
    return jsonb_build_object('result','too_far','distance_band', case when d < 50 then 'close' else 'not_close' end);
  end if;

  insert into public.finds(game_id, seeker_id, accuracy_m, distance_m, status)
  values (gid, uid, accuracy_m, d, 'confirming') returning id into fid;
  return jsonb_build_object('result','confirming','find_id', fid);
end $$;

create function public.verify_find(fid uuid, decider uuid, why text) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.finds;
begin
  update public.finds set status = 'verified', decided_at = now(), decided_by = decider, reason = coalesce(why, reason)
   where id = fid returning * into f;
  update public.game_players set found_at = now() where game_id = f.game_id and user_id = f.seeker_id and found_at is null;
  if not exists(select 1 from public.game_roles r join public.game_players p using (game_id, user_id)
                 where r.game_id = f.game_id and r.role = 'seeker' and p.status = 'joined' and p.found_at is null) then
    perform public.finish_game(f.game_id, 'Everyone found the hiding group');
  end if;
end $$;

create function public.confirm_find(fid uuid, is_here boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  f public.finds;
begin
  select * into f from public.finds where id = fid for update;
  if f.id is null or f.status <> 'confirming' then raise exception 'This find is no longer waiting' using errcode = 'P0001'; end if;
  if not public.in_hiding_group(f.game_id, uid) then raise exception 'Only the hiding group can confirm' using errcode = '42501'; end if;
  if is_here then
    perform public.verify_find(fid, uid, 'Confirmed by the hiding group');
  else
    update public.finds set status = 'review', reason = 'The hiding group said they weren''t here' where id = fid;
  end if;
end $$;

create function public.review_find(fid uuid, approve boolean, reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.finds;
begin
  select * into f from public.finds where id = fid for update;
  if f.id is null then raise exception 'Find not found' using errcode = 'P0002'; end if;
  perform public.require_organizer(f.game_id);
  if f.status <> 'review' then raise exception 'This find isn''t waiting for review' using errcode = 'P0001'; end if;
  if approve and coalesce(trim(reason),'') = '' then raise exception 'A reason is required to approve' using errcode = 'P0001'; end if;
  if approve then
    perform public.verify_find(fid, (select auth.uid()), 'Approved by organizer: ' || reason);
  else
    update public.finds set status = 'rejected', decided_at = now(), decided_by = (select auth.uid()),
           reason = coalesce(nullif(trim(reason),''), 'Rejected by organizer') where id = fid;
  end if;
  perform public.log_action(f.game_id, case when approve then 'approve_find' else 'reject_find' end,
                            jsonb_build_object('find', fid, 'seeker', f.seeker_id, 'reason', reason));
end $$;

-- ---------- results ----------
-- Found seekers rank by the order they were found. Seekers who didn't finish rank
-- by closest valid distance (5 m tolerance), then by who reached it first; exact
-- ties share a place. Initial hiders are listed separately or share 1st (pilot setting).
create function public.game_results(gid uuid)
returns table(user_id uuid, display_name text, category text, place int, shared boolean,
              found_at timestamptz, best_distance_m double precision)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  g public.games;
  hiders_first boolean;
  n_hiders int;
  n_found int;
begin
  select * into g from public.games where id = gid;
  if g.id is null or g.status not in ('FINISHED','TERMINATED') then return; end if;
  if not public.is_game_member(gid) and g.organizer_id <> (select auth.uid()) then return; end if;
  hiders_first := g.config->>'hiderRank' = 'first';
  select count(*) into n_hiders from public.game_roles r join public.game_players p using (game_id, user_id)
   where r.game_id = gid and r.role = 'hider' and p.status = 'joined';
  select count(*) into n_found from public.game_roles r join public.game_players p using (game_id, user_id)
   where r.game_id = gid and r.role = 'seeker' and p.status = 'joined' and p.found_at is not null;

  return query
  with base as (
    select p.user_id, pr.display_name, r.role, p.found_at, pp.best_distance_m, pp.best_at
      from public.game_players p
      join public.game_roles r using (game_id, user_id)
      join public.profiles pr on pr.id = p.user_id
      left join public.player_positions pp on pp.game_id = p.game_id and pp.user_id = p.user_id
     where p.game_id = gid and p.status = 'joined'
  ),
  hiders as (
    select b.user_id, b.display_name, 'hider'::text as category,
           case when hiders_first then 1 else null end as place,
           hiders_first and n_hiders > 1 as shared, b.found_at, b.best_distance_m
      from base b where b.role = 'hider'
  ),
  found as (
    select b.user_id, b.display_name, 'found'::text,
           (case when hiders_first then n_hiders else 0 end
             + rank() over (order by b.found_at))::int,
           count(*) over (partition by b.found_at) > 1, b.found_at, b.best_distance_m
      from base b where b.role = 'seeker' and b.found_at is not null
  ),
  unfinished as (
    select b.user_id, b.display_name, 'unfinished'::text,
           (case when hiders_first then n_hiders else 0 end + n_found
             + rank() over (order by floor(b.best_distance_m / 5) nulls last, b.best_at nulls last))::int,
           count(*) over (partition by floor(b.best_distance_m / 5), b.best_at) > 1, b.found_at, b.best_distance_m
      from base b where b.role = 'seeker' and b.found_at is null
  )
  select * from hiders union all select * from found union all select * from unfinished
  order by 4 nulls first, 3;
end $$;

-- ---------- privileges ----------
revoke execute on function
  public.dist_m(double precision, double precision, double precision, double precision),
  public.in_hiding_group(uuid, uuid), public.nearest_hider_m(uuid, double precision, double precision),
  public.finish_game(uuid, text), public.verify_find(uuid, uuid, text),
  public.tick_game(uuid), public.pause_game(uuid, text, boolean), public.resume_game(uuid),
  public.set_start_point(uuid, double precision, double precision, int),
  public.report_location(uuid, double precision, double precision, double precision, timestamptz, boolean),
  public.visible_positions(uuid), public.my_clue(uuid),
  public.request_find(uuid, double precision, double precision, double precision, timestamptz),
  public.confirm_find(uuid, boolean), public.review_find(uuid, boolean, text), public.game_results(uuid)
from public, anon, authenticated;
grant execute on function
  public.tick_game(uuid), public.pause_game(uuid, text, boolean), public.resume_game(uuid),
  public.set_start_point(uuid, double precision, double precision, int),
  public.report_location(uuid, double precision, double precision, double precision, timestamptz, boolean),
  public.visible_positions(uuid), public.my_clue(uuid),
  public.request_find(uuid, double precision, double precision, double precision, timestamptz),
  public.confirm_find(uuid, boolean), public.review_find(uuid, boolean, text), public.game_results(uuid)
to authenticated;
-- RLS policies run as the caller, so they use the caller-only check.
revoke execute on function public.am_in_hiding_group(uuid) from public, anon;
grant execute on function public.am_in_hiding_group(uuid) to authenticated;

alter publication supabase_realtime add table public.finds;
