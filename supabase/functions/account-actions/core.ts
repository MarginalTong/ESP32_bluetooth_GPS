export type VerifiedUser = {id: string; appleSubjects: string[]};
export type AccountActions = {
  verifyUser(jwt: string): Promise<VerifiedUser>;
  exchangeAppleCode(code: string): Promise<{subject: string; token: string}>;
  storeAppleToken(id: string, token: string): Promise<void>;
  loadAppleToken(id: string): Promise<string | null>;
  revokeAppleToken(token: string): Promise<void>;
  deleteUser(id: string): Promise<void>;
};

export function accountActions(deps: AccountActions) {
  const reply = (status: number, code: string) => new Response(JSON.stringify({code}), {
    status, headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store'},
  });
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return reply(405, 'method_not_allowed');
    const header = request.headers.get('Authorization') ?? '';
    if (!header.startsWith('Bearer ') || header.length > 12000) return reply(401, 'unauthorized');
    let user: VerifiedUser;
    try { user = await deps.verifyUser(header.slice(7)); }
    catch { return reply(401, 'unauthorized'); }
    let body: Record<string, unknown>;
    try {
      if (!request.headers.get('content-type')?.startsWith('application/json')) return reply(400, 'invalid_body');
      const reader = request.body?.getReader();
      if (!reader) return reply(400, 'invalid_body');
      const chunks: Uint8Array[] = [];
      let length = 0;
      while (true) {
        const {value, done} = await reader.read();
        if (done) break;
        length += value.length;
        if (length > 8192) { await reader.cancel(); return reply(413, 'body_too_large'); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) {bytes.set(chunk, offset); offset += chunk.length;}
      body = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
      if (!body || Array.isArray(body) || typeof body !== 'object') return reply(400, 'invalid_body');
    } catch {return reply(400, 'invalid_body');}
    try {
      if (body.action === 'register_apple') {
        if (!user.appleSubjects.length || typeof body.code !== 'string' || !body.code.length || body.code.length > 2048) {
          return reply(400, 'invalid_apple_grant');
        }
        const grant = await deps.exchangeAppleCode(body.code);
        if (!user.appleSubjects.includes(grant.subject)) return reply(403, 'apple_identity_mismatch');
        await deps.storeAppleToken(user.id, grant.token);
        return reply(200, 'ok');
      }
      if (body.action === 'delete_account') {
        if (body.confirmation !== 'DELETE') return reply(400, 'confirmation_required');
        if (user.appleSubjects.length) {
          const token = await deps.loadAppleToken(user.id);
          if (!token) return reply(409, 'apple_reauth_required');
          // Fail closed: never delete the account while provider revocation is
          // unavailable. The same operation is safe to retry after revocation.
          await deps.revokeAppleToken(token);
        }
        // User ID is exclusively derived from the verified session, not body.id.
        await deps.deleteUser(user.id);
        return reply(200, 'ok');
      }
      return reply(400, 'unknown_action');
    } catch {
      // Never emit raw upstream bodies, authorization codes or refresh tokens.
      return reply(503, 'account_action_unavailable');
    }
  };
}
