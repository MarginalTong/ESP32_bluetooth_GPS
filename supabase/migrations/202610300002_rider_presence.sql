-- Opt-in, navigation-only presence. No direct client table access or history.
begin;
create table public.rider_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  session_id uuid not null default gen_random_uuid(),
  public_id uuid not null default gen_random_uuid(),
  latitude numeric(7,3), longitude numeric(7,3),
  sequence bigint not null default -1,
  updated_at timestamptz not null default '-infinity',
  expires_at timestamptz not null default (now() + interval '30 seconds')
);
alter table public.rider_presence enable row level security;
revoke all on public.rider_presence from public, anon, authenticated;

create function public.navio_begin_rider_sharing() returns uuid
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); token uuid := gen_random_uuid();
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  insert into public.rider_presence(user_id, session_id) values(actor, token)
  on conflict(user_id) do update set session_id = token, public_id = gen_random_uuid(),
    latitude = null, longitude = null, sequence = -1, updated_at = '-infinity',
    expires_at = now() + interval '30 seconds';
  return token;
end $$;

create function public.navio_stop_rider_sharing(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  delete from public.rider_presence where user_id = auth.uid() and session_id = p_session;
end $$;

create function public.navio_publish_rider_position(p_session uuid, p_sequence bigint,
  p_latitude double precision, p_longitude double precision,
  p_accuracy double precision, p_fix_at timestamptz) returns boolean
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); changed integer;
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_session is null or p_sequence is null or p_sequence < 0 or
     p_latitude is null or not (p_latitude between -34.15 and -33.50) or
     p_longitude is null or not (p_longitude between 150.50 and 151.45) or
     p_accuracy is null or not (p_accuracy between 0 and 50) or
     p_fix_at is null or p_fix_at < now() - interval '10 seconds' or
     p_fix_at > now() + interval '5 seconds' then
    return false;
  end if;
  -- Round BEFORE storage: roughly 100 m grid, never precise coordinates.
  -- The session and sequence guards stop delayed/replayed writes resurrecting
  -- a withdrawn position or overwriting a newer location.
  update public.rider_presence set latitude = round(p_latitude::numeric, 3),
    longitude = round(p_longitude::numeric, 3), sequence = p_sequence,
    updated_at = now(), expires_at = now() + interval '30 seconds'
  where user_id = actor and session_id = p_session and sequence < p_sequence
    and updated_at <= now() - interval '4 seconds';
  get diagnostics changed = row_count;
  return changed = 1;
end $$;

create function public.navio_list_riders() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb; count_all integer;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  -- Opportunistic cleanup; visibility also has its own expiry check. No
  -- background cleanup job is required to hide an abandoned position.
  delete from public.rider_presence where expires_at <= now();
  select count(*) into count_all from public.rider_presence
    where latitude is not null and user_id <> auth.uid() and expires_at > now();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', public_id, 'latitude', latitude, 'longitude', longitude,
    'expires_at', expires_at, 'updated_at', updated_at)), '[]'::jsonb)
    into result from (select public_id, latitude, longitude, expires_at, updated_at
      from public.rider_presence where latitude is not null and user_id <> auth.uid()
        and expires_at > now() order by updated_at desc, public_id limit 500) visible;
  return jsonb_build_object('riders', result, 'truncated', count_all > 500);
end $$;

revoke all on function public.navio_begin_rider_sharing() from public, anon;
revoke all on function public.navio_stop_rider_sharing(uuid) from public, anon;
revoke all on function public.navio_publish_rider_position(uuid,bigint,double precision,double precision,double precision,timestamptz) from public, anon;
revoke all on function public.navio_list_riders() from public, anon;
grant execute on function public.navio_begin_rider_sharing() to authenticated;
grant execute on function public.navio_stop_rider_sharing(uuid) to authenticated;
grant execute on function public.navio_publish_rider_position(uuid,bigint,double precision,double precision,double precision,timestamptz) to authenticated;
grant execute on function public.navio_list_riders() to authenticated;
commit;
