# Direct audio private test

The app's new Gemini button records a single 16 kHz mono PCM WAV in memory,
ending about one second after speech becomes quiet (maximum ten seconds).
The recording is uploaded only after explicit consent. Neither gateway nor app
intentionally writes recordings to disk. Google processing/retention terms still
apply; free-tier inputs may be used for service improvement. Do not test with
private conversations or addresses on the free tier.

## Server upgrade

1. Upload the updated `server.py` to `~/voice_gateway/server.py` on the VPS.
2. Add `VOICE_AUDIO_ENABLED=true` to the server's existing `.env`. Keep
   `GEMINI_API_KEY` and `GEMINI_MODEL` there; never embed them in the app.
   Ensure the chosen model supports audio input. Create a personal token per
   rider with `python3 server.py users add NAME` (see README, "Users and
   quotas"); `VOICE_TEST_TOKEN` is only a temporary migration fallback.
3. In the existing HTTPS nginx server block, add this exact location, keeping
   the existing route location unchanged. The obsolete `/v1/intent-test` location may be removed:

```nginx
location = /v1/voice {
    client_max_body_size 430k;
    client_body_buffer_size 512k;
    access_log off;
    proxy_request_buffering off;
    proxy_pass http://127.0.0.1:8091;
    proxy_http_version 1.1;
    proxy_read_timeout 35s;
}

location = /v1/reply {
    client_max_body_size 2k;
    access_log off;
    proxy_pass http://127.0.0.1:8091;
    proxy_http_version 1.1;
    proxy_read_timeout 20s;
}
```

4. Run `sudo systemctl restart nav-voice`, then `sudo nginx -t` and only if
   successful `sudo systemctl reload nginx`.
5. Rebuild/install the app. Open voice settings (gear) and save your
   personal gateway token once. The default
   URL is built in; both settings are stored in the iPhone Keychain, not source.
6. While parked, press “Talk to Gemini”, accept audio upload, and say a command.
   Check cancellation/backgrounding and denied microphone permission too.

This is a bounded navigation-intent audio experiment, not an unrestricted live
conversation service. Gemini destination changes now read up to three Apple Maps
results, accept a spoken ordinal, then read the full selected place/address and
require explicit spoken confirmation. Each reply is another uploaded audio turn.
Playback must finish before recording starts. Unknown, cancelled or interrupted
answers retain the original route. Legacy offline recognition and preset tests have been removed.
Toll commands are understood but do not yet mutate
route preferences. The app explicitly reports this instead of claiming success.

Each call counts against the caller's own limits and the global limits. A
token is not a paid subscription or account system: issue, rotate and disable
tokens by hand with `server.py users`. Rotate any token that may have leaked.
An unauthenticated request must return 401; an authenticated request with audio
disabled returns 503. No deployment or real Gemini audio call is performed by
unit tests.
