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

Keep `GEMINI_API_KEY`, `GEMINI_MODEL`, `VOICE_TEST_TOKEN` and
`VOICE_AUDIO_ENABLED=true` in the server environment. The token variable retains
its name for compatibility with existing installations; it is not production
per-user authentication. Credentials are not committed or embedded in the app.
