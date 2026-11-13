import 'dart:math' as math;

import '../models/lat_lng.dart';

/// A point projected onto a road segment.
class SegmentProjection {
  const SegmentProjection({
    required this.projected,
    required this.distanceMeters,
  });

  final LatLng projected;
  final double distanceMeters;
}

/// The segment of a polyline closest to a position.
class ClosestSegment {
  const ClosestSegment({
    required this.segmentIndex,
    required this.projected,
    required this.distanceMeters,
  });

  final int segmentIndex;
  final LatLng projected;
  final double distanceMeters;
}

/// Plane geometry on short road segments. Coordinates are treated as flat
/// around each segment, which is accurate at the scale of a street.
class RouteGeometry {
  const RouteGeometry._();

  /// Metres per degree of latitude.
  static const latScale = 111320.0;

  static double toRad(double deg) => deg * math.pi / 180.0;

  static LatLng interpolate(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );

  /// How far along a -> b (0..1) the point nearest to [p] lies, or null for
  /// a segment with no length.
  static double? _nearestT(LatLng p, LatLng a, LatLng b) {
    final lngScale = latScale * math.cos(toRad((a.latitude + b.latitude) / 2));
    final px = (p.longitude - a.longitude) * lngScale;
    final py = (p.latitude - a.latitude) * latScale;
    final bx = (b.longitude - a.longitude) * lngScale;
    final by = (b.latitude - a.latitude) * latScale;
    final lengthSquared = bx * bx + by * by;
    if (lengthSquared == 0) return null;
    return ((px * bx + py * by) / lengthSquared).clamp(0.0, 1.0);
  }

  static SegmentProjection projectToSegment(LatLng p, LatLng a, LatLng b) {
    final t = _nearestT(p, a, b);
    final projected = t == null ? a : interpolate(a, b, t);
    return SegmentProjection(
      projected: projected,
      distanceMeters: p.distanceTo(projected),
    );
  }

  /// Flat-plane distance from [p] to the segment a -> b.
  static double distanceToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final t = _nearestT(p, a, b);
    if (t == null) return p.distanceTo(a);
    final lngScale = latScale * math.cos(toRad((a.latitude + b.latitude) / 2));
    final dx =
        (p.longitude - a.longitude - (b.longitude - a.longitude) * t) *
        lngScale;
    final dy =
        (p.latitude - a.latitude - (b.latitude - a.latitude) * t) * latScale;
    return math.sqrt(dx * dx + dy * dy);
  }

  static ClosestSegment? closestSegment(LatLng position, List<LatLng> points) {
    ClosestSegment? best;
    for (var i = 0; i < points.length - 1; i++) {
      final projection = projectToSegment(position, points[i], points[i + 1]);
      if (best == null || projection.distanceMeters < best.distanceMeters) {
        best = ClosestSegment(
          segmentIndex: i,
          projected: projection.projected,
          distanceMeters: projection.distanceMeters,
        );
      }
    }
    return best;
  }

  /// Where a -> b crosses c -> d, or null when they do not cross.
  static LatLng? segmentIntersection(LatLng a, LatLng b, LatLng c, LatLng d) {
    final abX = b.longitude - a.longitude;
    final abY = b.latitude - a.latitude;
    final cdX = d.longitude - c.longitude;
    final cdY = d.latitude - c.latitude;
    final denominator = abX * cdY - abY * cdX;
    // Parallel within floating-point noise of coordinate differences.
    if (denominator.abs() < 1e-15) return null;

    final acX = c.longitude - a.longitude;
    final acY = c.latitude - a.latitude;
    final roadT = (acX * cdY - acY * cdX) / denominator;
    final routeT = (acX * abY - acY * abX) / denominator;
    if (roadT < 0 || roadT > 1 || routeT < 0 || routeT > 1) return null;
    return interpolate(a, b, roadT);
  }

  /// Initial great-circle bearing a -> b, in radians clockwise from north.
  static double bearingRadians(LatLng a, LatLng b) {
    final lat1 = toRad(a.latitude);
    final lat2 = toRad(b.latitude);
    final deltaLongitude = toRad(b.longitude - a.longitude);
    final y = math.sin(deltaLongitude) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLongitude);
    return math.atan2(y, x);
  }
}
