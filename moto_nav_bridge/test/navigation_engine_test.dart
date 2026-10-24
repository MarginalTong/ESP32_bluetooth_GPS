import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';

// A short synthetic route along a line of latitude near the equator so that
// 1 degree of longitude is a large, easy-to-reason-about distance. We keep the
// points close together and check relative behavior rather than exact meters.
void main() {
  test('missed turn fixes recover early on long and curved outgoing roads', () {
    const a = LatLng(0, 0), b = LatLng(0.001, 0);
    const bend = LatLng(0.001, 0.0001), c = LatLng(0.006, 0.0001);
    const d = LatLng(0.006, 0.005);
    NavigationEngine engine() => NavigationEngine(const [
          RouteStep(
              direction: DeviceDirection.up,
              start: a,
              end: b,
              distanceMeters: 111,
              geometry: [a, b]),
          RouteStep(
              direction: DeviceDirection.right,
              start: b,
              end: c,
              distanceMeters: 567,
              geometry: [b, bend, c]),
          RouteStep(
              direction: DeviceDirection.right,
              start: c,
              end: d,
              distanceMeters: 545,
              geometry: [c, d]),
        ]);
    NavigationFix fix(double lat, double lon, double heading) =>
        NavigationFix(lat, lon,
            heading: heading, speed: 8, accuracy: 5, timestamp: DateTime.now());
    final nav = engine();
    nav.update(fix(0.0007, 0, 0));
    // Skip the corner and its short eastbound segment entirely.
    final first = nav.update(fix(0.0013, 0.0001, 0));
    expect(nav.currentStepIndex, 1);
    final second = nav.update(fix(0.002, 0.0001, 0));
    expect(second.distanceMeters, lessThan(first.distanceMeters));
    // Miss another turn: don't wait until halfway down the outgoing road.
    nav.update(fix(0.006, 0.0005, 90));
    expect(nav.currentStepIndex, 2);
    final reverse = engine();
    reverse.update(fix(0.0013, 0.0001, 180));
    expect(reverse.currentStepIndex, 0);
    final incoming = engine();
    incoming.update(fix(0.0007, 0, 0));
    expect(incoming.currentStepIndex, 0);
  });
  test('local matcher does not jump to a remote future segment', () {
    final points = List.generate(10, (i) => LatLng(i * 0.001, 0));
    final engine = NavigationEngine([
      RouteStep(
          direction: DeviceDirection.up,
          start: points.first,
          end: points.last,
          distanceMeters: 1000,
          geometry: points)
    ]);
    expect(engine.isOffRoute(points.first), isFalse);
    expect(engine.isOffRoute(points[8]), isTrue);
    expect(engine.isOffRoute(points[1]), isFalse);
  });
  test('travel course detects reverse movement but ignores stationary heading',
      () {
    final engine = NavigationEngine(const [
      RouteStep(
        direction: DeviceDirection.up,
        start: LatLng(0, 0),
        end: LatLng(0.01, 0),
        distanceMeters: 1110,
        rawManeuver: null,
      )
    ]);
    NavigationFix fix(double heading, double speed,
            {double longitude = 0, double accuracy = 5}) =>
        NavigationFix(0.001, longitude,
            heading: heading,
            speed: speed,
            accuracy: accuracy,
            timestamp: DateTime.now());
    expect(engine.isOffRoute(fix(0, 2)), isFalse);
    expect(engine.isOffRoute(fix(180, 3)), isTrue);
    expect(engine.reverseTravel, isTrue);
    for (final speed in [0.67, 1.05, 1.67, 2.49, double.nan, double.infinity]) {
      expect(engine.isOffRoute(fix(180, speed)), isFalse);
      expect(engine.lastCourseDeltaDegrees, isNull);
      expect(engine.lastRouteDistanceMeters, closeTo(0, .01));
    }
    expect(engine.isOffRoute(fix(180, 0)), isFalse);
    expect(engine.isOffRoute(fix(0, 2, longitude: 0.0003)), isTrue);
    expect(
        engine.isOffRoute(fix(0, 2, longitude: 0.0003, accuracy: 20)), isFalse);
  });
  test('route tolerance changes smoothly around 10 m GPS accuracy', () {
    final engine = NavigationEngine(const [
      RouteStep(
          direction: DeviceDirection.up,
          start: LatLng(0, 0),
          end: LatLng(0.01, 0),
          distanceMeters: 1110),
    ]);
    NavigationFix fix(double accuracy, double longitude) =>
        NavigationFix(0.001, longitude,
            heading: -1,
            speed: 0,
            accuracy: accuracy,
            timestamp: DateTime.now());

    // About 30 m from the line: both sides of the old 10 m accuracy cliff
    // should make the same decision.
    expect(engine.isOffRoute(fix(9.9, 0.00027)), isFalse);
    final below = engine.lastOffRouteThresholdMeters!;
    expect(engine.isOffRoute(fix(10.1, 0.00027)), isFalse);
    final above = engine.lastOffRouteThresholdMeters!;
    expect(above - below, closeTo(0.2, 0.01));
    expect(engine.isOffRoute(fix(9.5, 0.0005)), isTrue);
  });
  // Three maneuver points roughly in a line, ~111 m apart (0.001 deg lat).
  const p0 = LatLng(0.000, 0.0); // origin / start of step 0
  const p1 = LatLng(0.001, 0.0); // end of step 0 == turn point (LEFT)
  const p2 = LatLng(0.002, 0.0); // end of step 1 == destination (ARRIVED)

  List<RouteStep> route() => const [
        RouteStep(
          direction: DeviceDirection.up, // heading out, no prior maneuver
          start: p0,
          end: p1,
          distanceMeters: 111,
          rawManeuver: null,
        ),
        RouteStep(
          direction: DeviceDirection.left, // the turn performed at p1
          start: p1,
          end: p2,
          distanceMeters: 111,
          rawManeuver: 'turn-left',
        ),
      ];

  test('early in step 0, announces the upcoming LEFT turn at p1', () {
    final engine = NavigationEngine(route());
    final state = engine.update(p0);
    expect(state.direction, DeviceDirection.left);
    expect(engine.currentStepIndex, 0);
    // ~111 m to the turn point.
    expect(state.distanceMeters, greaterThan(100));
    expect(state.distanceMeters, lessThan(130));
  });

  test('distance to the turn shrinks as the rider approaches p1', () {
    final engine = NavigationEngine(route());
    final far = engine.update(p0).distanceMeters;
    // Still ~55 m from the turn point p1, i.e. outside the 15 m arrival
    // threshold, so the engine keeps measuring toward p1 (no step advance).
    final near = engine.update(const LatLng(0.0005, 0.0)).distanceMeters;
    expect(near, lessThan(far));
  });

  test('advances to final step after passing the turn point', () {
    final engine = NavigationEngine(route());
    engine.update(p0);
    // Rider is now near/at p1 -> should advance to step 1 (heading to dest).
    final state = engine.update(p1);
    expect(engine.currentStepIndex, 1);
    expect(state.direction, DeviceDirection.up);
    expect(state.distanceMeters, greaterThan(100));
  });

  test('overshooting the turn point still advances the step', () {
    final engine = NavigationEngine(route());
    engine.update(p0);
    // Jump clearly past the midpoint of p1..p2 (0.0015) toward p2, so the
    // rider is closer to the next maneuver point than the current one.
    final state = engine.update(const LatLng(0.0016, 0.0));
    expect(engine.currentStepIndex, 1);
    expect(state.direction, DeviceDirection.up);
  });

  test('only emits ARRIVED at the destination', () {
    final engine = NavigationEngine(route());
    engine.update(p0);
    engine.update(p1);
    final state = engine.update(p2); // arrive at destination
    expect(state.direction, DeviceDirection.arrived);
    expect(engine.isFinished, isTrue);
  });

  test('distance is never negative', () {
    final engine = NavigationEngine(route());
    final state = engine.update(p2);
    expect(state.distanceMeters, greaterThanOrEqualTo(0));
  });

  test('near the route is not off-route', () {
    final engine = NavigationEngine(route());
    expect(engine.isOffRoute(const LatLng(0.0004, 0.0001)), isFalse);
  });

  test('far from the route is off-route', () {
    final engine = NavigationEngine(route());
    expect(engine.isOffRoute(const LatLng(0.0004, 0.0020)), isTrue);
  });

  test('off-route check follows the remaining route after advancing', () {
    final engine = NavigationEngine(route());
    engine.update(p1);
    expect(engine.currentStepIndex, 1);
    expect(engine.isOffRoute(p0), isTrue);
    expect(engine.isOffRoute(const LatLng(0.0015, 0.0)), isFalse);
  });

  test('mini-map includes a bend beyond 100 m in the 200 m preview', () {
    final engine = NavigationEngine(const [
      RouteStep(
        direction: DeviceDirection.right,
        start: LatLng(0, 0),
        end: LatLng(0.001, 0.001),
        distanceMeters: 222,
        geometry: [LatLng(0, 0), LatLng(0.001, 0), LatLng(0.001, 0.001)],
      ),
    ]);
    final points = engine.update(const LatLng(0, 0)).routePreviewPoints;

    expect(NavigationEngine.routePreviewDistanceMeters, 200);
    expect(points.take(2), [640, 340]);
    // The bend is about 111 m ahead; the eastbound section must be visible.
    expect(points[points.length - 2], greaterThan(640));
    expect(points.last, inInclusiveRange(150, 170));
  });

  test('route preview points stay inside the top mini-map bounds', () {
    final engine = NavigationEngine(route());
    final state = engine.update(p0);
    final points = state.routePreviewPoints;

    expect(points.length, NavigationEngine.routePreviewMaxPoints * 2);

    for (var i = 0; i < points.length; i += 2) {
      expect(points[i], inInclusiveRange(180, 1100));
      expect(points[i + 1], inInclusiveRange(20, 340));
    }
  });

  test('route preview points are evenly spaced along the road', () {
    // Straight north for 300 m: the 200 m preview is split into equal steps,
    // finer than one mini-map unit.
    final engine = NavigationEngine(const [
      RouteStep(
        direction: DeviceDirection.up,
        start: LatLng(0, 0),
        end: LatLng(0.0027, 0),
        distanceMeters: 300,
      ),
    ]);
    final points = engine.update(const LatLng(0, 0)).routePreviewPoints;

    expect(points.length, NavigationEngine.routePreviewMaxPoints * 2);
    expect(points.first, 640);
    expect(points[1], 340);
    expect(points[points.length - 1], 20);
    for (var i = 2; i < points.length; i += 2) {
      expect(points[i], 640);
      // 320 tenths over 19 steps: 16 or 17 each after rounding.
      expect(points[i - 1] - points[i + 1], inInclusiveRange(16, 17));
    }
  });

  test('nearby side roads are projected into mini-map segment coordinates', () {
    final engine = NavigationEngine(
      route(),
      sideRoads: const [
        RoadSegment(
          start: LatLng(0.0005, -0.0004),
          end: LatLng(0.0005, 0.0004),
        ),
      ],
    );
    final state = engine.update(p0);
    final roads = state.sideRoadPreviewPoints;

    // A crossing road produces two route-anchored arms.
    expect(roads.length, 8);
    expect(roads[0], inInclusiveRange(180, 1100));
    expect(roads[1], inInclusiveRange(20, 340));
    expect(roads[2], inInclusiveRange(180, 1100));
    expect(roads[3], inInclusiveRange(20, 340));
  });

  test('side-road direction does not depend on the real road length', () {
    List<int> preview(double halfWidth) => NavigationEngine(
          route(),
          sideRoads: [
            RoadSegment(
              start: LatLng(0.0005, -halfWidth),
              end: LatLng(0.0005, halfWidth),
            ),
          ],
        ).update(p0).sideRoadPreviewPoints;

    expect(preview(0.00012), isNotEmpty);
    expect(preview(0.00012), preview(0.0004));
  });

  test('parallel nearby roads are not emitted as junctions', () {
    final engine = NavigationEngine(
      route(),
      sideRoads: const [
        RoadSegment(
          start: LatLng(0.0001, 0.0001),
          end: LatLng(0.0008, 0.0001),
        ),
      ],
    );

    expect(engine.update(p0).sideRoadPreviewPoints, isEmpty);
  });

  group('distance to the turn follows the road', () {
    // A hairpin: ~300 m north, ~30 m east, ~300 m back south. The turn at
    // its end is only ~30 m from the start in a straight line.
    const d = 0.0001; // ~11 m
    final hairpin = [
      for (var i = 0; i <= 27; i++) LatLng(i * d, 0),
      const LatLng(27 * d, 0.00027),
      for (var i = 27; i >= 0; i--) LatLng(i * d, 0.00027),
    ];
    final turn = hairpin.last;
    const after = LatLng(0, 0.0012);
    List<RouteStep> hairpinRoute() => [
          RouteStep(
            direction: DeviceDirection.up,
            start: hairpin.first,
            end: turn,
            distanceMeters: 630,
            geometry: hairpin,
          ),
          RouteStep(
            direction: DeviceDirection.left,
            start: turn,
            end: after,
            distanceMeters: 104,
          ),
        ];

    test('a hairpin announces road distance, not the straight line', () {
      final engine = NavigationEngine(hairpinRoute());
      // ~100 m up the outbound leg: ~200 + 30 + 300 m of road remain,
      // although the turn is only ~104 m away in a straight line.
      final state = engine.update(const LatLng(9 * d, 0));
      expect(state.direction, DeviceDirection.left);
      expect(state.distanceMeters, inInclusiveRange(510, 550));
    });

    test('GPS drift towards the return leg does not jump ahead', () {
      final engine = NavigationEngine(hairpinRoute());
      engine.update(const LatLng(9 * d, 0));
      // 20 m east of the outbound leg, 10 m from the return leg. Matching the
      // nearest leg would announce ~100 m; progress only moves forward.
      final state = engine.update(const LatLng(9 * d, 0.00018));
      expect(state.distanceMeters, greaterThan(450));
    });

    test('a route joined part-way along re-finds the rider', () {
      // Seeded at the route start (as selectRoute does), then the first real
      // fix is far beyond the forward search window.
      final shape = [for (var i = 0; i <= 200; i++) LatLng(i * d, 0)];
      final engine = NavigationEngine([
        RouteStep(
          direction: DeviceDirection.up,
          start: shape.first,
          end: shape.last,
          distanceMeters: 2224,
          geometry: shape,
        ),
        const RouteStep(
          direction: DeviceDirection.right,
          start: LatLng(200 * d, 0),
          end: LatLng(200 * d, 0.001),
          distanceMeters: 111,
        ),
      ]);
      engine.update(shape.first);
      final state = engine.update(shape[140]); // ~1.56 km in, ~667 m to go
      expect(state.distanceMeters, inInclusiveRange(650, 685));
    });
  });

  group('side roads on a long, densely sampled route', () {
    // 4 km north along longitude 0, one vertex every ~2.2 m.
    const step = 0.00002;
    final shape = [for (var i = 0; i <= 2000; i++) LatLng(i * step, 0)];
    List<RouteStep> longRoute() => [
          RouteStep(
            direction: DeviceDirection.up,
            start: shape.first,
            end: shape[1000],
            distanceMeters: 2224,
            geometry: shape.sublist(0, 1001),
          ),
          RouteStep(
            direction: DeviceDirection.left,
            start: shape[1000],
            end: shape.last,
            distanceMeters: 2224,
            geometry: shape.sublist(1000),
          ),
        ];
    RoadSegment crossing(double latitude) => RoadSegment(
          start: LatLng(latitude, -0.0004),
          end: LatLng(latitude, 0.0004),
        );
    const rider = LatLng(0.0003, 0); // ~33 m along the route

    test('roads far down the trip do not change the preview', () {
      final near = crossing(0.0012); // ~100 m ahead of the rider
      final far = [for (var i = 0; i < 200; i++) crossing(0.006 + i * 0.00015)];
      final withFar = NavigationEngine(longRoute(), sideRoads: [near, ...far])
          .update(rider)
          .sideRoadPreviewPoints;
      final nearOnly = NavigationEngine(longRoute(), sideRoads: [near])
          .update(rider)
          .sideRoadPreviewPoints;
      expect(nearOnly, isNotEmpty);
      expect(withFar, nearOnly);
    });

    test('a junction just behind the rider is still drawn', () {
      // ~15 m behind, several vertices back: inside the 20 m the preview
      // keeps behind the rider, outside the segment the rider is on.
      final roads = NavigationEngine(longRoute(),
              sideRoads: [crossing(0.0003 - 0.000135)])
          .update(rider)
          .sideRoadPreviewPoints;
      expect(roads, isNotEmpty);
    });
  });

  test('roads disconnected from the selected route are not emitted', () {
    final engine = NavigationEngine(
      route(),
      sideRoads: const [
        RoadSegment(
          start: LatLng(0.0005, 0.0003),
          end: LatLng(0.0005, 0.0006),
        ),
      ],
    );

    expect(engine.update(p0).sideRoadPreviewPoints, isEmpty);
  });
}
