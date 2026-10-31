-- Guidance voice and app language follow the account like other preferences.
-- Apply after profile_names. Older clients omit both fields, so an upload from
-- them keeps the stored values instead of resetting them.
begin;
alter table public.user_preferences
  add column voice_guidance boolean not null default false,
  add column app_language text not null default 'system'
    check (app_language in ('system', 'en', 'zh'));

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
  insert into public.user_preferences(user_id, avoid_highways, avoid_tolls, avoid_ferries,
    avoid_tunnels, map_style, show_traffic, voice_guidance, app_language) values (
    uid, coalesce((prefs->>'avoid_highways')::boolean, false),
    coalesce((prefs->>'avoid_tolls')::boolean, false),
    coalesce((prefs->>'avoid_ferries')::boolean, false),
    coalesce((prefs->>'avoid_tunnels')::boolean, false),
    coalesce(prefs->>'map_style', 'standard'), coalesce((prefs->>'show_traffic')::boolean, false),
    coalesce((prefs->>'voice_guidance')::boolean, false),
    coalesce(prefs->>'app_language', 'system')
  ) on conflict(user_id) do update set
    avoid_highways = excluded.avoid_highways, avoid_tolls = excluded.avoid_tolls,
    avoid_ferries = excluded.avoid_ferries, avoid_tunnels = excluded.avoid_tunnels,
    map_style = excluded.map_style, show_traffic = excluded.show_traffic,
    voice_guidance = coalesce((prefs->>'voice_guidance')::boolean, user_preferences.voice_guidance),
    app_language = coalesce(prefs->>'app_language', user_preferences.app_language);
  delete from public.saved_places where user_id = uid;
  insert into public.saved_places(user_id, slot, name, address, latitude, longitude)
    select uid, x->>'slot', x->>'name', coalesce(x->>'address', ''),
      (x->>'latitude')::double precision, (x->>'longitude')::double precision
    from jsonb_array_elements(places) x;
  return current_revision + 1;
end;
$$;
commit;
