import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
let db;
const watchdog=setTimeout(()=>{console.error('Presence database test timed out');process.exit(1);},45000);
// Keep the event loop alive while PostgreSQL's WASM module initializes.
const a='10000000-0000-4000-8000-000000000001', b='10000000-0000-4000-8000-000000000002';
before(async()=>{
 console.info('Initializing presence database');
 db=new PGlite();
 await db.exec(`create role anon; create role authenticated;
 create schema auth; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth,public to anon,authenticated;
 insert into auth.users values('${a}'),('${b}');`);
 await db.exec(await readFile(new URL('../migrations/202610300002_rider_presence.sql',import.meta.url),'utf8'));
 console.info('Presence schema ready');
});
after(async()=>{try{await db?.close();}finally{clearTimeout(watchdog);}});
async function as(id,query,args=[]){
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
 await db.exec('set role '+(id?'authenticated':'anon'));
 try{return (await db.query(query,args)).rows;}finally{await db.exec('reset role');}
}
async function begin(id=a){return (await as(id,'select public.navio_begin_rider_sharing() token'))[0].token;}
async function publish(id,token,seq=1,lat=-33.88888,at=new Date().toISOString()){
 return (await as(id,'select public.navio_publish_rider_position($1,$2,$3,151.12345,5,$4) ok',[token,seq,lat,at]))[0].ok;
}
async function list(id=b){return (await as(id,'select public.navio_list_riders() data'))[0].data;}
test('anonymous calls and direct table reads are forbidden',async()=>{
 await assert.rejects(()=>as('','select public.navio_list_riders()'),e=>e.code==='42501');
 await assert.rejects(()=>as(a,'select * from public.rider_presence'),e=>e.code==='42501');
});
test('only shared coarse latest position is exposed; no private IDs',async()=>{
 const token=await begin(); assert.equal((await list()).riders.length,0);
 assert.equal(await publish(a,token),true);
 const r=(await list()).riders[0];assert.equal(r.latitude,-33.889);assert.equal(r.longitude,151.123);
 assert.equal(r.user_id,undefined);assert.equal(r.session_id,undefined);assert.equal(r.email,undefined);
 assert.equal((await list(a)).riders.length,0);
});
test('other user cannot publish or withdraw a session; replay cannot revive after stop',async()=>{
 const token=await begin();assert.equal(await publish(b,token),false);
 assert.equal(await publish(a,token),true);
 await as(b,'select public.navio_stop_rider_sharing($1)',[token]);assert.equal((await list()).riders.length,1);
 await as(a,'select public.navio_stop_rider_sharing($1)',[token]);
 assert.equal(await publish(a,token,2),false);assert.equal((await list()).riders.length,0);
});
test('new session revokes old one, stale and out-of-region fixes are rejected',async()=>{
 const old=await begin(),token=await begin();assert.equal(await publish(a,old),false);
 assert.equal(await publish(a,token,1,-35),false);
 assert.equal(await publish(a,token,1,-33.88,'2000-01-01T00:00:00Z'),false);
 assert.equal(await publish(a,token),true);assert.equal(await publish(a,token,1),false);
 assert.equal(await publish(a,token,2),false); // server rate guard
});
test('expired positions disappear, rows are cleaned, account deletion cascades',async()=>{
 const token=await begin();await publish(a,token);
 await db.query("update public.rider_presence set expires_at=now()-interval '1 second' where user_id=$1",[a]);
 assert.equal((await list()).riders.length,0);
 assert.equal((await db.query('select count(*) n from public.rider_presence where user_id=$1',[a])).rows[0].n,0);
 await begin();await db.query('delete from auth.users where id=$1',[a]);
 assert.equal((await db.query('select count(*) n from public.rider_presence where user_id=$1',[a])).rows[0].n,0);
});
