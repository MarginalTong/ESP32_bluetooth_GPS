-- NAVIO account data. No routes, GPS history or BLE signing keys belong here.
begin;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (length(display_name) <= 80),
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now()
);
create table public.user_preferences (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  avoid_highways boolean not null default false,
  avoid_tolls boolean not null default false,
  avoid_ferries boolean not null default false,
  avoid_tunnels boolean not null default false,
  map_style text not null default 'standard'
    check (map_style in ('standard', 'standard_dark', 'hybrid', 'satellite')),
  show_traffic boolean not null default false
);
create table public.saved_places (
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  slot text not null check (slot in ('home', 'work', 'school')),
  name text not null check (length(name) between 1 and 200),
  address text not null default '' check (length(address) <= 500),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  primary key (user_id, slot)
);
-- Apple refresh tokens are encrypted by the Edge Function with a key held in
-- function secrets, not in this database or the mobile app.
create table public.account_apple_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  encrypted_token text not null,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.user_preferences enable row level security;
alter table public.saved_places enable row level security;
alter table public.account_apple_grants enable row level security;
revoke all on public.profiles, public.user_preferences, public.saved_places,
  public.account_apple_grants from anon, authenticated;
grant select on public.profiles, public.user_preferences, public.saved_places to authenticated;
grant all on public.account_apple_grants to service_role;
create policy own_profile on public.profiles for select to authenticated
  using ((select auth.uid()) = user_id);
create policy own_preferences on public.user_preferences for select to authenticated
  using ((select auth.uid()) = user_id);
create policy own_places on public.saved_places for select to authenticated
  using ((select auth.uid()) = user_id);

-- One statement gives a consistent snapshot of the three tables.
create function public.navio_get_account_data() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'revision', coalesce((select revision from public.profiles where user_id = auth.uid()), 0),
    'display_name', coalesce((select display_name from public.profiles where user_id = auth.uid()), ''),
    'preferences', coalesce((select to_jsonb(p) - 'user_id' from public.user_preferences p
      where user_id = auth.uid()), '{}'::jsonb),
    'places', coalesce((select jsonb_agg(to_jsonb(s) - 'user_id' order by slot)
      from public.saved_places s where user_id = auth.uid()), '[]'::jsonb)
  ) where auth.uid() is not null;
$$;

-- All writes are atomic and identity is taken from the verified session, never
-- a client-supplied user_id. Revision checking prevents silent cross-device loss.
create function public.navio_save_account_data(payload jsonb, expected_revision bigint)
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
  update public.profiles set display_name = coalesce(payload->>'display_name', ''),
    revision = revision + 1, updated_at = now() where user_id = uid;
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

-- Email-only accounts can be deleted transactionally without any admin key in
-- the app. Apple-linked accounts must go through account-actions, which first
-- revokes Apple's grant. Never allow an RPC to bypass provider revocation.
create function public.navio_delete_email_account(confirmation text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if confirmation is distinct from 'DELETE' then
    raise exception 'Explicit confirmation required' using errcode = '22023';
  end if;
  if exists(select 1 from auth.identities where user_id = uid and provider = 'apple') then
    raise exception 'Apple revocation required' using errcode = 'PT409';
  end if;
  delete from auth.users where id = uid;
  if not found then raise exception 'Account unavailable' using errcode = '28000'; end if;
end;
$$;

revoke all on function public.navio_get_account_data() from public, anon;
revoke all on function public.navio_save_account_data(jsonb, bigint) from public, anon;
revoke all on function public.navio_delete_email_account(text) from public, anon;
grant execute on function public.navio_get_account_data() to authenticated;
grant execute on function public.navio_save_account_data(jsonb, bigint) to authenticated;
grant execute on function public.navio_delete_email_account(text) to authenticated;
commit;
