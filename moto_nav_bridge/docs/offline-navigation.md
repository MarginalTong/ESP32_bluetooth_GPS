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
