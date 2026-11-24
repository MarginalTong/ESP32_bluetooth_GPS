# Offline navigation

## Existing data flow and boundaries

`LocationService` supplies GPS fixes without calling the routing server.
`NavigationEngine` matches fixes to route geometry, advances maneuvers and
calculates distances locally. `BleService.send` signs and writes display packets;
neither matching nor BLE requires internet access.

Online dependencies are Valhalla route/alternate-route planning, optional lane
and speed-limit enrichment, nearby side-road fetching, place search, map tiles,
voice-agent requests, account sync and public rider locations. Supplementary
side roads already load in the background; losing them must not stop guidance.

The existing controller kept routes only in RAM, requested routes again at Start,
and returned early from position handling while rerouting. Restart recovery and
persistent route storage were absent. The latter early return also prevented
recovering onto the cached route until the HTTP request completed.

## Code ownership

`navigation_controller.dart` keeps the public API and session state. Private
library parts separate planning, GPS/local tracking, reroute recovery, optional
map context, destination changes and lifecycle. This extraction preserves the
existing matching algorithm and BLE contract; it does not introduce another
navigation engine.

## Implemented route continuity

The production composition root injects `FileNavigationSessionStore`; tests can
inject an in-memory or failing store without platform channels. The controller's
persistence part coordinates it; the routing provider, GPS port and pure local
engine remain independently injectable. No connectivity plugin or internet
"ping" is used to decide whether GPS should work.

After each accepted preview, route change or reroute, `route.json` contains all
candidate routes, all step geometry/start/end coordinates, maneuver direction
and raw type, distances, travel-time metadata, street names, lane/roundabout/
arrival-side/speed-limit data, supplied side roads, attribution, destination,
waypoints and the trip's routing preferences. GPS progress does not rewrite this
geometry: `progress.json` stores the selected route, step cursor, completed stops,
route-relative waypoint base, one last position and save time. It updates every
five seconds, plus maneuver/selection/lifecycle transitions. There is no location
history, BLE packet, signing key or account credential in these files, and neither
file is part of the App's cloud settings sync. OS device-backup policy is separate.

Files live in the platform application-support `navigation_session` directory.
They have a schema version, SHA-256 corruption check and a 32 MiB per-document
limit. A same-directory temporary file is flushed then renamed; queued writes and
clear operations run in order. Progress is bound to a route-revision ID, so an old
checkpoint cannot be applied to a replacement route. Geometry encoding/hashing
runs in a separate isolate. Failures are reported without ending in-memory GPS
navigation; restart recovery is not promised when storage has failed.

Start reuses the selected preview if the destination/stops still match and a
current fix matches the route/course. It no longer requires an ETA refresh to
start an already planned trip. A moved origin or newly consumed start waypoint
requires a new route request instead of silently using the wrong itinerary.

Confirmed deviation retains the old geometry but suppresses its turn/distance;
the display receives the existing `rerouting`/STOP contract, not a fabricated
connector. GPS and BLE continue while the route request is pending. A fresh match
back on the cached route immediately resumes guidance and invalidates the pending
response. Fresh GPS heartbeats also run during recovery. Requests are bounded at
12 seconds and retries retain the existing ten-second minimum interval. The next
eligible fix/timer retries after connectivity recovers; on-route riding does not
request a replacement merely because the internet came back. Responses still
undergo existing position, course, request-token and `RouteAlignment` checks.

At launch the home page checks for a saved trip and offers Resume/End. It does
not start GPS, share rider presence or send an old instruction without a tap.
Resume requires a new fix no older than ten seconds and accuracy no worse than
50 m; it restores the saved step cursor/waypoint base, not an old packet or old GPS
timestamp. Off-route recovery keeps the route but waits for valid guidance.
Explicit End or arrival clears the recoverable trip. Late initial planning
responses cannot restart a trip after End.

## Scope and remaining limits

This is persistent route-following, **not a full offline routing graph**. Cached
routes have no TTL that expires after ten minutes, but road closures/conditions
cannot be refreshed offline. Place searches, new destinations and off-route
replanning still require Valhalla/network access. MapKit basemap tiles, satellite
imagery and newly encountered side-road context are not downloaded by this
change; route overlays/arrows can continue even when the basemap is unavailable.
AI and public rider/account services also remain online-dependent.

GPS loss is different from internet loss: a tunnel can remove the GNSS signal.
The existing GPS-loss/stale-display safety behavior remains; this change does
not invent a position or implement inertial dead reckoning. Flight mode may also
turn Bluetooth off, so hardware testing must explicitly re-enable BLE.

## Full offline replanning: separate options (reviewed 2026-11-24)

1. **Valhalla on the phone** is the closest fit. The maintained
   [valhalla-mobile project](https://github.com/Rallista/valhalla-mobile)
   provides native iOS/Android libraries. A Flutter platform-channel/FFI adapter
   can implement the existing `WaypointRouteProvider` while retaining the current
   Valhalla JSON parser. It needs prebuilt Valhalla graph tiles (`.gph` tile tree
   or a tile-extract `.tar`), compatible engine/configuration versions, regional
   download management, integrity checks and atomic data updates. OSM `.pbf`
   is an input to preprocessing, not a ready-to-route phone database; see
   [Valhalla build documentation](https://valhalla.github.io/valhalla/building/).
   Adjacent regions must come from a compatible graph build, not independently
   combined without checking boundary connectivity.
2. **Commercial Flutter offline SDK**: for example,
   [Magic Lane](https://developer.magiclane.com/docs/flutter/guides/offline/introduction/)
   supports downloaded-region routing/navigation. This would replace/adapt the
   routing/data stack, requires licensing/distribution review, and does not
   consume NAVIO's Valhalla tiles directly. Integration and motorcycle-specific
   routing preferences would need a separate proof of concept.
3. **Offline display maps alone** do not solve routing. Flutter renderers and
   MBTiles/PMTiles/vector/raster packs describe how to draw a map, not necessarily
   a connected routable road graph. The
   [Mapbox Flutter offline example](https://docs.mapbox.com/flutter/maps/examples/offline/)
   downloads style/tile packs; that feature alone is not proof of offline
   replanning. GraphHopper's own
   [repository](https://github.com/graphhopper/graphhopper) says offline routing
   is no longer officially supported; it is not a drop-in iOS/Flutter solution.

Storage must be measured against the intended regional graph, not estimated from
a screen resolution. Route-only storage scales with geometry/steps; it is capped
here at 32 MiB per document. A regional routing graph and display tiles are
separate downloads and may be orders of magnitude larger. Before committing to
full offline routing, build Sydney/NSW samples and record compressed download
size, installed size, peak routing memory, cold-start time and reroute latency on
the oldest supported iPhone/Android. Provision staging space for both old and new
graph packages during updates (roughly 2× the graph size plus downloaded archive
and safety margin). No unmeasured claim that an entire region fits in a few MB is
made here. The ESP32 continues to receive compact BLE guidance, not the phone's
full routing graph.

## Verification

Automated coverage includes: all route metadata round-tripping through real
files/new store instances; progress-only writes; mismatched revision/corrupt
checkpoint/partial write/schema/corruption handling; serialized End; preview
Start without a second request; ten minutes of virtual offline time followed by
new distance/BLE output; local recovery before a pending HTTP request completes;
late-response rejection; explicit restart resume with stale-fix rejection;
slow/failing persistence; automatic online retry with fresh GPS; and the Resume
UI. Existing route alignment, maneuver matching and BLE tests remain in the full
suite. Some expectations about a mandatory server request at Start deliberately
changed to the new cached-start behavior; fastest-route selection itself remains.

Physical checks still required (not claimed as completed by automated tests):

- Start a trip outdoors, enable flight mode, re-enable Bluetooth, and verify
  GPS/BLE still update turn distances on the planned route for at least ten minutes.
- Deviate safely while offline: no invented turn/distance; return to the route
  and check immediate recovery. Alternatively reconnect and check rerouting from
  the latest fix without restarting the navigation session.
- Terminate/reopen the App offline: no old turn is sent at launch; Resume obtains
  a fresh fix and continues at the saved progress. Repeat with a GPS-denied/stale
  fix and ensure guidance stays withheld.
- Check that End/arrival does not offer the ended trip after the next launch.
