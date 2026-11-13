import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/route_geometry.dart';

// Local metres -> coordinates near (0, 0); x east, y north.
LatLng p(double x, double y) => LatLng(y / 111320.0, x / 111320.0);

void main() {
  test('projects onto a segment and clamps to its ends', () {
    final middle = RouteGeometry.projectToSegment(
      p(30, 40),
      p(0, 0),
      p(0, 100),
    );
    expect(middle.distanceMeters, closeTo(30, 0.1));
    expect(middle.projected.distanceTo(p(0, 40)), lessThan(0.1));

    final beyond = RouteGeometry.projectToSegment(
      p(0, 130),
      p(0, 0),
      p(0, 100),
    );
    expect(beyond.projected.distanceTo(p(0, 100)), lessThan(0.1));
    expect(
      RouteGeometry.distanceToSegmentMeters(p(0, 130), p(0, 0), p(0, 100)),
      closeTo(30, 0.1),
    );
  });

  test('a zero-length segment measures to its single point', () {
    final point = RouteGeometry.projectToSegment(p(3, 4), p(0, 0), p(0, 0));
    expect(point.distanceMeters, closeTo(5, 0.1));
    expect(
      RouteGeometry.distanceToSegmentMeters(p(3, 4), p(0, 0), p(0, 0)),
      closeTo(5, 0.1),
    );
  });

  test('the closest segment of a polyline is found with its index', () {
    final line = [p(0, 0), p(0, 100), p(100, 100)];
    final closest = RouteGeometry.closestSegment(p(60, 90), line)!;
    expect(closest.segmentIndex, 1);
    expect(closest.distanceMeters, closeTo(10, 0.1));
    expect(RouteGeometry.closestSegment(p(0, 0), [p(0, 0)]), isNull);
  });

  test('segments intersect only where both actually cross', () {
    final crossing = RouteGeometry.segmentIntersection(
      p(-50, 50),
      p(50, 50),
      p(0, 0),
      p(0, 100),
    )!;
    expect(crossing.distanceTo(p(0, 50)), lessThan(0.1));
    // Would cross if extended.
    expect(
      RouteGeometry.segmentIntersection(
        p(10, 50),
        p(50, 50),
        p(0, 0),
        p(0, 100),
      ),
      isNull,
    );
    // Parallel.
    expect(
      RouteGeometry.segmentIntersection(p(5, 0), p(5, 100), p(0, 0), p(0, 100)),
      isNull,
    );
  });

  test('bearing is clockwise from north', () {
    expect(RouteGeometry.bearingRadians(p(0, 0), p(0, 100)), closeTo(0, 1e-6));
    expect(
      RouteGeometry.bearingRadians(p(0, 0), p(100, 0)),
      closeTo(1.5708, 1e-3),
    );
  });
}
