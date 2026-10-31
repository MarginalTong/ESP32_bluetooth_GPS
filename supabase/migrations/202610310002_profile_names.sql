-- Nicknames are separate from manual address/preference snapshots.
begin;

alter table public.profiles add column name_revision bigint not null default 0
  check (name_revision >= 0);
alter table public.profiles alter column display_name set default
  ('NAVIO_' || upper(substr(replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 8)));

-- Generate once, on the server, including email/Apple/Google registrations.
-- No name is derived from an email, real name or stable public user ID.
create function public.navio_create_user_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(user_id) values(new.id) on conflict do nothing;
  return new;
end;
$$;
revoke all on function public.navio_create_user_profile() from public, anon, authenticated;
create trigger navio_create_user_profile after insert on auth.users
  for each row execute function public.navio_create_user_profile();

-- Existing users retain their chosen names; only missing/blank names change.
insert into public.profiles(user_id) select id from auth.users on conflict do nothing;
update public.profiles set display_name = default where btrim(display_name) = '';

create function public.navio_get_profile(p_expected_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); result jsonb;
begin
  if uid is null or uid is distinct from p_expected_user then
    raise exception 'Account changed' using errcode = '42501';
  end if;
  insert into public.profiles(user_id) values(uid) on conflict do nothing;
  select jsonb_build_object('display_name', display_name, 'name_revision', name_revision)
    into result from public.profiles where user_id = uid;
  return result;
end;
$$;

create function public.navio_set_display_name(
  p_expected_user uuid, p_display_name text, p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); current_name text; current_version bigint;
begin
  if uid is null or uid is distinct from p_expected_user then
    raise exception 'Account changed' using errcode = '42501';
  end if;
  if p_display_name is null or char_length(p_display_name) not between 1 and 32
    or octet_length(p_display_name) > 256 or btrim(p_display_name) <> p_display_name
    or p_display_name ~ '[[:cntrl:]]'
    or p_display_name ~ U&'[\200E\200F\202A-\202E\2066-\2069]'
    or p_expected_revision is null or p_expected_revision < 0 then
    raise exception 'Invalid nickname' using errcode = '22023';
  end if;
  insert into public.profiles(user_id) values(uid) on conflict do nothing;
  select display_name, name_revision into current_name, current_version
    from public.profiles where user_id = uid for update;
  -- Retrying after a lost response is safe if the desired name is already set.
  if current_name = p_display_name and p_expected_revision <= current_version then
    return jsonb_build_object('display_name', current_name, 'name_revision', current_version);
  end if;
  if current_version <> p_expected_revision then
    raise exception 'Nickname changed on another device' using errcode = 'PT409';
  end if;
  update public.profiles set display_name = p_display_name,
    name_revision = name_revision + 1, updated_at = now() where user_id = uid;
  return jsonb_build_object('display_name', p_display_name, 'name_revision', current_version + 1);
end;
$$;
revoke all on function public.navio_get_profile(uuid) from public, anon;
revoke all on function public.navio_set_display_name(uuid, text, bigint) from public, anon;
grant execute on function public.navio_get_profile(uuid) to authenticated;
grant execute on function public.navio_set_display_name(uuid, text, bigint) to authenticated;

-- Older clients still upload whole snapshots. Ignore that obsolete nickname
-- field so a later address upload cannot silently undo a profile edit.
create or replace function public.navio_save_account_data(payload jsonb, expected_revision bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  current_revision bigint;
  prefs jsonb := payload->'preferences';
  places jsonb := payload->'places';
begin
  if uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if expected_revision is null or expected_revision < 0 or payload is null
      or jsonb_typeof(payload) <> 'object' or octet_length(payload::text) > 16384
      or jsonb_typeof(prefs) is distinct from 'object'
      or jsonb_typeof(places) is distinct from 'array' then
    raise exception 'Invalid account data' using errcode = '22023';
  end if;
  if jsonb_array_length(places) > 3 then
    raise exception 'Too many saved places' using errcode = '22023';
  end if;
  insert into public.profiles(user_id) values(uid) on conflict do nothing;
  select revision into current_revision from public.profiles where user_id = uid for update;
  if current_revision <> expected_revision then
    raise exception 'Cloud data changed; restore it before uploading again' using errcode = 'PT409';
  end if;
  update public.profiles set revision = revision + 1, updated_at = now() where user_id = uid;
  insert into public.user_preferences values (
    uid, coalesce((prefs->>'avoid_highways')::boolean, false),
    coalesce((prefs->>'avoid_tolls')::boolean, false),
    coalesce((prefs->>'avoid_ferries')::boolean, false),
    coalesce((prefs->>'avoid_tunnels')::boolean, false),
    coalesce(prefs->>'map_style', 'standard'), coalesce((prefs->>'show_traffic')::boolean, false)
  ) on conflict(user_id) do update set
    avoid_highways = excluded.avoid_highways, avoid_tolls = excluded.avoid_tolls,
    avoid_ferries = excluded.avoid_ferries, avoid_tunnels = excluded.avoid_tunnels,
    map_style = excluded.map_style, show_traffic = excluded.show_traffic;
  delete from public.saved_places where user_id = uid;
  insert into public.saved_places(user_id, slot, name, address, latitude, longitude)
    select uid, x->>'slot', x->>'name', coalesce(x->>'address', ''),
      (x->>'latitude')::double precision, (x->>'longitude')::double precision
    from jsonb_array_elements(places) x;
  return current_revision + 1;
end;
$$;
commit;
