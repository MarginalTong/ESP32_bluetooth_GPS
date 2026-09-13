import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';

// A short synthetic route along a line of latitude near the equator so that
// 1 degree of longitude is a large, easy-to-reason-about distance. We keep the
// points close together and check relative behavior rather than exact meters.
void main() {
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
}
