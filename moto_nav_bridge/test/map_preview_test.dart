import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/services/map_preview.dart';
import 'package:moto_nav_bridge/services/side_road_preview.dart';

// Local metres -> coordinates near (0, 0); x east, y north.
LatLng p(double x, double y) => LatLng(y / 111320.0, x / 111320.0);

void main() {
  // 500 m due north.
  final north = [p(0, 0), p(0, 250), p(0, 500)];

  test('there is no frame without a route ahead', () {
    expect(MapPreview.build(p(0, 0), [p(0, 0)]), isNull);
    expect(MapPreview.build(p(0, 0), [p(0, 0), p(0, 0)]), isNull);
  });

  test('the frame is heading-up from the rider and 200 m long', () {
    final preview = MapPreview.build(p(3, 100), north)!;
    final ahead = preview.metric(p(0, 150));
    expect(ahead.forward, closeTo(50, 0.5));
    expect(ahead.lateral, closeTo(0, 0.5));
    expect(preview.metric(p(20, 100)).lateral, closeTo(20, 0.5));
    expect(preview.route.last.distanceTo(p(0, 300)), lessThan(0.5));
  });

  test('the rider is at the bottom centre and the far end at the top', () {
    final points = MapPreview.build(p(0, 100), north)!.routePoints();
    expect(points, hasLength(MapPreview.routeMaxPoints * 2));
    expect(points.sublist(0, 2), [640, 340]);
    expect(points.sublist(points.length - 2), [640, 20]);
  });

  group('side roads', () {
    RoadSegment crossAt(double y, {double half = 60}) =>
        RoadSegment(start: p(-half, y), end: p(half, y));

    test('a crossing gives a left and a right arm from the junction', () {
      final preview = MapPreview.build(p(0, 0), north);
      final arms = SideRoadPreview.points(preview, [crossAt(100)]);
      expect(arms, hasLength(8));
      // Both start at the junction: centre column, half way up.
      expect([arms[0], arms[1]], [640, 180]);
      expect([arms[4], arms[5]], [640, 180]);
      expect({arms[2], arms[6]}, {540, 740});
      expect([arms[3], arms[7]], [180, 180]);
    });

    test('nearer junctions come first, up to the segment limit', () {
      final preview = MapPreview.build(p(0, 0), north);
      final arms = SideRoadPreview.points(preview, [
        crossAt(150),
        crossAt(50),
        crossAt(100),
      ]);
      expect(arms, hasLength(SideRoadPreview.maxSegments * 4));
      // y = 340 - forward * 0.16 * 10: 50 m ahead is 260.
      expect(arms[1], 260);
    });

    test(
      'roads that miss, run alongside or lie beyond the preview are out',
      () {
        final preview = MapPreview.build(p(0, 0), north);
        expect(
          SideRoadPreview.points(preview, [
            RoadSegment(start: p(40, 100), end: p(120, 100)), // 40 m short
            RoadSegment(start: p(0, 100), end: p(5, 200)), // nearly parallel
            crossAt(260), // past 200 m + margin
            crossAt(-40), // well behind
          ]),
          isEmpty,
        );
        expect(SideRoadPreview.points(null, [crossAt(100)]), isEmpty);
      },
    );
  });
}
