import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/route_step.dart';
import 'dart:math' as math;

/// Turns a route + a live position into the [NavState] to show on the device.
///
/// Turn-by-turn model: while traversing step `i` toward its `end`, the rider is
/// told what they will do *at* that end — i.e. the next step's maneuver — with
/// the distance remaining to that point ("in 200 m, turn left"). On the final
/// step the rider is told to keep going until they are actually within the
/// arrival threshold. [DeviceDirection.arrived] is emitted only at the
/// destination, not merely because the route has reached its final leg.
///
/// This class is pure Dart (takes plain [LatLng]s), so it is fully unit-testable
/// without the geolocator plugin.
class NavigationEngine {
  NavigationEngine(List<RouteStep> steps)
      : _steps = List.unmodifiable(steps),
        assert(steps.isNotEmpty, 'route must have at least one step');

  final List<RouteStep> _steps;

  int _index = 0;

  /// How close (meters) the rider must get to a maneuver point before we
  /// advance to the next step.
  static const double arrivalThresholdMeters = 15.0;

  /// Distance from the current route at which we consider the rider likely to
  /// be off-route. This is intentionally conservative to tolerate GPS drift,
  /// multi-lane roads, and simplified route geometry.
  static const double offRouteThresholdMeters = 60.0;
  static const double routePreviewDistanceMeters = 100.0;
  static const int routePreviewMaxPoints = 6;

  int get currentStepIndex => _index;
  int get stepCount => _steps.length;
  LatLng get currentTarget => _steps[_index].end;
  bool get isFinished =>
      _index >= _steps.length - 1 &&
      _distanceToStepEnd(_steps.last, _lastKnown) != null &&
      _distanceToStepEnd(_steps.last, _lastKnown)! <= arrivalThresholdMeters;

  LatLng? _lastKnown;

  /// Computes the [NavState] for the given [position], advancing the current
  /// step when the rider reaches (or overshoots) a maneuver point.
  NavState update(LatLng position) {
    _lastKnown = position;
    final n = _steps.length;

    // Advance while the rider has effectively reached the current step's end,
    // or clearly overshot it toward the next one.
    while (_index < n - 1) {
      final current = _steps[_index];
      final distToCurrentEnd = position.distanceTo(current.end);
      final distToNextEnd = position.distanceTo(_steps[_index + 1].end);

      final reached = distToCurrentEnd <= arrivalThresholdMeters;
      final overshot = distToNextEnd < distToCurrentEnd;
      if (reached || overshot) {
        _index++;
      } else {
        break;
      }
    }

    final target = _steps[_index].end;
    final dist = position.distanceTo(target).round();

    // Otherwise show the maneuver performed at the current step's end, which is
    // the next step's mapped direction. On the final leg, keep showing a
    // forward instruction until the rider is actually at the destination.
    final DeviceDirection dir = (_index >= n - 1)
        ? (dist <= arrivalThresholdMeters
            ? DeviceDirection.arrived
            : DeviceDirection.up)
        : _steps[_index + 1].direction;

    return NavState(
      direction: dir,
      distanceMeters: dist < 0 ? 0 : dist,
      routePreviewPoints: _routePreviewPoints(position),
    );
  }

  bool isOffRoute(LatLng position) =>
      distanceFromRouteMeters(position) > offRouteThresholdMeters;

  /// Returns the shortest distance from [position] to the remaining route.
  ///
  /// Route geometry is simplified to each step's start/end segment, because the
  /// navigation protocol only needs turn points. This is good enough to detect
  /// meaningful deviations without overreacting to normal GPS noise.
  double distanceFromRouteMeters(LatLng position) {
    var best = double.infinity;
    for (var i = _index; i < _steps.length; i++) {
      final points = _geometryForStep(_steps[i]);
      for (var j = 0; j < points.length - 1; j++) {
        best = math.min(
          best,
          _distanceToSegmentMeters(position, points[j], points[j + 1]),
        );
      }
    }
    return best;
  }

  double? _distanceToStepEnd(RouteStep step, LatLng? from) =>
      from?.distanceTo(step.end);

  static double _distanceToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    const latScale = 111320.0;
    final lngScale = latScale * math.cos(_toRad((a.latitude + b.latitude) / 2));

    final px = (p.longitude - a.longitude) * lngScale;
    final py = (p.latitude - a.latitude) * latScale;
    final bx = (b.longitude - a.longitude) * lngScale;
    final by = (b.latitude - a.latitude) * latScale;

    final lengthSquared = bx * bx + by * by;
    if (lengthSquared == 0) return p.distanceTo(a);

    final t = ((px * bx + py * by) / lengthSquared).clamp(0.0, 1.0);
    final closestX = bx * t;
    final closestY = by * t;
    final dx = px - closestX;
    final dy = py - closestY;
    return math.sqrt(dx * dx + dy * dy);
  }

  List<LatLng> _geometryForStep(RouteStep step) =>
      step.geometry.length >= 2 ? step.geometry : [step.start, step.end];

  List<int> _routePreviewPoints(LatLng position) {
    const left = 18;
    const top = 2;
    const right = 110;
    const bottom = 34;
    const centerX = 64;

    final remaining = _remainingRoutePoints();
    if (remaining.length < 2) return const [];

    final closest = _closestSegment(position, remaining);
    if (closest == null) return const [];

    final route = <LatLng>[closest.projected];
    var travelled = 0.0;
    var cursor = closest.projected;

    for (var i = closest.segmentIndex; i < remaining.length - 1; i++) {
      final target = remaining[i + 1];
      final segmentLength = cursor.distanceTo(target);
      if (segmentLength <= 0) continue;

      if (travelled + segmentLength >= routePreviewDistanceMeters) {
        final t = (routePreviewDistanceMeters - travelled) / segmentLength;
        route.add(_interpolate(cursor, target, t));
        break;
      }

      route.add(target);
      travelled += segmentLength;
      cursor = target;
    }

    if (route.length < 2) return const [];

    final heading = _bearingRadians(route[0], route[1]);
    const latScale = 111320.0;
    final lngScale =
        latScale * math.cos(_toRad(route[0].latitude).clamp(-1.4, 1.4));
    const scale = (bottom - top) / routePreviewDistanceMeters;

    final screen = <({int x, int y})>[];
    for (final point in route) {
      final east = (point.longitude - route[0].longitude) * lngScale;
      final north = (point.latitude - route[0].latitude) * latScale;

      final forward = east * math.sin(heading) + north * math.cos(heading);
      final lateral = east * math.cos(heading) - north * math.sin(heading);

      final x = (centerX + lateral * scale).round().clamp(left, right);
      final y = (bottom - forward * scale).round().clamp(top, bottom);

      if (screen.isEmpty || screen.last.x != x || screen.last.y != y) {
        screen.add((x: x, y: y));
      }
    }

    final sampled = _sampleScreenPoints(screen, routePreviewMaxPoints);
    if (sampled.length < 2) return const [];

    return [
      for (final point in sampled) ...[point.x, point.y],
    ];
  }

  List<LatLng> _remainingRoutePoints() {
    final output = <LatLng>[];
    for (var i = _index; i < _steps.length; i++) {
      for (final point in _geometryForStep(_steps[i])) {
        if (output.isEmpty || output.last.distanceTo(point) > 0.5) {
          output.add(point);
        }
      }
    }
    return output;
  }

  _ClosestSegment? _closestSegment(LatLng position, List<LatLng> points) {
    _ClosestSegment? best;
    for (var i = 0; i < points.length - 1; i++) {
      final projection = _projectToSegment(position, points[i], points[i + 1]);
      if (best == null || projection.distanceMeters < best.distanceMeters) {
        best = _ClosestSegment(
          segmentIndex: i,
          projected: projection.projected,
          distanceMeters: projection.distanceMeters,
        );
      }
    }
    return best;
  }

  static _SegmentProjection _projectToSegment(LatLng p, LatLng a, LatLng b) {
    const latScale = 111320.0;
    final lngScale = latScale * math.cos(_toRad((a.latitude + b.latitude) / 2));

    final px = (p.longitude - a.longitude) * lngScale;
    final py = (p.latitude - a.latitude) * latScale;
    final bx = (b.longitude - a.longitude) * lngScale;
    final by = (b.latitude - a.latitude) * latScale;

    final lengthSquared = bx * bx + by * by;
    if (lengthSquared == 0) {
      return _SegmentProjection(projected: a, distanceMeters: p.distanceTo(a));
    }

    final t = ((px * bx + py * by) / lengthSquared).clamp(0.0, 1.0);
    final projected = _interpolate(a, b, t);
    return _SegmentProjection(
      projected: projected,
      distanceMeters: p.distanceTo(projected),
    );
  }

  static LatLng _interpolate(LatLng a, LatLng b, double t) => LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );

  static double _bearingRadians(LatLng a, LatLng b) {
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final deltaLongitude = _toRad(b.longitude - a.longitude);
    final y = math.sin(deltaLongitude) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLongitude);
    return math.atan2(y, x);
  }

  static List<({int x, int y})> _sampleScreenPoints(
    List<({int x, int y})> points,
    int maxPoints,
  ) {
    if (points.length <= maxPoints) return points;
    return [
      for (var i = 0; i < maxPoints; i++)
        points[((points.length - 1) * i / (maxPoints - 1)).round()],
    ];
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;
}

class _ClosestSegment {
  const _ClosestSegment({
    required this.segmentIndex,
    required this.projected,
    required this.distanceMeters,
  });

  final int segmentIndex;
  final LatLng projected;
  final double distanceMeters;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.projected,
    required this.distanceMeters,
  });

  final LatLng projected;
  final double distanceMeters;
}
