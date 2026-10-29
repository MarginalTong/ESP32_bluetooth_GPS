import {test} from 'node:test';
import assert from 'node:assert/strict';
import {accountActions} from '../functions/account-actions/core.ts';

function fixture({apple = false, token = 'encrypted-provider-token', revokeFailure = false, badSubject = false} = {}) {
  const calls = [];
  const handler = accountActions({
    async verifyUser(jwt) { if(jwt !== 'valid-jwt') throw Error('private secret'); return {id: 'user-a', appleSubjects: apple ? ['apple-a'] : []}; },
    async exchangeAppleCode() {return {subject: badSubject ? 'apple-b' : 'apple-a', token: 'provider-token'};},
    async storeAppleToken(id) {calls.push('store:'+id);},
    async loadAppleToken(id) {calls.push('load:'+id);return token;},
    async revokeAppleToken() {calls.push('revoke');if(revokeFailure) throw Error('private provider token');},
    async deleteUser(id) {calls.push('delete:'+id);},
  });
  const request = (body, jwt = 'valid-jwt') => handler(new Request('https://example.test', {
    method:'POST',headers:{Authorization:'Bearer '+jwt,'Content-Type':'application/json'},body:JSON.stringify(body),
  }));
  return {request,calls,handler};
}
test('authentication is required before privileged actions', async () => {
  const f=fixture(); const r=await f.request({action:'delete_account',confirmation:'DELETE'},'invalid');
  assert.equal(r.status,401);assert.deepEqual(f.calls,[]);assert.ok(!(await r.text()).includes('secret'));
});
test('request IDs cannot delete another account', async () => {
  const f=fixture();assert.equal((await f.request({action:'delete_account',confirmation:'DELETE',id:'user-b'})).status,200);
  assert.deepEqual(f.calls,['delete:user-a']);
});
test('explicit confirmation is required', async () => {
  const f=fixture();assert.equal((await f.request({action:'delete_account'})).status,400);assert.deepEqual(f.calls,[]);
});
test('Apple authorization is revoked before deleting the user', async () => {
  const f=fixture({apple:true});assert.equal((await f.request({action:'delete_account',confirmation:'DELETE'})).status,200);
  assert.deepEqual(f.calls,['load:user-a','revoke','delete:user-a']);
});
test('revocation failure never deletes the user or exposes provider secrets', async () => {
  const f=fixture({apple:true,revokeFailure:true});const r=await f.request({action:'delete_account',confirmation:'DELETE'});
  assert.equal(r.status,503);assert.deepEqual(f.calls,['load:user-a','revoke']);assert.ok(!(await r.text()).includes('token'));
});
test('missing Apple grant requires reauthentication', async () => {
  const f=fixture({apple:true,token:null});assert.equal((await f.request({action:'delete_account',confirmation:'DELETE'})).status,409);
  assert.deepEqual(f.calls,['load:user-a']);
});
test('a provider grant must belong to the signed-in Apple identity', async () => {
  const f=fixture({apple:true,badSubject:true});assert.equal((await f.request({action:'register_apple',code:'one-time-code'})).status,403);
  assert.deepEqual(f.calls,[]);
});
test('valid Apple grants are stored against verified user ID', async () => {
  const f=fixture({apple:true});assert.equal((await f.request({action:'register_apple',code:'one-time-code',id:'user-b'})).status,200);
  assert.deepEqual(f.calls,['store:user-a']);
});
test('oversized and unsupported requests do not cause privileged writes', async () => {
  const f=fixture();assert.equal((await f.request({action:'register_apple',code:'x'.repeat(9000)})).status,413);
  assert.equal((await f.handler(new Request('https://example.test'))).status,405);assert.deepEqual(f.calls,[]);
});
