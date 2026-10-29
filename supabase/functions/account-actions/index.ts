import { createClient } from 'npm:@supabase/supabase-js@2';
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from 'npm:jose@6';
import { accountActions } from './core.ts';

const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error('Server configuration missing');
  return value;
};
const client = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: {persistSession: false, autoRefreshToken: false},
});
const appleKeys = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
async function secret() {
  const key = await importPKCS8(env('APPLE_PRIVATE_KEY').replaceAll('\\n', '\n'), 'ES256');
  return await new SignJWT({}).setProtectedHeader({alg: 'ES256', kid: env('APPLE_KEY_ID')})
    .setIssuer(env('APPLE_TEAM_ID')).setSubject(env('APPLE_CLIENT_ID'))
    .setAudience('https://appleid.apple.com').setIssuedAt().setExpirationTime('5m').sign(key);
}
async function appleRequest(path: string, fields: Record<string, string>) {
  const result = await fetch('https://appleid.apple.com' + path, {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({client_id: env('APPLE_CLIENT_ID'), client_secret: await secret(), ...fields}),
    signal: AbortSignal.timeout(10000),
  });
  if (!result.ok) throw new Error('Provider unavailable');
  return result;
}
async function tokenKey() {
  const raw = env('APPLE_TOKEN_ENCRYPTION_KEY');
  if (!/^[0-9a-fA-F]{64}$/.test(raw)) throw new Error('Server configuration invalid');
  const bytes = Uint8Array.from(raw.match(/../g)!, b => parseInt(b, 16));
  return await crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
function base64(bytes: Uint8Array) { return btoa(String.fromCharCode(...bytes)); }
async function encrypt(token: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv}, await tokenKey(), new TextEncoder().encode(token)));
  return base64(iv) + '.' + base64(encrypted);
}
async function decrypt(value: string) {
  const pieces = value.split('.');
  if (pieces.length !== 2) throw new Error('Invalid provider grant');
  const decode = (v: string) => Uint8Array.from(atob(v), c => c.charCodeAt(0));
  return new TextDecoder().decode(await crypto.subtle.decrypt({name: 'AES-GCM', iv: decode(pieces[0])}, await tokenKey(), decode(pieces[1])));
}
Deno.serve(accountActions({
  async verifyUser(jwt) {
    const {data, error} = await client.auth.getUser(jwt);
    if (error || !data.user) throw new Error('Unauthorized');
    const apple = (data.user.identities ?? []).filter(i => i.provider === 'apple');
    if (apple.some(i => typeof i.identity_data?.sub !== 'string')) {
      throw new Error('Provider identity unavailable');
    }
    return {id: data.user.id, appleSubjects: apple.map(i => i.identity_data!.sub as string)};
  },
  async exchangeAppleCode(code) {
    const body = await (await appleRequest('/auth/token', {grant_type: 'authorization_code', code})).json();
    if (typeof body.refresh_token !== 'string' || typeof body.id_token !== 'string') throw new Error('Missing grant');
    const {payload} = await jwtVerify(body.id_token, appleKeys, {
      issuer: 'https://appleid.apple.com', audience: env('APPLE_CLIENT_ID'), algorithms: ['RS256'],
    });
    if (!payload.sub) throw new Error('Missing provider identity');
    return {subject: payload.sub, token: body.refresh_token};
  },
  async storeAppleToken(id, token) {
    const {error} = await client.from('account_apple_grants').upsert({user_id: id, encrypted_token: await encrypt(token), updated_at: new Date().toISOString()});
    if (error) throw new Error('Grant storage unavailable');
  },
  async loadAppleToken(id) {
    const {data, error} = await client.from('account_apple_grants').select('encrypted_token').eq('user_id', id).maybeSingle();
    if (error) throw new Error('Grant storage unavailable');
    return data ? await decrypt(data.encrypted_token) : null;
  },
  async revokeAppleToken(token) { await appleRequest('/auth/revoke', {token, token_type_hint: 'refresh_token'}); },
  async deleteUser(id) {
    const {error} = await client.auth.admin.deleteUser(id);
    if (error) throw new Error('Deletion unavailable');
  },
}));
