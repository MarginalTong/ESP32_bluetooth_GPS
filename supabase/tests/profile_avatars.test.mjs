import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
let db;
const watchdog=setTimeout(()=>{console.error('Avatar database test timed out');process.exit(1);},45000);
watchdog.unref();
const a='10000000-0000-4000-8000-000000000001', b='10000000-0000-4000-8000-000000000002';
// Structural JPEG sentinel; image decoding/dimension tests live in Flutter.
const photo=Buffer.from('ffd8ff00112233ffd9','hex').toString('base64');
before(async()=>{
 db=new PGlite();
 await db.exec(`create role anon; create role authenticated;
 create schema auth; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth,public to anon,authenticated;
 insert into auth.users values('${a}'),('${b}');`);
 for(const migration of ['202610300002_rider_presence.sql','202610310001_profile_avatars.sql']){
   await db.exec(await readFile(new URL('../migrations/'+migration,import.meta.url),'utf8'));
 }
});
after(async()=>{await db?.close();});
async function as(id,query,args=[]){
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
 await db.exec('set role '+(id?'authenticated':'anon'));
 try{return (await db.query(query,args)).rows;}finally{await db.exec('reset role');}
}
async function set(id=a,bytes=photo,expected=id){return (await as(id,'select public.navio_set_profile_avatar($1,$2) id',[expected,bytes]))[0].id;}
async function get(id=a){return (await as(id,'select public.navio_get_profile_avatar() data'))[0].data;}
async function sharing(){
 const token=(await as(a,'select public.navio_begin_rider_sharing() token'))[0].token;
 await as(a,'select public.navio_publish_rider_position($1,1,-33.888,151.123,5,now())',[token]);
 return {token, id:(await db.query('select public_id id from public.rider_presence where user_id=$1',[a])).rows[0].id};
}
function sharedVersion(id,version){const hex=createHash('md5').update(id+':'+version).digest('hex');return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20);}
async function fetch(id,version,actor=b){return (await as(actor,'select public.navio_get_rider_avatar($1,$2) data',[id,sharedVersion(id,version)]))[0].data;}
test('anonymous and direct avatar table access are denied',async()=>{
 await assert.rejects(()=>as('','select public.navio_get_profile_avatar()'),e=>e.code==='42501');
 await assert.rejects(()=>as(a,'select * from public.profile_avatars'),e=>e.code==='42501');
 await assert.rejects(()=>as('','select public.navio_get_rider_avatar($1,$2)',[a,b]),e=>e.code==='42501');
});
test('own avatars are isolated and stale-account mutations are rejected',async()=>{
 const version=await set(); assert.equal((await get()).id,version);
 assert.equal((await get()).jpeg_base64,photo);assert.equal(await get(b),null);
 await assert.rejects(()=>set(b,photo,a),e=>e.code==='42501');
 await assert.rejects(()=>as(b,'select public.navio_remove_profile_avatar($1)',[a]),e=>e.code==='42501');
 assert.equal((await get()).id,version);
});
test('only the matching active rotating rider ID exposes a thumbnail',async()=>{
 const version=await set(),live=await sharing();
 const list=(await as(b,'select public.navio_list_riders() data'))[0].data;
 const row=list.riders[0];assert.equal(row.avatar_id,sharedVersion(live.id,version));assert.notEqual(row.avatar_id,version);
 for(const privateKey of ['user_id','session_id','jpeg','jpeg_base64','email']) assert.equal(row[privateKey],undefined);
 assert.equal(await fetch(live.id,version),photo);
 assert.equal(await fetch(b,version),null);
 await as(a,'select public.navio_stop_rider_sharing($1)',[live.token]);
 assert.equal(await fetch(live.id,version),null);
});
test('expiry and session rotation revoke old avatar lookups',async()=>{
 const version=await set(),old=await sharing();const fresh=await sharing();
 assert.equal(await fetch(old.id,version),null);
 assert.equal(await fetch(fresh.id,version),photo);
 await db.query("update public.rider_presence set expires_at=now()-interval '1 second' where user_id=$1",[a]);
 assert.equal(await fetch(fresh.id,version),null);
});
test('replacement and removal revoke previous versions without changing navigation',async()=>{
 const first=await set(),live=await sharing();const second=await set();
 assert.notEqual(first,second);assert.equal(await fetch(live.id,first),null);
 assert.equal(await fetch(live.id,second),photo);
 await as(a,'select public.navio_remove_profile_avatar($1)',[a]);
 assert.equal(await get(),null);assert.equal(await fetch(live.id,second),null);
 assert.equal((await db.query('select count(*) n from public.rider_presence where user_id=$1',[a])).rows[0].n,1);
});
test('invalid, oversized and non-JPEG payloads fail without replacing the avatar',async()=>{
 const version=await set();
 for(const bytes of [null,'bad base64',Buffer.alloc(32769).toString('base64'),Buffer.from('not-a-jpeg').toString('base64')]) {
   await assert.rejects(()=>set(a,bytes));
   assert.equal((await get()).id,version);
 }
});
test('deleting the account cascades all avatar data',async()=>{
 await set();await db.query('delete from auth.users where id=$1',[a]);
 assert.equal((await db.query('select count(*) n from public.profile_avatars where user_id=$1',[a])).rows[0].n,0);
 await assert.rejects(()=>set(),e=>e.code==='23503');
});
