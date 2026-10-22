# Navigation-only voice wake

The Agent icon is available in normal builds, without VOICE_PRIVATE_TEST.
The map no longer displays the large wake/voice/repeat controls. The user opts
in from the Agent menu for each navigation session after gateway credentials
are saved. To avoid interfering with map and GPS performance, standby runs only
one on-device Apple Speech request at a time. It prefers the UI language
(zh-CN or en-AU) and falls back to the other locale if necessary. Both 导航 and
Hey Moto are matched if transcribed, but recognition in the non-active language
is not guaranteed on every iPhone. The Agent menu shows the active locale.
If neither locale supports on-device recognition, wake is unavailable but the
manual Agent entry remains. English matching ignores case/punctuation but
requires whole words. No network fallback and no standby transcript logging.

Foreground only. Lock/background, audio interruption and headset removal pause
listening; user turns the toggle off/on to resume. Ending the trip or arrival
stops the listener and cancels any wake dialogue. A pending permission response
cannot restart a stopped session. Regular recognition sessions renew at 45s;
errors stop instead of retrying indefinitely. Renewal can have a listening gap.

Say 导航, wait for 请说, then speak a command. Existing ~1s speech endpointing
and spoken destination confirmation apply. Wake-session consent covers command
and confirmation uploads to Gemini. Completing the dialogue returns to standby.
TTS stops wake capture to prevent self-triggering. No all-day listening.

Not a production background/locked-screen feature. Still requires physical-device
validation: cross-language transcription on supported phones/iOS, 30+ minute renewal,
music/headset audio routing, wind/false positives, interruption, permission
denial, navigation end during permissions/network/confirmation, and battery use.
Do not promise lockscreen support or reliable keyword spotting from this prototype.
