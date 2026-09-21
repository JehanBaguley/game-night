-- ============================================================================
-- Game Night - schema v2.1
--
-- Paste the whole file into the Supabase SQL editor and run it once.
-- Safe to re-run: it drops and recreates everything.
--
-- SECURITY MODEL
--   Row level security is ON for every table with NO write policies, which
--   denies the public anon key all direct table access. The only way in is the
--   security-definer functions at the bottom, and every one of them takes a
--   group code. A client that does not know the code cannot read or write
--   anything, and a client cannot read across groups even with a broken query,
--   because the scoping lives in the function rather than the client.
--
-- IDENTITY MODEL (the change in 2.1)
--   A person is a `member` row with a stable member_id. Devices are a separate
--   table pointing at it, so one human can vote from a phone and a laptop and
--   stay one human. Ballots, picks and takes all key on member_id, never on a
--   device, so linking a second device carries the whole history with it.
-- ============================================================================

create extension if not exists "pgcrypto";

drop table if exists plays          cascade;
drop table if exists takes          cascade;
drop table if exists boosts         cascade;   -- gone in the flat-shelf rework
drop table if exists ballots        cascade;
drop table if exists member_devices cascade;
drop table if exists members        cascade;
drop table if exists shelf          cascade;
drop table if exists groups         cascade;
drop table if exists games          cascade;

-- ---------------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------------

create table groups (
  code             text primary key,
  name             text not null,
  quorum           int  not null default 5,   -- votes needed to close a round early
  round_no         int  not null default 1,
  round_started_at timestamptz not null default now(),
  locked_appid     int,                       -- set when a round is called
  paused_at        timestamptz,               -- set while the group is on a break
  emoji            text not null default '🎮',  -- crew icon: favicon, header, crews list
  sesh_need        int,                       -- free people that make a night; null = everyone
  sesh_time        text not null default '8pm', -- usual start, shown on a locked night
  created_at       timestamptz not null default now()
);

-- A person in a group. member_id is the stable identity everything else hangs
-- off, so a name change or a new device never orphans anyone's votes.
create table members (
  group_code text not null references groups(code) on delete cascade,
  member_id  uuid not null default gen_random_uuid(),
  name       text not null,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (group_code, member_id)
);

-- Which devices are this person. Phone plus laptop plus the work machine all
-- point at one member_id, which is what stops the same person appearing twice.
create table member_devices (
  group_code text not null references groups(code) on delete cascade,
  device_id  uuid not null,
  member_id  uuid not null,
  linked_at  timestamptz not null default now(),
  primary key (group_code, device_id)
);

create table ballots (
  group_code text not null references groups(code) on delete cascade,
  member_id  uuid not null,
  round_no   int  not null default 1,
  picks      int[] not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (group_code, member_id, round_no)
);

-- Everything this group can vote on. There is no backlog and no gate: a game is
-- up for a vote the moment it is added. benched = true is the only thing that
-- takes one out of view, and it is one tap to undo.
create table shelf (
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  added_by   uuid,
  added_name text,
  benched    boolean not null default false,  -- out of view, not deleted, one tap back
  energy     int,                             -- 1..3
  crew_max   int,                             -- null = genuinely unknown
  crew_mod   int,                             -- higher count reachable with mods or a server config
  crew_note  text,                            -- the caveat, shown when someone taps the cap
  setup      text,                            -- 'launch' | 'host' | 'server'
  doing      text,                            -- group override for the derived mode of play
  added_at   timestamptz not null default now(),
  primary key (group_code, appid)
);

create table takes (
  group_code text not null references groups(code) on delete cascade,
  member_id  uuid not null,
  appid      int  not null,
  body       text not null,
  updated_at timestamptz not null default now(),
  primary key (group_code, member_id, appid)
);

-- What this group has actually played. One row per game per round, so the
-- same game coming back around later is a second row rather than an overwrite.
-- This is what makes "played before" and "play it again" possible.
create table plays (
  group_code  text not null references groups(code) on delete cascade,
  appid       int  not null,
  round_no    int  not null,                  -- 0 means "before we started tracking"
  started_at  timestamptz not null default now(),
  finished_at timestamptz,                    -- null means this is the one on right now
  verdict     text,                           -- 'banger' | 'fine' | 'never_again'
  primary key (group_code, appid, round_no)
);

-- Steam metadata cache. GLOBAL, not per group: both groups wanting Valheim
-- costs exactly one Steam fetch, ever. Written only by the edge function.
create table games (
  appid        int primary key,
  name         text not null,
  short_desc   text,
  long_desc    text,
  header       text,
  review_desc  text,
  review_pct   int,
  review_count int,
  genres       text[] not null default '{}',
  tags         text[] not null default '{}',
  categories   text[] not null default '{}',
  coop         boolean not null default false,
  online_coop  boolean not null default false,
  released     text,
  coming_soon  boolean not null default false,  -- Steam's own "not out yet" flag
  demo_appid   int,                             -- a free demo you can try first, if there is one
  doing        text,                           -- mucking | building | story | scary | rounds
  shape        text,                           -- dropin | sitting | campaign | longhaul
  energy_guess int,                            -- tag-derived fallback when the group has not set one
  fetched_at   timestamptz not null default now()
);

create index shelf_group_idx  on shelf(group_code);
create index takes_group_idx  on takes(group_code, appid);
create index plays_group_idx  on plays(group_code, appid);
create index devices_member_idx on member_devices(group_code, member_id);
create index games_stale_idx  on games(fetched_at);

-- ---------------------------------------------------------------------------
-- LOCK EVERYTHING DOWN
-- ---------------------------------------------------------------------------
alter table groups         enable row level security;
alter table members        enable row level security;
alter table member_devices enable row level security;
alter table ballots        enable row level security;
alter table shelf          enable row level security;
alter table takes          enable row level security;
alter table plays          enable row level security;
alter table games          enable row level security;

-- games is the one table safe to read openly: public Steam data, nothing
-- group-specific. The keepalive workflow uses this.
create policy games_read on games for select using (true);

-- ---------------------------------------------------------------------------
-- (No promotion trigger any more. Nothing needs promoting: a game is up for a
-- vote from the moment it is added, so there is no gate to enforce.)

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

-- Crockford-ish alphabet: no I, L, O or U, so a code survives being read aloud
-- or typed from a screenshot.
create or replace function make_code()
returns text language plpgsql as $$
declare
  alphabet text := '23456789ABCDEFGHJKMNPQRSTVWXYZ';
  out text := ''; i int;
begin
  for i in 1..7 loop
    out := out || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return out;
end; $$;

-- Which member is this device, if any. The whole "never ask twice" feature
-- rests on this one lookup.
create or replace function member_of(p_code text, p_device uuid)
returns uuid language sql security definer set search_path = public stable as $$
  select member_id from member_devices
   where group_code = p_code and device_id = p_device;
$$;

create or replace function assert_member(p_code text, p_device uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := member_of(p_code, p_device);
  if m is null then raise exception 'this device is not linked to anyone in this group'; end if;
  update members set last_seen = now() where group_code = p_code and member_id = m;
  return m;
end; $$;

-- ---------------------------------------------------------------------------
-- RPCs - the entire public interface
-- ---------------------------------------------------------------------------

-- Returns the member_id for this device, or null. Called before anything else
-- so a returning visitor is recognised without being asked for a name.
create or replace function whoami(p_code text, p_device uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := member_of(p_code, p_device);
  if m is not null then
    update members set last_seen = now() where group_code = p_code and member_id = m;
  end if;
  return m;
end; $$;

-- the emoji is free text from the client, so bound it: a single emoji can run
-- to ~10 code points (ZWJ families, flags, skin tones) but never to a word
create or replace function clean_emoji(p text)
returns text language plpgsql immutable as $$
declare e text := trim(coalesce(p,''));
begin
  if e = '' then return '🎮'; end if;
  if char_length(e) > 16 or e ~ '^[\x20-\x7E]+$' then
    raise exception 'pick an emoji';
  end if;
  return e;
end; $$;

create or replace function create_group(p_name text, p_device uuid, p_person text, p_emoji text default '🎮')
returns text language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0; m uuid;
begin
  if length(coalesce(trim(p_name),'')) = 0 or length(p_name) > 40 then
    raise exception 'group name must be 1 to 40 characters';
  end if;
  loop
    c := make_code();
    exit when not exists (select 1 from groups where code = c);
    tries := tries + 1;
    if tries > 20 then raise exception 'could not allocate a code'; end if;
  end loop;

  insert into groups(code, name, emoji) values (c, trim(p_name), clean_emoji(p_emoji));
  insert into members(group_code, name)
       values (c, left(coalesce(nullif(trim(p_person),''),'Host'), 24))
  returning member_id into m;
  insert into member_devices(group_code, device_id, member_id) values (c, p_device, m);
  return c;
end; $$;

-- any member can rename the crew or change its emoji, same trust level as
-- benching a game; someone who only holds the code has to join first
create or replace function update_group(p_code text, p_device uuid, p_name text, p_emoji text)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if length(coalesce(trim(p_name),'')) = 0 or length(trim(p_name)) > 40 then
    raise exception 'group name must be 1 to 40 characters';
  end if;
  update groups set name = trim(p_name), emoji = clean_emoji(p_emoji) where code = p_code;
end; $$;

-- Create a NEW person in the group and link this device to them.
create or replace function join_as_new(p_code text, p_device uuid, p_person text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m uuid; nm text := left(coalesce(nullif(trim(p_person),''),'Someone'), 24);
begin
  if not exists (select 1 from groups where code = p_code) then
    raise exception 'no group with that code';
  end if;

  m := member_of(p_code, p_device);
  if m is not null then
    -- already linked, so this is a rename rather than a second person
    update members set name = nm, last_seen = now()
     where group_code = p_code and member_id = m;
    return m;
  end if;

  if (select count(*) from members where group_code = p_code) >= 60 then
    raise exception 'this group already has 60 people';
  end if;

  insert into members(group_code, name) values (p_code, nm) returning member_id into m;
  insert into member_devices(group_code, device_id, member_id) values (p_code, p_device, m);
  return m;
end; $$;

-- Link this device to a person who is ALREADY in the group. This is what runs
-- when someone says "yes, that Sam is me" from a second device.
-- Additive: the original device keeps working, so this is a link, not a takeover.
create or replace function claim_member(p_code text, p_device uuid, p_member uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from members where group_code = p_code and member_id = p_member) then
    raise exception 'no such person in this group';
  end if;

  insert into member_devices(group_code, device_id, member_id)
       values (p_code, p_device, p_member)
  on conflict (group_code, device_id) do update set member_id = excluded.member_id;

  update members set last_seen = now() where group_code = p_code and member_id = p_member;
  return p_member;
end; $$;

create or replace function rename_me(p_code text, p_device uuid, p_person text)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  update members set name = left(coalesce(nullif(trim(p_person),''),'Someone'), 24)
   where group_code = p_code and member_id = m;
end; $$;

create or replace function touch_group(p_code text, p_device uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := member_of(p_code, p_device);
  if m is not null then
    update members set last_seen = now() where group_code = p_code and member_id = m;
  end if;
end; $$;

-- One read for the whole page, so polling is a single round trip.
-- device_count lets the UI show that a person has more than one device linked,
-- which is the only visible signal that a claim happened.
create or replace function get_state(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare g groups%rowtype; result json;
begin
  select * into g from groups where code = p_code;
  if not found then raise exception 'no group with that code'; end if;

  select json_build_object(
    'group', json_build_object(
       'code', g.code, 'name', g.name, 'quorum', g.quorum,
       'round_no', g.round_no, 'round_started_at', g.round_started_at,
       'locked_appid', g.locked_appid, 'paused_at', g.paused_at,
       'emoji', g.emoji, 'sesh_need', g.sesh_need, 'sesh_time', g.sesh_time,
       'tint_h', g.tint_h, 'tint_s', g.tint_s, 'tint_emoji', g.tint_emoji,
       'discord', g.discord_hook is not null),
    'members', coalesce((
       select json_agg(json_build_object(
         'member_id', m.member_id, 'name', m.name,
         'last_seen', m.last_seen, 'first_seen', m.first_seen,
         'device_count', (select count(*) from member_devices d
                           where d.group_code = p_code and d.member_id = m.member_id)
       ) order by m.first_seen)
       from members m where m.group_code = p_code), '[]'::json),
    'ballots', coalesce((
       select json_agg(json_build_object(
         'member_id', b.member_id, 'picks', b.picks, 'updated_at', b.updated_at))
       from ballots b where b.group_code = p_code and b.round_no = g.round_no), '[]'::json),
    'shelf', coalesce((
       select json_agg(json_build_object(
         'appid', s.appid, 'benched', s.benched, 'added_name', s.added_name,
         'energy', s.energy, 'crew_max', s.crew_max, 'crew_mod', s.crew_mod,
         'crew_note', s.crew_note, 'setup', s.setup, 'doing', s.doing,
         'added_at', s.added_at) order by s.added_at)
       from shelf s where s.group_code = p_code), '[]'::json),
    'takes', coalesce((
       select json_agg(json_build_object(
         'member_id', t.member_id, 'appid', t.appid, 'body', t.body))
       from takes t where t.group_code = p_code), '[]'::json),
    'plays', coalesce((
       select json_agg(json_build_object(
         'appid', pl.appid, 'round_no', pl.round_no,
         'started_at', pl.started_at, 'finished_at', pl.finished_at,
         'verdict', pl.verdict) order by pl.started_at)
       from plays pl where pl.group_code = p_code), '[]'::json),
    'games', coalesce((
       select json_agg(to_json(ga)) from games ga
        where ga.appid in (select appid from shelf where group_code = p_code)), '[]'::json),
    -- next sesh: free nights from yesterday on (server clock is UTC, the crew is not)
    'sesh_free', coalesce((
       select json_agg(json_build_object('appid', sf.appid, 'day', sf.day, 'member_id', sf.member_id))
       from sesh_free sf where sf.group_code = p_code and sf.day >= current_date - 1), '[]'::json),
    'sesh_none', coalesce((
       select json_agg(json_build_object('appid', sn.appid, 'member_id', sn.member_id))
       from sesh_none sn where sn.group_code = p_code), '[]'::json),
    'sesh_lock', coalesce((
       select json_agg(json_build_object('appid', sl.appid, 'day', sl.day, 'locked_by', sl.locked_by))
       from sesh_lock sl where sl.group_code = p_code), '[]'::json),
    'sessions', coalesce((
       select json_agg(json_build_object('appid', se.appid, 'day', se.day) order by se.day)
       from sessions se where se.group_code = p_code), '[]'::json),
    'side', coalesce((
       select json_agg(json_build_object(
         'appid', sg.appid, 'started_at', sg.started_at, 'started_by', sg.started_by,
         'players', coalesce((select json_agg(sp.member_id) from side_players sp
                               where sp.group_code = p_code and sp.appid = sg.appid), '[]'::json))
         order by sg.started_at)
       from side_games sg where sg.group_code = p_code), '[]'::json),
    'owns', coalesce((
       select json_agg(json_build_object('appid', o.appid, 'member_id', o.member_id))
       from owns o where o.group_code = p_code), '[]'::json),
    'prices', coalesce((
       select json_agg(to_json(pr)) from prices pr
        where pr.appid in (select appid from shelf where group_code = p_code)), '[]'::json)
  ) into result;
  return result;
end; $$;

create or replace function set_picks(p_code text, p_device uuid, p_picks int[])
returns void language plpgsql security definer set search_path = public as $$
declare m uuid; rn int; clean int[];
begin
  m := assert_member(p_code, p_device);
  select round_no into rn from groups where code = p_code;

  -- only games actually on this group's shelf and not benched, max 3
  select coalesce(array_agg(distinct a), '{}') into clean
    from unnest(p_picks) a
   where a in (select appid from shelf where group_code = p_code and not benched);

  if array_length(clean, 1) > 3 then raise exception 'three picks maximum'; end if;

  insert into ballots(group_code, member_id, round_no, picks, updated_at)
       values (p_code, m, rn, clean, now())
  on conflict (group_code, member_id, round_no)
  do update set picks = excluded.picks, updated_at = now();
end; $$;

create or replace function add_game(
  p_code text, p_device uuid, p_appid int,
  p_energy int default null, p_crew_max int default null, p_setup text default null,
  p_crew_mod int default null, p_crew_note text default null
) returns void language plpgsql security definer set search_path = public as $$
declare m uuid; nm text;
begin
  m := assert_member(p_code, p_device);
  if (select count(*) from shelf where group_code = p_code) >= 200 then
    raise exception 'this group already has 200 games, retire some first';
  end if;
  select name into nm from members where group_code = p_code and member_id = m;

  insert into shelf(group_code, appid, added_by, added_name, benched,
                    energy, crew_max, crew_mod, crew_note, setup)
       values (p_code, p_appid, m, nm, false,
               p_energy, p_crew_max, p_crew_mod, left(p_crew_note, 160), p_setup)
  on conflict (group_code, appid) do update set benched = false;
end; $$;

create or replace function set_facets(
  p_code text, p_device uuid, p_appid int,
  p_energy int, p_crew_max int, p_setup text,
  p_crew_mod int default null, p_doing text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  if p_energy is not null and (p_energy < 1 or p_energy > 3) then
    raise exception 'energy must be 1, 2 or 3'; end if;
  if p_crew_max is not null and (p_crew_max < 1 or p_crew_max > 200) then
    raise exception 'player cap looks wrong'; end if;
  if p_setup is not null and p_setup not in ('launch','host','server') then
    raise exception 'setup must be launch, host or server'; end if;
  if p_doing is not null and p_doing not in ('mucking','building','story','scary','rounds') then
    raise exception 'doing must be mucking, building, story, scary or rounds'; end if;

  update shelf
     set energy   = coalesce(p_energy, energy),
         crew_max = coalesce(p_crew_max, crew_max),
         crew_mod = coalesce(p_crew_mod, crew_mod),
         setup    = coalesce(p_setup, setup),
         doing    = coalesce(p_doing, doing)
   where group_code = p_code and appid = p_appid;
end; $$;

-- Take a game out of view. Any member can do it, and it is not a delete:
-- takes and the whole play history survive, and unbench_game puts
-- it straight back. Current picks are cleared so the tally stays honest.
create or replace function bench_game(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  update shelf set benched = true where group_code = p_code and appid = p_appid;
  update ballots set picks = array_remove(picks, p_appid), updated_at = now()
   where group_code = p_code and p_appid = any(picks);
end; $$;

create or replace function unbench_game(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  update shelf set benched = false where group_code = p_code and appid = p_appid;
end; $$;


-- Round 0 is history from before the app existed. Every group starts with a
-- shelf they have already been playing for ages, and a card that says "never
-- played" for all of it is simply wrong. Re-running it just updates the
-- verdict, so it doubles as the edit.
create or replace function log_past_play(
  p_code text, p_device uuid, p_appid int, p_verdict text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  if p_verdict is not null and p_verdict not in ('banger','fine','never_again') then
    raise exception 'verdict must be banger, fine or never_again';
  end if;
  insert into plays(group_code, appid, round_no, started_at, finished_at, verdict)
       values (p_code, p_appid, 0, now(), now(), p_verdict)
  on conflict (group_code, appid, round_no)
  do update set verdict = excluded.verdict;
end; $$;

-- Undo the above, or drop a round that never actually happened.
create or replace function forget_play(
  p_code text, p_device uuid, p_appid int, p_round int
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  delete from plays
   where group_code = p_code and appid = p_appid and round_no = p_round
     and finished_at is not null;   -- never delete the game that is on right now
end; $$;

create or replace function set_take(p_code text, p_device uuid, p_appid int, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if p_body is null or length(trim(p_body)) = 0 then
    delete from takes where group_code = p_code and member_id = m and appid = p_appid;
    return;
  end if;
  insert into takes(group_code, member_id, appid, body, updated_at)
       values (p_code, m, p_appid, left(trim(p_body), 140), now())
  on conflict (group_code, member_id, appid)
  do update set body = excluded.body, updated_at = now();
end; $$;

-- Lock the round in. The chosen game starts a play row, which is what turns
-- "we voted for this" into "we are playing this right now".
-- Between games. Votes still land, there is just nothing being counted down
-- and the group can see that on purpose rather than by the round going stale.
create or replace function set_break(p_code text, p_device uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  update groups set paused_at = case when p_on then now() else null end
   where code = p_code;
end; $$;

create or replace function close_round(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
declare rn int;
begin
  perform assert_member(p_code, p_device);
  select round_no into rn from groups where code = p_code;
  update groups set locked_appid = p_appid where code = p_code;
  insert into plays(group_code, appid, round_no) values (p_code, p_appid, rn)
  on conflict (group_code, appid, round_no) do nothing;
end; $$;

-- Undo a lock-in before anyone has played it.
create or replace function reopen_round(p_code text, p_device uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rn int; a int;
begin
  perform assert_member(p_code, p_device);
  select round_no, locked_appid into rn, a from groups where code = p_code;
  if a is null then return; end if;
  delete from plays where group_code = p_code and round_no = rn and finished_at is null;
  update groups set locked_appid = null where code = p_code;
end; $$;

-- Finish what is on and open a fresh round. The verdict is optional and is
-- the only bit of memory the group keeps about whether it was any good.
create or replace function new_round(
  p_code text, p_device uuid, p_verdict text default null,
  p_bench boolean default false, p_break boolean default false
) returns void language plpgsql security definer set search_path = public as $$
declare rn int; a int;
begin
  perform assert_member(p_code, p_device);
  if p_verdict is not null and p_verdict not in ('banger','fine','never_again') then
    raise exception 'verdict must be banger, fine or never_again';
  end if;
  select round_no, locked_appid into rn, a from groups where code = p_code;

  update plays set finished_at = now(), verdict = coalesce(p_verdict, verdict)
   where group_code = p_code and round_no = rn and finished_at is null;

  -- The group decides at the finish line whether the game stays on the shelf
  -- or gets benched. Nothing is guessed: a long-haul game you are still
  -- enjoying should not be buried, and a dud should not keep winning.
  if p_bench and a is not null then
    update shelf set benched = true where group_code = p_code and appid = a;
    update ballots set picks = array_remove(picks, a) where group_code = p_code and a = any(picks);
  end if;

  update groups
     set round_no = round_no + 1, round_started_at = now(), locked_appid = null,
         paused_at = case when p_break then now() else null end
   where code = p_code;
end; $$;

-- ---------------------------------------------------------------------------
-- GRANTS - the anon key may call these functions and nothing else
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon;
-- Postgres grants EXECUTE to PUBLIC on new functions, so revoking from anon
-- alone still leaves these three internal helpers callable by anyone.
revoke execute on function make_code() from public;
revoke execute on function clean_emoji(text) from public;
revoke execute on function member_of(text, uuid) from public;
revoke execute on function assert_member(text, uuid) from public;

grant execute on function whoami(text, uuid)                                to anon;
grant execute on function create_group(text, uuid, text, text)              to anon;
grant execute on function update_group(text, uuid, text, text)              to anon;
grant execute on function join_as_new(text, uuid, text)                     to anon;
grant execute on function claim_member(text, uuid, uuid)                    to anon;
grant execute on function rename_me(text, uuid, text)                       to anon;
grant execute on function touch_group(text, uuid)                           to anon;
grant execute on function get_state(text)                                   to anon;
grant execute on function set_picks(text, uuid, int[])                      to anon;
grant execute on function add_game(text, uuid, int, int, int, text, int, text)          to anon;
grant execute on function set_facets(text, uuid, int, int, int, text, int, text) to anon;
grant execute on function bench_game(text, uuid, int)                       to anon;
grant execute on function unbench_game(text, uuid, int)                     to anon;
grant execute on function log_past_play(text, uuid, int, text)              to anon;
grant execute on function forget_play(text, uuid, int, int)                 to anon;
grant execute on function set_take(text, uuid, int, text)                   to anon;
grant execute on function close_round(text, uuid, int)                      to anon;
grant execute on function new_round(text, uuid, text, boolean, boolean)     to anon;
grant execute on function set_break(text, uuid, boolean)                    to anon;
grant execute on function reopen_round(text, uuid)                          to anon;
grant select on games to anon;

-- ---------------------------------------------------------------------------
-- NEXT SESH, SESSIONS AND SIDE GAMES
-- Picking the game is one decision; picking the nights is another. A game in
-- play (the called one, or a side game) collects "I'm free" days, a night that
-- reaches the crew's number is pencilled in, someone locks it, and once it has
-- passed one question logs whether it happened.
-- ---------------------------------------------------------------------------
alter table groups add column if not exists sesh_need int;                         -- null = everyone in the crew
alter table groups add column if not exists sesh_time text not null default '8pm'; -- shown on a locked night

create table if not exists sesh_free (            -- one row per person per free night per game
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  day        date not null,
  member_id  uuid not null,
  primary key (group_code, appid, day, member_id)
);
create table if not exists sesh_none (            -- "can't do any of these", so a no still counts as an answer
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  member_id  uuid not null,
  set_at     timestamptz not null default now(),
  primary key (group_code, appid, member_id)
);
create table if not exists sesh_lock (            -- the night we're going with; one per game in play
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  day        date not null,
  locked_by  uuid,
  locked_at  timestamptz not null default now(),
  primary key (group_code, appid)
);
create table if not exists sessions (             -- nights that actually happened
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  day        date not null,
  logged_at  timestamptz not null default now(),
  primary key (group_code, appid, day)
);
create table if not exists side_games (           -- a second, smaller game running alongside the called one
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  started_by uuid,
  started_at timestamptz not null default now(),
  primary key (group_code, appid)
);
create table if not exists side_players (
  group_code text not null,
  appid      int  not null,
  member_id  uuid not null,
  primary key (group_code, appid, member_id),
  foreign key (group_code, appid) references side_games(group_code, appid) on delete cascade
);

alter table sesh_free    enable row level security;
alter table sesh_none    enable row level security;
alter table sesh_lock    enable row level security;
alter table sessions     enable row level security;
alter table side_games   enable row level security;
alter table side_players enable row level security;
revoke all on sesh_free, sesh_none, sesh_lock, sessions, side_games, side_players from anon, authenticated;

-- is this game on right now, as the called game or on the side?
create or replace function in_play(p_code text, p_appid int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from groups where code = p_code and locked_appid = p_appid)
      or exists (select 1 from side_games where group_code = p_code and appid = p_appid);
$$;

-- replace my free nights for a game with this set
create or replace function set_free(p_code text, p_device uuid, p_appid int, p_days date[])
returns void language plpgsql security definer set search_path = public as $$
declare m uuid; n int := coalesce(array_length(p_days, 1), 0);
begin
  m := assert_member(p_code, p_device);
  if not in_play(p_code, p_appid) then raise exception 'that game is not on right now'; end if;
  if n > 16 then raise exception 'too many days'; end if;
  delete from sesh_free where group_code = p_code and appid = p_appid and member_id = m;
  insert into sesh_free(group_code, appid, day, member_id)
       select p_code, p_appid, d, m from unnest(p_days) d
        where d between current_date - 1 and current_date + 16
  on conflict do nothing;
  if n > 0 then
    delete from sesh_none where group_code = p_code and appid = p_appid and member_id = m;
  end if;
end; $$;

-- "can't do any of these"
create or replace function set_none(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if not in_play(p_code, p_appid) then raise exception 'that game is not on right now'; end if;
  delete from sesh_free where group_code = p_code and appid = p_appid and member_id = m;
  insert into sesh_none(group_code, appid, member_id) values (p_code, p_appid, m)
  on conflict (group_code, appid, member_id) do update set set_at = now();
end; $$;

create or replace function lock_sesh(p_code text, p_device uuid, p_appid int, p_day date)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if not in_play(p_code, p_appid) then raise exception 'that game is not on right now'; end if;
  if p_day < current_date - 1 then raise exception 'that night has been'; end if;
  insert into sesh_lock(group_code, appid, day, locked_by) values (p_code, p_appid, p_day, m)
  on conflict (group_code, appid) do update set day = excluded.day, locked_by = excluded.locked_by, locked_at = now();
end; $$;

create or replace function unlock_sesh(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  delete from sesh_lock where group_code = p_code and appid = p_appid;
end; $$;

-- after the night: did it happen? Either way the slate is wiped for the next one
create or replace function resolve_sesh(p_code text, p_device uuid, p_appid int, p_played boolean)
returns void language plpgsql security definer set search_path = public as $$
declare d date;
begin
  perform assert_member(p_code, p_device);
  select day into d from sesh_lock where group_code = p_code and appid = p_appid;
  if d is null then return; end if;
  if p_played then
    insert into sessions(group_code, appid, day) values (p_code, p_appid, d) on conflict do nothing;
  end if;
  delete from sesh_lock where group_code = p_code and appid = p_appid;
  delete from sesh_free where group_code = p_code and appid = p_appid;
  delete from sesh_none where group_code = p_code and appid = p_appid;
end; $$;

-- the crew's rules: how many free makes a night, and the usual start time
create or replace function set_sesh_rules(p_code text, p_device uuid, p_need int, p_time text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  if p_need is not null and (p_need < 1 or p_need > 60) then raise exception 'pick a number from 1 up'; end if;
  update groups
     set sesh_need = p_need,
         sesh_time = coalesce(nullif(left(trim(coalesce(p_time,'')), 12), ''), '8pm')
   where code = p_code;
end; $$;

create or replace function start_side_game(p_code text, p_device uuid, p_appid int)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if not exists (select 1 from shelf where group_code = p_code and appid = p_appid and not benched) then
    raise exception 'that game is not on the shelf';
  end if;
  if exists (select 1 from groups where code = p_code and locked_appid = p_appid) then
    raise exception 'that is already the main game';
  end if;
  if (select count(*) from side_games where group_code = p_code) >= 3 then
    raise exception 'three side games is plenty';
  end if;
  insert into side_games(group_code, appid, started_by) values (p_code, p_appid, m) on conflict do nothing;
  insert into side_players(group_code, appid, member_id) values (p_code, p_appid, m) on conflict do nothing;
end; $$;

create or replace function side_join(p_code text, p_device uuid, p_appid int, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if not exists (select 1 from side_games where group_code = p_code and appid = p_appid) then
    raise exception 'that side game has wrapped up';
  end if;
  if p_on then
    insert into side_players(group_code, appid, member_id) values (p_code, p_appid, m) on conflict do nothing;
  else
    delete from side_players where group_code = p_code and appid = p_appid and member_id = m;
  end if;
end; $$;

-- wrap a side game up: it lands in play history like any other game
create or replace function end_side_game(p_code text, p_device uuid, p_appid int, p_verdict text)
returns void language plpgsql security definer set search_path = public as $$
declare s side_games%rowtype; r int;
begin
  perform assert_member(p_code, p_device);
  if p_verdict is not null and p_verdict not in ('banger','fine','never_again') then
    raise exception 'unknown verdict';
  end if;
  select * into s from side_games where group_code = p_code and appid = p_appid;
  if not found then return; end if;
  select round_no into r from groups where code = p_code;
  insert into plays(group_code, appid, round_no, started_at, finished_at, verdict)
       values (p_code, p_appid, r, s.started_at, now(), p_verdict)
  on conflict (group_code, appid, round_no) do update
       set finished_at = now(), verdict = coalesce(excluded.verdict, plays.verdict);
  delete from side_games where group_code = p_code and appid = p_appid;
  delete from sesh_lock  where group_code = p_code and appid = p_appid;
  delete from sesh_free  where group_code = p_code and appid = p_appid;
  delete from sesh_none  where group_code = p_code and appid = p_appid;
end; $$;

revoke execute on function in_play(text, int) from public;
grant execute on function set_free(text, uuid, int, date[])          to anon;
grant execute on function set_none(text, uuid, int)                  to anon;
grant execute on function lock_sesh(text, uuid, int, date)           to anon;
grant execute on function unlock_sesh(text, uuid, int)               to anon;
grant execute on function resolve_sesh(text, uuid, int, boolean)     to anon;
grant execute on function set_sesh_rules(text, uuid, int, text)      to anon;
grant execute on function start_side_game(text, uuid, int)           to anon;
grant execute on function side_join(text, uuid, int, boolean)        to anon;
grant execute on function end_side_game(text, uuid, int, text)       to anon;

-- release state: Steam's coming-soon flag and the demo, alongside the date text
alter table games add column if not exists coming_soon boolean not null default false;
alter table games add column if not exists demo_appid  int;

-- ---------------------------------------------------------------------------
-- UNLINK OTHER DEVICES
-- Every browser that opens a crew as you is linked to you, so the count only
-- grows. This keeps the one you're on and unlinks the rest; they'll ask who
-- you are next time. Votes, takes and history belong to the person, not the
-- device, so nothing else changes.
-- ---------------------------------------------------------------------------
create or replace function unlink_other_devices(p_code text, p_device uuid)
returns int language plpgsql security definer set search_path = public as $$
declare m uuid; n int;
begin
  m := assert_member(p_code, p_device);
  delete from member_devices where group_code = p_code and member_id = m and device_id <> p_device;
  get diagnostics n = row_count;
  return n;
end; $$;
grant execute on function unlink_other_devices(text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- CREW COLOUR
-- The accent comes from the crew's emoji. It is worked out in the browser (the
-- server has no emoji font to draw with) and saved here, so every device shows
-- the same shade. tint_emoji records which emoji it was taken from: when the
-- emoji changes, the first member to open the crew works it out again.
-- tint_h = -1 means "this emoji has no real colour, use the default".
-- ---------------------------------------------------------------------------
alter table groups add column if not exists tint_h     int;
alter table groups add column if not exists tint_s     int;
alter table groups add column if not exists tint_emoji text;

create or replace function set_tint(p_code text, p_device uuid, p_emoji text, p_h int, p_s int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_member(p_code, p_device);
  if p_h is null or p_h < -1 or p_h > 359 or coalesce(p_s, 0) < 0 or coalesce(p_s, 0) > 100 then
    raise exception 'bad colour';
  end if;
  -- only if the emoji is still the one the colour was taken from
  update groups set tint_h = p_h, tint_s = coalesce(p_s, 0), tint_emoji = p_emoji
   where code = p_code and emoji = p_emoji;
end; $$;
grant execute on function set_tint(text, uuid, text, int, int) to anon;

-- ---------------------------------------------------------------------------
-- DISCORD SCOREBOARD
-- A crew can paste a channel webhook. The discord edge function posts one
-- scoreboard message there and edits it as things change, with a fresh post
-- for big moments. The webhook link is a secret: it never leaves the database
-- except to that function, and get_state only says whether one is set.
-- ---------------------------------------------------------------------------
alter table groups add column if not exists discord_hook text;
alter table groups add column if not exists discord_msg  text;   -- id of the live scoreboard message
alter table groups add column if not exists discord_sig  text;   -- what it last said, so unchanged edits are skipped

create or replace function set_discord(p_code text, p_device uuid, p_hook text)
returns boolean language plpgsql security definer set search_path = public as $$
declare h text := nullif(trim(coalesce(p_hook, '')), '');
begin
  perform assert_member(p_code, p_device);
  if h is not null and h !~ '^https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$' then
    raise exception 'That doesn''t look like a Discord webhook link';
  end if;
  update groups set discord_hook = h, discord_msg = null, discord_sig = null where code = p_code;
  return h is not null;
end; $$;
grant execute on function set_discord(text, uuid, text) to anon;

-- ---------------------------------------------------------------------------
-- WHO OWNS IT
-- Co-op's usual blocker is buying the thing. Each member ticks the games they
-- already own; the page works out what everyone could play tonight.
-- ---------------------------------------------------------------------------
create table if not exists owns (
  group_code text not null references groups(code) on delete cascade,
  appid      int  not null,
  member_id  uuid not null,
  primary key (group_code, appid, member_id)
);
alter table owns enable row level security;
revoke all on owns from anon, authenticated;

create or replace function set_owns(p_code text, p_device uuid, p_appids int[], p_own boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  m := assert_member(p_code, p_device);
  if coalesce(array_length(p_appids, 1), 0) > 200 then raise exception 'too many at once'; end if;
  if p_own then
    insert into owns(group_code, appid, member_id)
    select p_code, a, m from unnest(p_appids) a
    on conflict do nothing;
  else
    delete from owns where group_code = p_code and member_id = m and appid = any(p_appids);
  end if;
end; $$;
grant execute on function set_owns(text, uuid, int[], boolean) to anon;

-- ---------------------------------------------------------------------------
-- STEAM PRICES
-- Filled by the prices edge function (Steam has no CORS), at most every few
-- hours per game, in AUD. Shared across crews like the games table.
-- ---------------------------------------------------------------------------
create table if not exists prices (
  appid       int primary key,
  is_free     boolean not null default false,
  discount    int  not null default 0,          -- percent off, 0 when full price
  final_fmt   text,                             -- "$14.97", as Steam formats it
  initial_fmt text,                             -- "$29.95"
  fetched_at  timestamptz not null default now()
);
alter table prices enable row level security;
revoke all on prices from anon, authenticated;

-- ---------------------------------------------------------------------------
-- GAMES THAT AREN'T ON STEAM
-- Browser games (skribbl.io), Epic (Fortnite), consoles. They live in the same
-- games table under a negative appid, so votes, nights, owning and the
-- scoreboard all work unchanged. Each one belongs to the crew that made it.
-- fetched_at is 'infinity' so the Steam refresh never tries to re-fetch them.
-- ---------------------------------------------------------------------------
alter table games add column if not exists platform     text;     -- null = Steam; browser | epic | xbox | playstation | switch | other
alter table games add column if not exists play_url     text;     -- where to play it or buy it
alter table games add column if not exists is_free      boolean not null default false;
alter table games add column if not exists custom_group text;     -- the crew that added it, for custom games only
create sequence if not exists custom_game_seq;

create or replace function add_custom_game(
  p_code text, p_device uuid, p_name text, p_platform text, p_url text, p_free boolean,
  p_crew_max int default null, p_energy int default null
) returns int language plpgsql security definer set search_path = public as $$
declare m uuid; nm text; a int; who text; u text := nullif(trim(coalesce(p_url, '')), '');
begin
  m := assert_member(p_code, p_device);
  nm := trim(coalesce(p_name, ''));
  if length(nm) < 1 or length(nm) > 60 then raise exception 'give it a name (up to 60 characters)'; end if;
  if coalesce(p_platform, 'other') not in ('browser','epic','xbox','playstation','switch','other') then raise exception 'unknown platform'; end if;
  if u is not null and u !~* '^https?://[^\s]+$' then raise exception 'that link needs to start with https://'; end if;
  if p_crew_max is not null and (p_crew_max < 1 or p_crew_max > 200) then raise exception 'player cap looks wrong'; end if;
  if p_energy is not null and (p_energy < 1 or p_energy > 3) then raise exception 'energy must be 1, 2 or 3'; end if;
  if (select count(*) from shelf where group_code = p_code) >= 200 then
    raise exception 'this group already has 200 games, retire some first';
  end if;
  -- the same name in the same crew is the same game: put it back rather than doubling up
  select appid into a from games where custom_group = p_code and lower(name) = lower(nm) limit 1;
  if a is null then
    a := -nextval('custom_game_seq')::int;
    insert into games(appid, name, platform, play_url, is_free, custom_group, coop, online_coop, fetched_at)
    values (a, nm, coalesce(p_platform, 'other'), left(u, 300), coalesce(p_free, false), p_code, true, true, 'infinity');
  end if;
  select name into who from members where group_code = p_code and member_id = m;
  insert into shelf(group_code, appid, added_by, added_name, benched, energy, crew_max)
  values (p_code, a, m, who, false, p_energy, p_crew_max)
  on conflict (group_code, appid) do update set benched = false;
  return a;
end; $$;
grant execute on function add_custom_game(text, uuid, text, text, text, boolean, int, int) to anon;

-- fix a custom game's name, link, platform or price later
create or replace function update_custom_game(
  p_code text, p_device uuid, p_appid int, p_name text, p_platform text, p_url text, p_free boolean
) returns void language plpgsql security definer set search_path = public as $$
declare nm text := trim(coalesce(p_name, '')); u text := nullif(trim(coalesce(p_url, '')), '');
begin
  perform assert_member(p_code, p_device);
  if length(nm) < 1 or length(nm) > 60 then raise exception 'give it a name (up to 60 characters)'; end if;
  if coalesce(p_platform, 'other') not in ('browser','epic','xbox','playstation','switch','other') then raise exception 'unknown platform'; end if;
  if u is not null and u !~* '^https?://[^\s]+$' then raise exception 'that link needs to start with https://'; end if;
  update games set name = nm, platform = coalesce(p_platform, 'other'), play_url = left(u, 300), is_free = coalesce(p_free, false)
   where appid = p_appid and custom_group = p_code;
  if not found then raise exception 'that game is not one this crew added'; end if;
end; $$;
grant execute on function update_custom_game(text, uuid, int, text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- LINK ANOTHER DEVICE
-- There are no accounts, so "you" is a browser. To bring your phone and your
-- laptop together, the device you're already on asks for a short code (valid
-- ten minutes, one use). Typing it on the other device links it to you in
-- every crew at once and hands back the list of crews.
-- ---------------------------------------------------------------------------
create table if not exists device_pairs (
  code       text primary key,
  device_id  uuid not null,
  created_at timestamptz not null default now()
);
alter table device_pairs enable row level security;
revoke all on device_pairs from anon, authenticated;

create or replace function start_pairing(p_device uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0;
begin
  if not exists (select 1 from member_devices where device_id = p_device) then
    raise exception 'join a crew on this device first';
  end if;
  delete from device_pairs where device_id = p_device or created_at < now() - interval '10 minutes';
  loop
    c := left(make_code(), 6);
    exit when not exists (select 1 from device_pairs where code = c);
    tries := tries + 1; if tries > 20 then raise exception 'try again'; end if;
  end loop;
  insert into device_pairs(code, device_id) values (c, p_device);
  return c;
end; $$;
grant execute on function start_pairing(uuid) to anon;

create or replace function finish_pairing(p_pair text, p_device uuid)
returns json language plpgsql security definer set search_path = public as $$
declare src uuid; c text := upper(regexp_replace(coalesce(p_pair, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  select device_id into src from device_pairs where code = c and created_at > now() - interval '10 minutes';
  if src is null then raise exception 'that code has run out or was mistyped, get a fresh one'; end if;
  if src = p_device then raise exception 'that code is for a different device'; end if;
  delete from device_pairs where code = c;
  -- same person in every crew the other device is in; a crew this device already
  -- belongs to keeps whoever it already is there
  insert into member_devices(group_code, device_id, member_id)
  select group_code, p_device, member_id from member_devices where device_id = src
  on conflict (group_code, device_id) do nothing;
  return coalesce((
    select json_agg(json_build_object('code', g.code, 'name', g.name, 'emoji', g.emoji, 'me', m.name) order by g.name)
      from member_devices d join groups g on g.code = d.group_code
      join members m on m.group_code = d.group_code and m.member_id = d.member_id
     where d.device_id = p_device), '[]'::json);
end; $$;
grant execute on function finish_pairing(text, uuid) to anon;
