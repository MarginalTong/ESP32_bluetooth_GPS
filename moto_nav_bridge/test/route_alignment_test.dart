import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/route_alignment.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';

void main() {
  NavigationFix fix(double lat, double lng, double heading) =>
      NavigationFix(lat, lng,
          heading: heading, accuracy: 5, speed: 3, timestamp: DateTime.now());
  const a = LatLng(0, 0), b = LatLng(0.001, 0), c = LatLng(0.001, 0.001);
  const route = RouteCandidate(steps: [
    RouteStep(
        direction: DeviceDirection.up, start: a, end: b, distanceMeters: 111),
    RouteStep(
        direction: DeviceDirection.right,
        start: b,
        end: c,
        distanceMeters: 111),
  ]);
  test('latency progress trims passed turn only when on outgoing road', () {
    final result = RouteAlignment.trim(route, a, fix(0.001, 0.0001, 90));
    expect(result.steps.length, 1);
    expect(result.steps.first.start.longitude, closeTo(0.0001, 0.000001));
  });
  test('opposite heading alone must not delete required route', () {
    expect(
        RouteAlignment.conflictsWithCourse(route, fix(0.0001, 0, 180)), isTrue);
    expect(RouteAlignment.trim(route, a, fix(0.0001, 0, 180)), same(route));
  });
  test('nearby parallel road must not be connected by trimming', () {
    expect(RouteAlignment.trim(route, a, fix(0.0005, 0.0004, 0)), same(route));
  });
  test('explicit first U-turn survives trimming and renders UTURN', () {
    const turn = RouteCandidate(steps: [
      RouteStep(
          direction: DeviceDirection.uturn,
          start: b,
          end: a,
          distanceMeters: 111)
    ]);
    final p = fix(0.001, 0, 0);
    expect(RouteAlignment.trim(turn, b, p), same(turn));
    expect(NavigationEngine(turn.steps).update(p).direction,
        DeviceDirection.uturn);
  });
  test('turn immediately behind advances only along outgoing direction', () {
    final engine = NavigationEngine(route.steps);
    engine.update(fix(0.001, 0.00005, 90));
    expect(engine.currentStepIndex, 1);
    final wrong = NavigationEngine(route.steps);
    wrong.update(fix(0.00105, 0, 0));
    expect(wrong.currentStepIndex, 0);
  });
}
