# NAVIO trip waypoints

## Use

1. Choose the final destination, then tap **Add stops** in the route panel.
2. Search for up to five intermediate places. Tap a row to replace it; use the
   up/down controls to change its order, or remove a stop. **Done** applies the
   draft and requests a new preview; Back discards it.
3. Start navigation. Each stop is visited in the displayed order, then guidance
   continues to the final destination. There is no timed stopover/pause action.
4. The trip panel shows the next stop. Reroutes retain only outstanding stops.
   Ending navigation clears the itinerary. Stops are trip-only, not cloud-synced.

Editing is available before navigation only. The existing search page supports
place search and address links. This version does not add numbered waypoint pins
to the native map or allow editing stops mid-ride. Phone and display still share
one continuous route; no BLE packet-format or firmware change is needed.

## Routing and safety

- POST the ordered origin → stops → destination to the configured Valhalla
  endpoint. Intermediate locations use `break`, giving independently verifiable
  legs. The response must contain exactly the requested number of legs and
  connected geometry; missing stops fail instead of silently routing directly.
- Intermediate arrival maneuvers are removed when joining legs. A START at the
  following leg is converted into the joining turn based on road geometry.
  Only the final endpoint can emit ARRIVED. This geometric join is not a
  lane-level instruction; roundabouts and stops on complex junctions need
  additional real-road verification.
- Progress requires reaching the road-snapped leg endpoint within 25 m, in
  order, on-route. NavigationFix accuracy must be ≤25 m and fresh within 10 s.
  A GPS jump cannot use the engine's normal overshoot rule to skip a stop.
  If GPS samples miss that arrival area entirely, the stop stays outstanding;
  a reroute may deliberately return to it rather than guess it was visited.
- Valhalla does not support alternates for more than two locations, so trips
  with stops request `alternates: 0`. Two-location routes keep existing choices.
- Five stops is an app limit, not a claim about the server's configured maximum.
  Changing the final destination retains the existing stop list.

Reference: [Valhalla route API](https://valhalla.github.io/valhalla/api/route/api-reference/).

## Verification

```sh
flutter test test/waypoint_routes_test.dart test/waypoint_navigation_test.dart test/waypoint_editor_test.dart
flutter analyze
flutter test
# Optional network check using fixed public Sydney landmarks, not live GPS:
flutter test --dart-define=NAVIO_LIVE_ROUTE_TEST=true test/waypoint_live_test.dart
```

Before release, verify on an undamaged display and iPhone: stop before/after a
turn, a stop in a car park, a missed stop and deviation, GPS loss near a stop,
stop edits followed by a failed preview, pause/resume, and final arrival. Test
sunlight/glove readability and safety only while stationary. Automated tests
and a live server smoke test do not certify real-ride behavior.
