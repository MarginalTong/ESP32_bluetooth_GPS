# Navigation voice gateway

Use the Gemini audio endpoint `POST /v1/voice` with a bearer token. The active
flow is conversational: it returns a short reply and optionally proposes a
destination action. The App provides a bounded, read-only route snapshot only
after the rider enables AI trip access. Saved home/work/school addresses stay
on the phone; only available slot labels reach Gemini, and a spoken confirmation
is required before a new route replaces the existing one. Route preferences
(tolls/highways/tunnels/ferries) are not yet voice-editable.
See
[AUDIO_DEPLOYMENT.md](AUDIO_DEPLOYMENT.md) for configuration, privacy limits and deployment.

The App can optionally call `POST /v1/reply` after it resolves a live,
read-only navigation answer. The gateway may add a short conversational
sentence, but must preserve the App's verified answer verbatim. Older gateways
remain compatible: the App falls back to the local answer if this endpoint is
missing, times out or reaches quota. Each successful voice question can use
two Gemini calls instead of one, so review the daily cap before deployment.
Expose `/v1/reply` in the same Nginx upstream as `/v1/voice`, then restart the
`nav-voice` service. Do not proxy it to Valhalla.
The audio classifier also returns a route-independent greeting, so saying
"hi" does not ask for navigation state. ETA answers still require an active
route and a recent usable location; the App never fabricates travel time.

The obsolete preset-text `/v1/intent-test` endpoint has been removed and now returns 404.
Run tests with `python3 -m unittest discover -s voice_gateway` from the repository root.

Keep `GEMINI_API_KEY`, `GEMINI_MODEL` and `VOICE_AUDIO_ENABLED=true` in the
server environment. Credentials are not committed or embedded in the app.

## Users and quotas

Every rider gets a personal bearer token. The gateway stores only its SHA-256,
and each call must fit both that user's limits and the global limits
(`VOICE_GLOBAL_DAILY`, default 1000; `VOICE_GLOBAL_PER_MINUTE`, default 30),
which bound the total Gemini bill. A leaked token can only spend its own
quota, and can be rotated or disabled on its own.

Manage users on the VPS with the service's environment and working directory
(so `VOICE_BUDGET_DB` points at the live database):

```sh
cd ~/voice_gateway && set -a && . ./.env && set +a
python3 server.py users add alice --daily 100 --per-minute 6   # prints the token once
python3 server.py users list
python3 server.py users rotate alice      # new token; the old one stops working
python3 server.py users disable alice     # or: enable
python3 server.py users limits alice --daily 200 --per-minute 10
```

Give each rider their token through a private channel; they save it in the
app's voice settings (stored in the iPhone Keychain). Changes take effect
immediately, without restarting the service. Over-limit calls return 429
`user_limit_reached` or `service_limit_reached`; unknown or disabled tokens
return 401.

**Migrating from the shared token.** If `VOICE_TEST_TOKEN` is still set, it
keeps working as user `legacy` (100/day, 6/min) so installed apps do not break.
Once every rider has a personal token, remove `VOICE_TEST_TOKEN` from `.env`
and restart: the `legacy` user is disabled. Calls recorded before the upgrade
still count towards the global limits.
