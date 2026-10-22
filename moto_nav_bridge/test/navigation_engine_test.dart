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
    expect(points.take(2), [64, 34]);
    // The bend is about 111 m ahead; the eastbound section must be visible.
    expect(points[points.length - 2], greaterThan(64));
    expect(points.last, inInclusiveRange(15, 17));
  });

  test('route preview points stay inside the top mini-map bounds', () {
    final engine = NavigationEngine(route());
    final state = engine.update(p0);
    final points = state.routePreviewPoints;

    expect(points.length % 2, 0);
    expect(points.length, lessThanOrEqualTo(12));

    for (var i = 0; i < points.length; i += 2) {
      expect(points[i], inInclusiveRange(18, 110));
      expect(points[i + 1], inInclusiveRange(2, 34));
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
    expect(roads[0], inInclusiveRange(18, 110));
    expect(roads[1], inInclusiveRange(2, 34));
    expect(roads[2], inInclusiveRange(18, 110));
    expect(roads[3], inInclusiveRange(2, 34));
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
