import {before, after, test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
let db;
const watchdog = setTimeout(() => { console.error('Settings database timeout'); process.exit(1); }, 45000);
const a = '10000000-0000-4000-8000-000000000001';
const migration = name => readFile(new URL(`../migrations/${name}.sql`, import.meta.url), 'utf8');
before(async () => {
  db = new PGlite();
  await db.waitReady;
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.identities(user_id uuid references auth.users(id) on delete cascade, provider text);
    create function auth.uid() returns uuid language sql stable as
      $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth, public to anon, authenticated, service_role;
    insert into auth.users values('${a}');`);
  for (const name of ['202610300001_accounts', '202610310002_profile_names',
    '202610310003_automatic_settings_sync']) await db.exec(await migration(name));
  // Rows saved before this migration must survive it.
  await as(a, 'select public.navio_save_account_data($1::jsonb,0)', [JSON.stringify({
    preferences: {map_style: 'hybrid', avoid_tolls: true}, places: [],
  })]);
  await db.exec(await migration('202610310004_voice_language_settings'));
});
after(async () => { try { await db?.close(); } finally { clearTimeout(watchdog); } });
async function as(id, query, args = []) {
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
  await db.exec('set role authenticated');
  try { return (await db.query(query, args)).rows; } finally { await db.exec('reset role'); }
}
const read = async () => (await as(a, 'select public.navio_get_account_data() data'))[0].data;
const sync = (preferences, revision) => as(a,
  'select public.navio_sync_settings($1,$2::jsonb,$3) r',
  [a, JSON.stringify({preferences, places: []}), revision]);

test('existing preferences keep their values and get the defaults', async () => {
  const {preferences} = await read();
  assert.equal(preferences.map_style, 'hybrid');
  assert.equal(preferences.avoid_tolls, true);
  assert.equal(preferences.voice_guidance, false);
  assert.equal(preferences.app_language, 'system');
});
test('voice and language round-trip through the sync entry point', async () => {
  await sync({voice_guidance: true, app_language: 'zh'}, (await read()).revision);
  const {preferences} = await read();
  assert.equal(preferences.voice_guidance, true);
  assert.equal(preferences.app_language, 'zh');
});
test('an older client that omits both fields cannot reset them', async () => {
  await sync({map_style: 'standard'}, (await read()).revision);
  const {preferences} = await read();
  assert.equal(preferences.map_style, 'standard');
  assert.equal(preferences.voice_guidance, true);
  assert.equal(preferences.app_language, 'zh');
});
test('an unknown language is rejected', async () => {
  const before = await read();
  await assert.rejects(() => sync({app_language: 'fr'}, before.revision));
  assert.deepEqual(await read(), before);
});
