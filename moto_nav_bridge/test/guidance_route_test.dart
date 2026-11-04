import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_curves.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_route.dart';

import 'voice_guidance_planner_test.dart' show step;

void main() {
  test('maneuver kinds come from the Valhalla type', () {
    final route = GuidanceRoute.fromSteps([
      step(DeviceDirection.up, [(0, 0), (0, 100)], raw: 'valhalla:1'),
      step(DeviceDirection.bearRight, [
        (0, 100),
        (50, 200),
      ], raw: 'valhalla:23'),
      step(DeviceDirection.up, [(50, 200), (50, 300)], raw: 'valhalla:8'),
      step(DeviceDirection.left, [(50, 300), (-50, 300)]),
    ]);
    expect(route.maneuvers.map((m) => m.kind), [
      ManeuverKind.fork,
      ManeuverKind.silent,
      ManeuverKind.basic,
      ManeuverKind.destination,
    ]);
    expect(route.maneuvers.first.alongMeters, closeTo(100, 1));
    expect(
      route.maneuvers.last.alongMeters,
      closeTo(route.stepEndAlong.last, 1),
    );
  });

  test('the following maneuver skips silent ones and reports the gap', () {
    final route = GuidanceRoute.fromSteps([
      step(DeviceDirection.up, [(0, 0), (0, 100)], raw: 'valhalla:1'),
      step(DeviceDirection.right, [(0, 100), (100, 100)], raw: 'valhalla:10'),
      step(DeviceDirection.up, [(100, 100), (200, 100)], raw: 'valhalla:8'),
      step(DeviceDirection.left, [(200, 100), (200, 200)], raw: 'valhalla:15'),
    ]);
    final next = route.following(route.upcoming(0)!)!;
    expect(next.maneuver.kind, ManeuverKind.turn);
    expect(next.maneuver.direction, DeviceDirection.left);
    expect(next.gapMeters, closeTo(200, 1));
    expect(route.upcoming(-1), isNull);
    expect(route.upcoming(99), isNull);
  });

  test('a bend at a maneuver point is the maneuver, not a curve warning', () {
    // Two sharp corners 100 m apart: a series of bends on its own.
    final steps = [
      step(DeviceDirection.up, [
        (0, 0),
        (0, 300),
        (100, 300),
        (100, 600),
      ], raw: 'valhalla:1'),
    ];
    expect(GuidanceCurves.find(steps, const []), hasLength(1));
    expect(GuidanceCurves.find(steps, const [300, 400]), isEmpty);
  });
}
