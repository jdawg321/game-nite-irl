-- Game Nite: full-game test. Run after migrations 0001–0004 are applied.
-- Plays a whole game with fake users and checks every rule. Everything runs in
-- one transaction and is ROLLED BACK, so nothing is left in the database.
-- Read the `out` table at the end: every row should say PASS.
begin;

create temp table out(step int generated always as identity, check_name text, result text) on commit drop;
grant all on out to authenticated;
create temp table ids(k text primary key, v uuid) on commit drop;
grant all on ids to authenticated;

create function pg_temp.ok(name text, cond boolean) returns void language sql as $$
  insert into out(check_name, result) values (name, case when cond then 'PASS' else 'FAIL' end)
$$;
create function pg_temp.as_user(n int) returns void language sql as $$
  select set_config('request.jwt.claims',
    format('{"sub":"00000000-0000-0000-0000-00000000000%s","role":"authenticated"}', n), true);
$$;

-- Users 1 = organizer (not playing), 2..5 = players. All 18+, rules agreed.
insert into auth.users(id, instance_id, aud, role, email)
select ('00000000-0000-0000-0000-00000000000' || i)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 't' || i || '@test.local'
  from generate_series(1, 5) i;
update public.profiles set display_name = 'Player ' || right(id::text, 1), is_adult = true, rules_ack_at = now(),
       replay_consent = (right(id::text, 1) = '2');
update public.profiles set is_organizer = true where id = '00000000-0000-0000-0000-000000000001';

set local role authenticated;

-- Organizer creates a game: 1 hider, random, 1-min head start, 20 min, 15 m radius, distance clues.
select pg_temp.as_user(1);
insert into ids values ('g', public.create_game('Test Sardines', 'instant', null, 'Provo',
  '{"minPlayers":3,"headStartMin":1,"reveal":"proximity"}'));
select public.set_start_point((select v from ids where k='g'), 40.2338, -111.6585, 500);
select public.open_lobby((select v from ids where k='g'));

-- Players join with the code typed in lowercase.
do $$ declare i int; c text; begin
  select lower(join_code) into c from public.games where id = (select v from ids where k='g');
  for i in 2..5 loop perform pg_temp.as_user(i); perform public.join_game(c); end loop;
end $$;

select pg_temp.as_user(1);
select public.start_game((select v from ids where k='g'));
select pg_temp.ok('start: game is PREPARING with a timeline',
  (select status = 'PREPARING' and seek_starts_at > now() and ends_at > seek_starts_at from public.games where id = (select v from ids where k='g')));

-- Find out (as the database owner) who the hider is, for the rest of the test.
reset role;
insert into ids select 'hider', r.user_id from public.game_roles r where r.game_id = (select v from ids where k='g') and r.role = 'hider';
insert into ids select 'seeker', r.user_id from public.game_roles r
  where r.game_id = (select v from ids where k='g') and r.role = 'seeker' order by r.user_id limit 1;
select pg_temp.ok('roles: exactly one hider', (select count(*) = 1 from ids where k = 'hider'));
set local role authenticated;

-- Roles are private: a seeker sees only their own role.
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='seeker')), true);
select pg_temp.ok('privacy: a seeker reads exactly 1 role (their own)',
  (select count(*) = 1 from public.game_roles where game_id = (select v from ids where k='g')));
select pg_temp.ok('privacy: a seeker cannot call in_hiding_group',
  not has_function_privilege('authenticated', 'public.in_hiding_group(uuid, uuid)', 'execute'));
select pg_temp.ok('privacy: positions table is unreadable',
  not has_table_privilege('authenticated', 'public.player_positions', 'select'));

-- Jump the clock: countdown and head start are over, seeking has begun.
reset role;
update public.games set started_at = now() - interval '2 minutes', seek_starts_at = now() - interval '30 seconds',
       ends_at = now() + interval '19 minutes' where id = (select v from ids where k='g');
set local role authenticated;

-- Hider reports from ~100 m east of the start; seeker from the start.
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='hider')), true);
select public.report_location((select v from ids where k='g'), 40.2338, -111.6573, 6, now());
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='seeker')), true);
select public.report_location((select v from ids where k='g'), 40.2338, -111.6585, 6, now());

select pg_temp.ok('timeline: tick moved the game to ACTIVE',
  (select status = 'ACTIVE' from public.games where id = (select v from ids where k='g')));
select pg_temp.ok('visibility: a seeker never sees the hider',
  not exists(select 1 from public.visible_positions((select v from ids where k='g')) where grp = 'hiding'));
select pg_temp.ok('clue: seeker ~100 m away is told "warm"',
  (select public.my_clue((select v from ids where k='g'))->>'band' = 'warm'));
select pg_temp.ok('find: from 100 m away is rejected as too far',
  (select public.request_find((select v from ids where k='g'), 40.2338, -111.6585, 6, now())->>'result' = 'too_far'));
select pg_temp.ok('find: a bad-accuracy fix goes to organizer review',
  (select public.request_find((select v from ids where k='g'), 40.2338, -111.65735, 45, now())->>'result' = 'review'));

-- Organizer rejects that one; then the seeker walks up and makes a good find.
select pg_temp.as_user(1);
select public.review_find((select id from public.finds where status = 'review' limit 1), false, 'GPS too vague');
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='seeker')), true);
select pg_temp.ok('find: within 15 m with good GPS asks the hider to confirm',
  (select public.request_find((select v from ids where k='g'), 40.2338, -111.65735, 5, now())->>'result' = 'confirming'));

-- The hider confirms.
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='hider')), true);
select pg_temp.ok('confirm: hider can see the find waiting',
  exists(select 1 from public.finds where status = 'confirming'));
select public.confirm_find((select id from public.finds where status = 'confirming' limit 1), true);

-- The found seeker is now in the hiding group and can see the hider.
select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (select v from ids where k='seeker')), true);
select pg_temp.ok('found seeker now sees the hiding group',
  exists(select 1 from public.visible_positions((select v from ids where k='g')) where grp = 'hiding'));
select pg_temp.ok('found seeker gets the hiding clue',
  (select public.my_clue((select v from ids where k='g'))->>'mode' = 'hiding'));

-- Pause hides everything; resume pushes the clock back.
select pg_temp.as_user(1);
select public.pause_game((select v from ids where k='g'), 'Car on the path', true);
select pg_temp.ok('pause: no positions while paused',
  not exists(select 1 from public.visible_positions((select v from ids where k='g'))));
reset role;
update public.games set paused_at = now() - interval '2 minutes' where id = (select v from ids where k='g');
create temp table t_end as select ends_at from public.games where id = (select v from ids where k='g');
set local role authenticated;
select pg_temp.as_user(1);
select public.resume_game((select v from ids where k='g'));
reset role;
select pg_temp.ok('resume: end time moved later by the pause',
  (select g.ends_at > t.ends_at + interval '110 seconds' from public.games g, t_end t where g.id = (select v from ids where k='g')));
set local role authenticated;

-- Time runs out; results rank the found seeker first.
reset role;
update public.games set ends_at = now() - interval '1 second' where id = (select v from ids where k='g');
set local role authenticated;
select pg_temp.as_user(1);
select public.tick_game((select v from ids where k='g'));
select pg_temp.ok('end: game FINISHED when time expired',
  (select status = 'FINISHED' and end_reason = 'Time expired' from public.games where id = (select v from ids where k='g')));
select pg_temp.ok('results: found seeker is 1st',
  (select place = 1 and category = 'found' from public.game_results((select v from ids where k='g'))
    where user_id = (select v from ids where k='seeker')));
select pg_temp.ok('results: hider listed separately (no place)',
  (select place is null from public.game_results((select v from ids where k='g'))
    where user_id = (select v from ids where k='hider')));
reset role;
select pg_temp.ok('privacy: raw samples deleted for players without replay consent',
  not exists(select 1 from public.location_samples s join public.profiles p on p.id = s.user_id
              where s.game_id = (select v from ids where k='g') and not p.replay_consent));
set local role authenticated;

-- Account deletion removes the user and their data.
select pg_temp.as_user(5);
select public.delete_account();
reset role;
select pg_temp.ok('delete: auth user and profile are gone',
  not exists(select 1 from auth.users where id = '00000000-0000-0000-0000-000000000005')
  and not exists(select 1 from public.profiles where id = '00000000-0000-0000-0000-000000000005'));

select step, check_name, result from out order by step;
rollback;
