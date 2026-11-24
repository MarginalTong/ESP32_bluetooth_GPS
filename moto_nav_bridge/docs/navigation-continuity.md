# Navigation continuity

## Confirmed reset paths (2026-11-24)

- ESP32 `ServerCallbacks::onDisconnect` increments the mailbox disconnect
  counter. `applyBleMailbox` previously cleared navigation, packet age and
  maneuver state, then invalidated `mapMotion`. `resolveUiState` prioritised
  disconnected -> `ConnectionLost`; `renderUiScreen` drew the NAVIO brand.
- Flutter does not call End or change tabs on BLE loss. `AppShell` keeps the
  map inside an IndexedStack. `NavigationController` keeps the route/session
  on GPS errors, but previously sent a geometry-free STOP packet, causing the
  display's fullscreen NoGuidance page.
- BLE already retries the bound display at 1/2/4/8 seconds, then ten seconds,
  later thirty seconds. Reconnection creates a fresh signed session nonce.
  The old pending-state flush accepted navigation up to ten seconds old;
  reconnection needs explicit GPS-quality-aware synchronisation instead.

## Module boundaries

BLE scanning, pairing/discovery and writes are private library parts of
`BleService`. Firmware runtime fragments preserve translation-unit order;
the sketch keeps entrypoints and the host-tested authentication block.
Hardware registers, pins, panel setup and visual parameters are unchanged by
this extraction. The user's pre-existing gray-layer edits remain uncommitted
(the rendering fragment now owns the moved code).

## Implemented state contract

`NavigationContinuityController.conditions` is a set, not a replacement route:
Navigating, NetworkOffline, GPSUnavailable, BLEDisconnected, Reconnecting and
NavigationEnded can coexist where meaningful. A link event does not call End,
clear the route, recreate the map, or select a different tab. GPS-quality errors
keep navigation active and send cached context, not an empty STOP screen.
The instruction card identifies GPS loss separately from rerouting.

NetworkOffline means an observed route-network failure/timeout. An ordinary
HTTP/no-route/route-matching rejection is not automatically called offline.
There is deliberately no periodic internet ping or assumption that Wi-Fi means
internet; when riding on-cache without requests, internet reachability is
unknown until observed, not continuously monitored. Successful route requests
clear the observed fault. This status never controls BLE or route lifetime.

The coordinator listens to injectable link notifications and requests a fresh
GPS-backed snapshot on a connected edge and on foreground resume. It neither
starts duplicate scans nor overrides a user-initiated Disconnect. Existing
BleReconnectPolicy retains its bounded 1/2/4/8 -> 10 -> 30 second backoff.
FlutterBluePlus still owns native scan/connect execution; OS background limits
are not bypassed by a Dart timer.

No queued pre-loss packet is flushed on reconnection. Old-write completions
check signer/characteristic identity before touching current state, and drain
ownership prevents an old Future from clearing the new write operation.
New connections synchronise signed local/UTC clock data first. Normal frames
carry the GPS-derived UTC `e` deadline; geometry and distance are never re-dated
just because delivery failed. The ESP32 checks HMAC/nonce, sequence and expiry
before applying a navigation update. Its existing eight-second receipt timeout
also remains in force. No timeout was lengthened.

Firmware `NavigationContinuity` preserves the last real navigation facts.
Disconnect freezes animation but not geometry; clock-only reconnection stays
stale until a valid navigation snapshot arrives. Unknown positioning, reroute
waits and expired data hide the live rider marker, numeric countdown and speed
limit. A compact LAST KNOWN / BLE-STALE label replaces the former large failure
page. Only explicit END or completed arrival returns to idle. This is RAM
retention, not persistence across an ESP32 power cycle.

## Verification and remaining physical checks

Host simulations cover 1 s / 10 s / 120 s outages and elapsed-time UI decisions,
clock-only reconnect, fresh-frame recovery, explicit END, duplicates, reverse
sequence numbers, expired/future deadlines, missing UTC calibration and a new
authenticated connection's counter reset. Existing HMAC vectors include old
nonce rejection. Dart simulations cover preserved route/session identity,
simultaneous network/GPS/BLE faults, simultaneous reroute and reconnection,
foreground refresh with stale/new GPS, expiry serialization and signed packet
size. Existing IndexedStack/map-retention tests remain in the full suite.

These simulations are not radio or hardware tests. On-device acceptance still
requires installing the App and flashing the matching firmware, then testing
RF interruptions, background suspension/resume, native queued-write callbacks,
clock changes and visual smoothness. Both old/new peer combinations retain
compatibility, but strict source expiry requires both new versions. No firmware
was uploaded or phone App installed automatically.
