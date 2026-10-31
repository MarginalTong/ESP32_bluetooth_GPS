import {before, after, test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
let db;
const watchdog = setTimeout(() => { console.error('Profile database timeout'); process.exit(1); }, 45000);
const a = '10000000-0000-4000-8000-000000000001';
const b = '10000000-0000-4000-8000-000000000002';
const c = '10000000-0000-4000-8000-000000000003';
before(async () => {
  db = new PGlite();
  await db.waitReady;
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create role supabase_auth_admin;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.identities(user_id uuid references auth.users(id) on delete cascade, provider text);
    create function auth.uid() returns uuid language sql stable as
      $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth, public to anon, authenticated, service_role;
    grant usage on schema auth to supabase_auth_admin;
    grant insert on auth.users to supabase_auth_admin;
    insert into auth.users values('${a}'), ('${b}');`);
  await db.exec(await readFile(new URL('../migrations/202610300001_accounts.sql', import.meta.url), 'utf8'));
  await db.query('insert into public.profiles(user_id,display_name) values($1,$2)', [a, 'Existing rider']);
  await db.exec(await readFile(new URL('../migrations/202610310002_profile_names.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../migrations/202610310003_automatic_settings_sync.sql', import.meta.url), 'utf8'));
});
after(async () => { try { await db?.close(); } finally { clearTimeout(watchdog); } });
async function as(id, query, args = []) {
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
  await db.exec('set role ' + (id ? 'authenticated' : 'anon'));
  try { return (await db.query(query, args)).rows; } finally { await db.exec('reset role'); }
}
async function get(id = a, expected = id) { return (await as(id, 'select public.navio_get_profile($1) data', [expected]))[0].data; }
async function set(name, version, id = a, expected = id) { return (await as(id, 'select public.navio_set_display_name($1,$2,$3) data', [expected, name, version]))[0].data; }
test('existing names survive; missing and new users get stable random names', async () => {
  assert.equal((await get()).display_name, 'Existing rider');
  const old = await get(b);
  assert.match(old.display_name, /^NAVIO_[A-F0-9]{8}$/);
  assert.deepEqual(await get(b), old);
  await db.exec('set role supabase_auth_admin');
  try { await db.query('insert into auth.users values($1)', [c]); }
  finally { await db.exec('reset role'); }
  const row = (await db.query('select display_name from public.profiles where user_id=$1', [c])).rows[0];
  assert.match(row.display_name, /^NAVIO_[A-F0-9]{8}$/);
  assert.equal((await get(c)).display_name, row.display_name);
});
test('anonymous, forged account and direct writes cannot change names', async () => {
  await assert.rejects(() => get('', a), e => e.code === '42501');
  await assert.rejects(() => set('Fake', 0, '', a), e => e.code === '42501');
  await assert.rejects(() => get(b, a), e => e.code === '42501');
  await assert.rejects(() => set('Fake', 0, b, a), e => e.code === '42501');
  await assert.rejects(() => as(a, 'update public.profiles set display_name=$1', ['Fake']), e => e.code === '42501');
  assert.equal((await get()).display_name, 'Existing rider');
});
test('versioned edits, stale requests and lost-response retries are safe', async () => {
  assert.deepEqual(await set('Sydney rider', 0), {display_name: 'Sydney rider', name_revision: 1});
  assert.deepEqual(await set('Sydney rider', 0), {display_name: 'Sydney rider', name_revision: 1});
  await assert.rejects(() => set('Stale rider', 0), e => e.code === 'PT409');
  assert.equal((await get()).display_name, 'Sydney rider');
});
test('invalid names leave profile unchanged; Chinese and emoji work', async () => {
  for (const name of ['', ' ', ' a', 'a ', 'x'.repeat(33), 'line\nbreak', 'a\u0001b', 'a\u202eb', null]) {
    await assert.rejects(() => set(name, 1), e => e.code === '22023');
  }
  assert.deepEqual(await set('悉尼骑友 🏍️', 1), {display_name: '悉尼骑友 🏍️', name_revision: 2});
});
test('manual settings uploads cannot erase nicknames or invalidate name versions', async () => {
  const before = await get();
  await as(a, 'select public.navio_save_account_data($1::jsonb,0)', [JSON.stringify({
    display_name: '', preferences: {map_style: 'hybrid'}, places: [],
  })]);
  assert.deepEqual(await get(), before);
  const snapshot = (await as(a, 'select public.navio_get_account_data() data'))[0].data;
  assert.equal(snapshot.display_name, before.display_name);
  assert.equal(snapshot.preferences.map_style, 'hybrid');
  assert.equal(snapshot.revision, 1);
  await assert.rejects(() => as(a, 'select public.navio_save_account_data($1::jsonb,0)', [JSON.stringify({preferences: {}, places: []})]), e => e.code === 'PT409');
});
test('deleted accounts cannot recreate profiles using a stale session', async () => {
  await db.query('delete from auth.users where id=$1', [c]);
  await assert.rejects(() => get(c), e => e.code === '23503');
  await assert.rejects(() => set('Ghost', 0, c), e => e.code === '23503');
});
test('automatic sync rejects anonymous and switched-account requests', async () => {
  const data = JSON.stringify({display_name: '', preferences: {}, places: []});
  await assert.rejects(() => as('', 'select public.navio_sync_settings($1,$2::jsonb,1)', [a,data]), e => e.code === '42501');
  await assert.rejects(() => as(b, 'select public.navio_sync_settings($1,$2::jsonb,1)', [a,data]), e => e.code === '42501');
  assert.equal((await as(a,'select public.navio_get_account_data() data'))[0].data.revision, 1);
});
test('automatic sync keeps revision protection and never changes the profile name', async () => {
  const before = await get();
  const data = JSON.stringify({display_name: 'Stale cached name', preferences: {map_style: 'satellite'}, places: []});
  const result = (await as(a, 'select public.navio_sync_settings($1,$2::jsonb,1) revision', [a,data]))[0];
  assert.equal(Number(result.revision), 2);
  assert.deepEqual(await get(), before);
  await assert.rejects(() => as(a, 'select public.navio_sync_settings($1,$2::jsonb,1)', [a,data]), e => e.code === 'PT409');
});
