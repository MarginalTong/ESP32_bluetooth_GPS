-- Bind queued automatic writes to the account that produced the settings.
-- Keep the legacy snapshot RPC for older clients, but new clients use this
-- session-checked entry point to prevent a late write after account switching.
begin;
create function public.navio_sync_settings(
  p_expected_user uuid, payload jsonb, expected_revision bigint
) returns bigint language plpgsql security invoker set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() is distinct from p_expected_user then
    raise exception 'Account changed' using errcode = '42501';
  end if;
  return public.navio_save_account_data(payload, expected_revision);
end;
$$;
revoke all on function public.navio_sync_settings(uuid, jsonb, bigint) from public, anon;
grant execute on function public.navio_sync_settings(uuid, jsonb, bigint) to authenticated;
commit;
