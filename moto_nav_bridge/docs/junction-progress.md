# Junction progress and clipping

## Cause

`SideRoadPreview` used `MapPreview.screenPoint`, whose y coordinate clamps to
the forward-route baseline (34). A junction up to 20 metres behind the rider
was intentionally retained, but its screen anchor could not move behind the
rider. It therefore stuck at the cursor until being discarded.

Two other inconsistencies amplified this: the preview globally projected the
GPS again, independently of the engine's current-step match (a nearby return
leg could win), and a step transition discarded the previous junction geometry.
The 14 m side-road connection tolerance could then attach an old branch to the
new route's endpoint instead of its original intersection.

## Implementation

- `RoutePreviewProgress` accumulates segment lengths and accepts the engine's
  constrained projection. Distance calculation and preview use the same match.
  It holds less than 3 m of stationary noise and less than 5 m backwards jitter;
  forward movement is immediate for moving fixes. Larger measured retreats are
  accepted, not hidden. These are display/progress guards, not GPS correction
  or a replacement for the independent off-route/course checks.
- `MapPreview` clips the forward route starting at that projection. Original
  vertices behind it are retained for connecting side roads only, including a
  40 m tail across previous maneuvers. When the maneuver selector advances
  early at low speed, a closer incoming-road match keeps the preview on the
  actual approach rather than snapping it to the upcoming step's start.
  Current-step segment indices are kept
  consistent even when geometry has repeated vertices.
- Side roads use cumulative road distance relative to the rider for the
  -20 m / +225 m window. Their junction coordinates are not clamped to the
  cursor. The firmware's existing map aperture clips them as they leave view.
- No BLE format change, extra server calls, longer animation, or firmware
  rendering change. Existing 20-point `P` / eight-arm `R` snapshots and bounded
  `MapMotion` interpolation remain. Interpolation ends at the measured target;
  absent packets do not cause unlimited prediction. Packet loss can still
  reduce visual smoothness; there is no invented intermediate GPS fix.

Side-road arms remain the existing fixed-length perpendicular schematic,
not a geographically exact road map. This change fixes anchor motion and
consumption; it does not redesign that representation or add branch IDs to BLE.

## Reproduce and test

Run from `moto_nav_bridge`:

```sh
flutter test test/junction_progress_test.dart
```

Coordinates in the test are local metres near the equator: travel from (0,0)
to (0,100), take the selected arm to (120,260); the other arm leaves (0,100)
for (-60,180). Approach at y=80 and 95, then feed one-metre samples along the
selected arm (0.6*d,100+0.8*d), with a fresh 36.87-degree course. At d=1..19
the branch anchor must retreat from y=341.6 to370.4 in tenths of mini-map units,
while the rider remains (640,340). At d=30 the old junction is out of range.
The original clamp pins every behind-rider sample at340 instead.

The same file covers T/cross/multiple junctions, consecutive short maneuvers,
slow approaches, nearer future return legs,
stationary jitter, real movement and a large retreat. Host test
`firmware/tests/junction_motion_test.cpp` feeds 1 Hz packets and ticks the actual
`MapMotion` at25 ms; it checks monotonic movement past the cursor, a stationary
cursor and no extrapolation during a ten-minute packet gap. It is included in
`bash firmware/tests/run_map_motion_test.sh` and the full repository check.

These are deterministic geometry and host-render-motion checks, not a physical
display or RF test. Validate a real ride after updating the phone App; the
fix does not require reflashing firmware that already supports `P`/`R`.
