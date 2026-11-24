import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/map_preview.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';
import 'package:moto_nav_bridge/services/route_geometry.dart';
import 'package:moto_nav_bridge/services/route_preview_progress.dart';
import 'package:moto_nav_bridge/services/side_road_preview.dart';

// Reproducible local-metre fixture. Selected Y arm: (0,100) -> (120,260).
// Unselected arm: (0,100) -> (-60,180). No routing or network is involved.
LatLng p(double x, double y) => LatLng(y / 111320, x / 111320);
NavigationFix fix(double x, double y, {double heading = 0, double speed = 8}) =>
    NavigationFix(
      y / 111320,
      x / 111320,
      heading: heading,
      speed: speed,
      accuracy: 3,
      timestamp: DateTime.now(),
    );
RouteStep step(LatLng a, LatLng b) => RouteStep(
  direction: DeviceDirection.up,
  start: a,
  end: b,
  geometry: [a, b],
  distanceMeters: a.distanceTo(b).round(),
);

void main() {
  test('slow approach does not snap the map to an early advanced maneuver', () {
    final nav = NavigationEngine(
      [step(p(0, 0), p(0, 100)), step(p(0, 100), p(200, 100))],
      sideRoads: [RoadSegment(start: p(-60, 100), end: p(0, 100))],
    );
    nav.update(fix(0, 70, speed: 0.3));
    final roads = nav.update(fix(0, 95, speed: 0.3)).sideRoadPreviewPoints;
    // The maneuver may already be selected, but its physical junction is
    // still 5 m ahead of the rider, not underneath the cursor.
    expect(roads.take(2), [640, 332]);
  });

  test('a passed junction is not reattached to the next maneuver endpoint', () {
    final nav = NavigationEngine(
      [
        step(p(0, 0), p(0, 100)),
        step(p(0, 100), p(5, 100)),
        step(p(5, 100), p(200, 100)),
      ],
      sideRoads: [RoadSegment(start: p(-60, 90), end: p(0, 90))],
    );
    nav.update(fix(0, 70));
    final roads = nav.update(fix(7, 100, heading: 90)).sideRoadPreviewPoints;
    expect(nav.currentStepIndex, 2);
    expect(roads, hasLength(4));
    // World junction (0,90), not next step's (5,100). Relative to eastbound
    // rider (7,100), it is 17 m back along road and 10 m to the right.
    expect(roads[0], closeTo(656, 1));
    expect(roads[1], closeTo(351.2, 1));
    expect(
      nav.update(fix(12, 100, heading: 90)).sideRoadPreviewPoints,
      isEmpty,
    );
  });

  test('Y junction retreats behind the cursor across maneuver transition', () {
    final nav = NavigationEngine(
      [step(p(0, 0), p(0, 100)), step(p(0, 100), p(120, 260))],
      sideRoads: [RoadSegment(start: p(0, 100), end: p(-60, 180))],
    );
    nav.update(fix(0, 80));
    final before = nav.update(fix(0, 95)).sideRoadPreviewPoints;
    expect(nav.currentStepIndex, 0);
    expect(before[1], lessThan(340));
    var lastY = 340;
    for (var metres = 1; metres <= 19; metres++) {
      final state = nav.update(
        fix(metres * 0.6, 100 + metres * 0.8, heading: 36.87),
      );
      expect(nav.currentStepIndex, 1);
      final roads = state.sideRoadPreviewPoints;
      expect(roads, hasLength(4));
      // Not pinned at the rider's y=340. Fixed-world junction retreats at
      // 1.6 tenths/unit per metre, until the behind-window clips it away.
      expect(roads[1], closeTo(340 + metres * 1.6, 1));
      expect(roads[1], greaterThanOrEqualTo(lastY));
      expect(roads[0], closeTo(640, 1));
      lastY = roads[1];
      expect(state.routePreviewPoints.take(2), [640, 340]);
    }
    expect(
      nav.update(fix(18, 124, heading: 36.87)).sideRoadPreviewPoints,
      isEmpty,
    );
  });

  for (final entry in <String, List<RoadSegment>>{
    'T': [RoadSegment(start: p(0, 100), end: p(80, 100))],
    'cross': [RoadSegment(start: p(-80, 100), end: p(80, 100))],
    'multiple exits': [
      RoadSegment(start: p(-80, 100), end: p(80, 100)),
      RoadSegment(start: p(-80, 140), end: p(80, 140)),
    ],
  }.entries) {
    test(
      '${entry.key} anchors share the route frame before and after passing',
      () {
        final route = [p(0, 0), p(0, 300)];
        for (final y in [90.0, 100.0, 105.0, 115.0]) {
          final preview = MapPreview.build(p(0, y), route)!;
          final roads = SideRoadPreview.points(preview, entry.value);
          expect(
            roads,
            hasLength(entry.value.length * 4 * (entry.key == 'T' ? 1 : 2)),
          );
          for (var i = 0; i < roads.length; i += 4) {
            final worldY = y + (340 - roads[i + 1]) / 1.6;
            expect([100.0, 140.0].any((v) => (worldY - v).abs() < 0.7), isTrue);
            expect(roads[i], 640);
          }
        }
      },
    );
  }

  test(
    'preview uses the current-step projection, not a nearer future return',
    () {
      final nav = NavigationEngine(
        [
          step(p(0, 0), p(0, 500)),
          step(p(0, 500), p(20, 500)),
          step(p(20, 500), p(20, 0)),
        ],
        sideRoads: [RoadSegment(start: p(-40, 150), end: p(0, 150))],
      );
      final state = nav.update(fix(18, 100));
      expect(state.sideRoadPreviewPoints.take(2), [640, 260]);
    },
  );

  test(
    'along-distance jitter is held, real progress and retreat are accepted',
    () {
      final progress = RoutePreviewProgress();
      final points = [p(0, 0), p(0, 300)];
      ClosestSegment sample(double y, {double speed = 8, int step = 0}) {
        final position = fix(0, y, speed: speed);
        return progress.update(
          position,
          points,
          step,
          RouteGeometry.closestSegment(position, points)!,
        );
      }

      expect(sample(100).projected.distanceTo(p(0, 100)), lessThan(0.1));
      for (final y in [99.0, 101.0, 98.0, 102.0]) {
        expect(
          sample(y, speed: 0).projected.distanceTo(p(0, 100)),
          lessThan(0.1),
        );
      }
      expect(sample(104).projected.distanceTo(p(0, 104)), lessThan(0.1));
      expect(sample(102).projected.distanceTo(p(0, 104)), lessThan(0.1));
      expect(sample(90).projected.distanceTo(p(0, 90)), lessThan(0.1));
      expect(sample(1, step: 1).projected.distanceTo(p(0, 1)), lessThan(0.1));
    },
  );
}
