-- Small, private profile thumbnails. No public object URLs or original photos.
-- Apply after accounts + rider_presence migrations. Existing clients ignore the
-- new optional avatar_id field; the existing sharing/session guards are kept.
begin;
create table public.profile_avatars (
  user_id uuid primary key references auth.users(id) on delete cascade,
  avatar_id uuid not null default gen_random_uuid(),
  jpeg bytea not null check (octet_length(jpeg) between 4 and 32768),
  updated_at timestamptz not null default now()
);
alter table public.profile_avatars enable row level security;
revoke all on public.profile_avatars from public, anon, authenticated;

create function public.navio_get_profile_avatar() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); result jsonb;
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select jsonb_build_object('id', avatar_id,
    'jpeg_base64', replace(encode(jpeg, 'base64'), E'\n', '')) into result
    from public.profile_avatars where user_id = actor;
  return result;
end $$;

create function public.navio_set_profile_avatar(p_expected_user uuid, p_jpeg_base64 text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); data bytea; version uuid := gen_random_uuid();
begin
  if actor is null or actor is distinct from p_expected_user then
    raise exception 'Account changed' using errcode = '42501';
  end if;
  -- Bound BEFORE decoding, then validate type and decoded size. Pixel dimension
  -- bounds and re-encoding are also enforced by the app before native display.
  if p_jpeg_base64 is null or octet_length(p_jpeg_base64) > 43692 then
    raise exception 'Invalid avatar' using errcode = '22023';
  end if;
  data := decode(p_jpeg_base64, 'base64');
  if octet_length(data) not between 4 and 32768 or
      substring(data from 1 for 3) <> decode('ffd8ff','hex') or
      substring(data from octet_length(data)-1 for 2) <> decode('ffd9','hex') then
    raise exception 'Invalid JPEG avatar' using errcode = '22023';
  end if;
  insert into public.profile_avatars(user_id, avatar_id, jpeg) values(actor, version, data)
  on conflict(user_id) do update set avatar_id = version, jpeg = data, updated_at = now();
  return version;
end $$;

create function public.navio_remove_profile_avatar(p_expected_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() is distinct from p_expected_user then
    raise exception 'Account changed' using errcode = '42501';
  end if;
  delete from public.profile_avatars where user_id = auth.uid();
end $$;

-- Share a thumbnail only while the matching rotating presence is visible.
-- Neither the private account UUID nor a permanent avatar URL is returned.
create function public.navio_get_rider_avatar(p_public_id uuid, p_avatar_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare result text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select replace(encode(a.jpeg, 'base64'), E'\n', '') into result
  from public.profile_avatars a join public.rider_presence r on r.user_id = a.user_id
  where r.public_id = p_public_id
    and md5(r.public_id::text || ':' || a.avatar_id::text)::uuid = p_avatar_id
    and r.latitude is not null and r.expires_at > now();
  return result;
end $$;

create or replace function public.navio_list_riders() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb; count_all integer;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  delete from public.rider_presence where expires_at <= now();
  select count(*) into count_all from public.rider_presence
    where latitude is not null and user_id <> auth.uid() and expires_at > now();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', public_id, 'latitude', latitude, 'longitude', longitude,
    'expires_at', expires_at, 'updated_at', updated_at, 'avatar_id', avatar_id)), '[]'::jsonb)
  into result from (select r.public_id, r.latitude, r.longitude, r.expires_at,
      r.updated_at, md5(r.public_id::text || ':' || a.avatar_id::text)::uuid as avatar_id
    from public.rider_presence r left join public.profile_avatars a on a.user_id = r.user_id
    where r.latitude is not null and r.user_id <> auth.uid() and r.expires_at > now()
    order by r.updated_at desc, r.public_id limit 500) visible;
  return jsonb_build_object('riders', result, 'truncated', count_all > 500);
end $$;

revoke all on function public.navio_get_profile_avatar() from public, anon;
revoke all on function public.navio_set_profile_avatar(uuid,text) from public, anon;
revoke all on function public.navio_remove_profile_avatar(uuid) from public, anon;
revoke all on function public.navio_get_rider_avatar(uuid,uuid) from public, anon;
grant execute on function public.navio_get_profile_avatar() to authenticated;
grant execute on function public.navio_set_profile_avatar(uuid,text) to authenticated;
grant execute on function public.navio_remove_profile_avatar(uuid) to authenticated;
grant execute on function public.navio_get_rider_avatar(uuid,uuid) to authenticated;
commit;
