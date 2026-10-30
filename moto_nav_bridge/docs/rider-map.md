# NAVIO Sydney rider map (pilot)

Independent/GNSS navigation is deferred. This feature uses the existing phone
GPS and BLE navigation; it does not require a new hardware revision.

## User behavior

The people button below map settings opens two independent switches:

- **Show riders**: signed-in users can view voluntary participants. It never
  enables their own location sharing.
- **Share my position during navigation**: explicit public-sharing consent is
  required. The switch is in-memory only, off after app restart or account
  change. Actual publishing requires active navigation and a fresh, accurate
  Sydney-area fix. Pause, arrival, ending, poor/stale GPS or leaving the region
  withdraws the current presence session. If still opted in, resuming or starting
  another navigation can start a fresh sharing session.

Only coarse coordinates (three decimal places, roughly 100 m grid) are sent to
Supabase. The server rounds again before storage. No route, destination, speed,
home/work address, email, name, photograph, BLE binding or GPS history is shared.
Markers use colorful default person avatars and short rotating public IDs, not
auth user IDs. Custom uploaded profile photos are not part of this version.

This is public to **all signed-in users**, not a private friends group. Approximate
positions can still reveal sensitive habits and can be recorded by viewers;
rounding and rotating IDs do not make a rider anonymous. Use while parked to
configure. Markers are user-device reports, not verified identities or safety aids.

## Update and retention model

- Publishing is throttled to at most once every five seconds, with no duplicate
  fix republishing. GPS/BLE updates never await cloud I/O. Server writes are
  independently limited to once per four seconds per sharing session.
  Publication failures back off for at least five seconds. A rejected update
  triggers an explicit attempt to withdraw the previous session; a successful
  viewer refresh cannot clear the publisher's failure warning.
- Viewing polls the authenticated RPC about every five seconds while the map
  tab and app are visible. This is near-real-time polling, not a Supabase
  Realtime subscription or a guaranteed frame-by-frame tracking service.
- Position rows expire 30 seconds after the last accepted update. A successful
  stop request deletes immediately. Offline stop/crash/forced app termination
  relies on expiry instead; network latency and the next viewer refresh affect
  when a marker disappears. Client expiry checks remove stale markers too.
- The latest row replaces the previous row. Expired rows are hidden on reads
  and opportunistically deleted by the listing RPC; no strict physical deletion
  deadline/background cleanup job is configured. Database backups may retain
  earlier database states under the provider's retention policy.
- A private random session token plus monotonic sequence protects against a
  delayed publish reviving a stopped session or replacing a newer position.
  A new session also rotates the public marker ID. Auth expiry or inability to
  contact Supabase fails closed; navigation itself continues unaffected.
- Pilot geographic bounds are latitude -34.15 to -33.50 and longitude 150.50 to
  151.45. This rectangle is not an official Sydney municipal boundary.
- A response is capped at 500 riders and explicitly reports truncation. This is
  not a promise to show unlimited city-wide participants. Production scaling
  needs viewport queries/clustering, load tests, rate/abuse controls and a cost
  review. MapKit clusters nearby avatar annotations.

## Deployment

Apply `supabase/migrations/202610300002_rider_presence.sql` once to the same
account project. It creates a private RLS-enabled table and authenticated RPCs;
clients have no direct table access. Only `auth.uid()` determines the writer.
Account deletion cascades the presence row. No service_role key belongs in the
app. Do not enable table publication/broadcast of raw rows as a shortcut.

The feature remains unavailable until the migration is deployed. Configure
privacy policy/App Store location disclosures, user-support and abuse handling
before opening it beyond a small consented test group. Two confirmed test
accounts/devices are needed for real end-to-end verification; no genuine rider
locations should be published merely to test deployment.

```sh
npm --prefix supabase/tests test
cd moto_nav_bridge
flutter analyze
flutter test
flutter build ios --release --dart-define-from-file=../.navo/accounts.test.json
```

Device acceptance: two accounts, consenting vs view-only vs guest; start, pause,
resume, arrival/end; logout/account switch; lock-screen GPS; network loss and app
kill; expired markers; unchanged map camera/gestures as avatars move. Never power
or flash the cracked/hot display for this test.

`test/rider_clients_local_test.dart` connects two controllers through the real
Supabase Dart SDK to a shared test-only HTTP fixture. It checks wire payload
rounding, position movement, view-only isolation, arrival withdrawal and response
validation without publishing simulated riders online. Authentication and RPC
responses are simulated, not a running PostgREST service. SQL/RLS has separate
PostgreSQL/WASM tests. These layers do not replace two-phone hosted acceptance.

## Display arrival feedback

Firmware draws a check over 800 ms, holds the ARRIVED page for a total of four
seconds, then returns to NAVIO standby without another BLE packet. Duplicate
ARRIVED packets do not restart the timer. A new trip resets it. There is no new
sound/haptic promise: the current hardware has no newly added feedback actuator.
The phone can retain its arrival summary until the user ends the trip.
