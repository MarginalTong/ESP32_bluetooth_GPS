import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// Fail a hung database fixture instead of leaving CI running indefinitely.
const watchdog = setTimeout(() => { console.error('Database test timeout'); process.exit(1); }, 45000);
// Keep the event loop alive while PostgreSQL's WASM module initializes.

let db;
const a = '10000000-0000-4000-8000-000000000001';
const b = '10000000-0000-4000-8000-000000000002';
const payload = {
  display_name: 'Test rider', preferences: { map_style: 'standard_dark' },
  places: [{slot: 'home', name: 'Synthetic home', address: '', latitude: -33, longitude: 151}],
};
before(async () => {
  db = new PGlite();
  console.info('Initializing PostgreSQL test fixture');
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth;
    create table auth.users(id uuid primary key);
    create table auth.identities(user_id uuid references auth.users(id) on delete cascade, provider text);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    grant usage on schema auth, public to anon, authenticated, service_role;
    grant execute on function auth.uid() to anon, authenticated, service_role;
    insert into auth.users values ('${a}'), ('${b}');
  `);
  console.info('Applying account migration');
  await db.exec(await readFile(new URL('../migrations/202610300001_accounts.sql', import.meta.url), 'utf8'));
  console.info('Account migration ready');
});
after(async () => { try { await db?.close(); } finally { clearTimeout(watchdog); } });
async function user(id, fn, role = 'authenticated') {
  await db.exec('begin');
  try {
    await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [id]);
    await db.exec('set local role ' + role);
    await fn();
  } finally { await db.exec('rollback'); }
}
async function save(data = payload, revision = 0) {
  return (await db.query('select public.navio_save_account_data($1::jsonb, $2) as revision',
    [JSON.stringify(data), revision])).rows[0].revision;
}
async function get() {
  return (await db.query('select public.navio_get_account_data() as data')).rows[0].data;
}
async function rejects(fn, code) {
  await db.exec('savepoint rejected_request');
  try { await assert.rejects(fn, e => e.code === code); }
  finally { await db.exec('rollback to savepoint rejected_request'); }
}
test('anonymous requests cannot read tables or invoke account RPCs', async () => {
  await user('', async () => {
    await rejects(() => db.query('select * from public.saved_places'), '42501');
    await rejects(() => db.query('select public.navio_get_account_data()'), '42501');
    await rejects(() => save(), '42501');
  }, 'anon');
});
test('a verified user gets defaults, then an atomic versioned snapshot', async () => {
  await user(a, async () => {
    assert.equal((await get()).revision, 0);
    assert.equal(Number(await save()), 1);
    const data = await get();
    assert.equal(data.revision, 1);
    assert.equal(data.display_name, 'Test rider');
    assert.equal(data.preferences.map_style, 'standard_dark');
    assert.equal(data.places[0].slot, 'home');
  });
});
test('RLS isolates users and ignores a forged payload user_id', async () => {
  await user(a, async () => {
    await save({...payload, user_id: b});
    await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [b]);
    assert.equal((await db.query('select * from public.profiles')).rows.length, 0);
    assert.equal((await db.query('select * from public.saved_places')).rows.length, 0);
    assert.equal((await get()).revision, 0);
    await save({...payload, display_name: 'Second user'});
    assert.equal((await db.query('select * from public.profiles')).rows.length, 1);
    await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [a]);
    assert.equal((await get()).display_name, 'Test rider');
  });
});
test('authenticated clients cannot bypass the atomic write RPC or read Apple grants', async () => {
  await user(a, async () => {
    await rejects(() => db.query('insert into public.profiles(user_id) values ($1)', [b]), '42501');
    await rejects(() => db.query('select * from public.account_apple_grants'), '42501');
  });
});
test('stale revisions fail without replacing cloud data', async () => {
  await user(a, async () => {
    await save();
    await rejects(() => save({...payload, display_name: 'Stale client'}, 0), 'PT409');
    assert.equal((await get()).display_name, 'Test rider');
    assert.equal(Number(await save({...payload, display_name: 'New version'}, 1)), 2);
    await rejects(() => save(payload, 1), 'PT409');
  });
});
test('invalid coordinates and duplicate slots roll back the entire upload', async () => {
  await user(a, async () => {
    await save();
    await rejects(() => save({...payload, places: [{...payload.places[0], latitude: 91}]}, 1), '23514');
    await rejects(() => save({...payload, places: [payload.places[0], payload.places[0]]}, 1), '23505');
    assert.equal((await get()).revision, 1);
    assert.equal((await get()).places.length, 1);
  });
});
test('explicit account deletion cascades only the caller data and denies stale JWT writes', async () => {
  await user(a, async () => {
    await save();
    await rejects(() => db.query(`select public.navio_delete_email_account('wrong')`), '22023');
    await db.query(`select public.navio_delete_email_account('DELETE')`);
    assert.equal((await get()).places.length, 0);
    await rejects(() => save(), '23503');
    await db.exec('reset role');
    assert.equal((await db.query('select id from auth.users where id = $1', [a])).rows.length, 0);
    assert.equal((await db.query('select id from auth.users where id = $1', [b])).rows.length, 1);
  });
});
test('Apple-linked accounts cannot bypass provider token revocation', async () => {
  await user(a, async () => {
    await db.exec('reset role');
    await db.query(`insert into auth.identities values ($1, 'apple')`, [a]);
    await db.exec('set local role authenticated');
    await rejects(() => db.query(`select public.navio_delete_email_account('DELETE')`), 'PT409');
  });
});
