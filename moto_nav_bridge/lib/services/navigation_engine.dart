import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/road_segment.dart';
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
  NavigationEngine(
    List<RouteStep> steps, {
    List<RoadSegment> sideRoads = const [],
  })  : _steps = List.unmodifiable(steps),
        _sideRoads = List.unmodifiable(sideRoads),
        assert(steps.isNotEmpty, 'route must have at least one step');

  final List<RouteStep> _steps;
  List<RoadSegment> _sideRoads;

  int _index = 0;
  int _remainingRouteCacheIndex = -1;
  List<LatLng> _remainingRouteCache = const [];

  /// How close (meters) the rider must get to a maneuver point before we
  /// advance to the next step.
  static const double arrivalThresholdMeters = 15.0;

  /// Distance from the current route at which we consider the rider likely to
  /// be off-route. This is intentionally conservative to tolerate GPS drift,
  /// multi-lane roads, and simplified route geometry.
  static const double offRouteThresholdMeters = 60.0;
  static const double routePreviewDistanceMeters = 100.0;
  static const int routePreviewMaxPoints = 6;
  // Two well-chosen junction arms reproduce the cluster-style view and keep
  // the complete JSON below conservative iOS BLE write limits.
  static const int sideRoadPreviewMaxSegments = 2;
  static const double sideRoadConnectionToleranceMeters = 14.0;
  static const double sideRoadMinimumBranchMeters = 8.0;
  static const double sideRoadMinimumCrossingSin = 0.30;
  static const int _previewLeft = 18;
  static const int _previewTop = 2;
  static const int _previewRight = 110;
  static const int _previewBottom = 34;
  static const int _previewCenterX = 64;

  int get currentStepIndex => _index;
  int get stepCount => _steps.length;
  LatLng get currentTarget => _steps[_index].end;
  bool get isFinished =>
      _index >= _steps.length - 1 &&
      _distanceToStepEnd(_steps.last, _lastKnown) != null &&
      _distanceToStepEnd(_steps.last, _lastKnown)! <= arrivalThresholdMeters;

  LatLng? _lastKnown;

  /// Replaces the local road context without resetting maneuver progress.
  void replaceSideRoads(List<RoadSegment> roads) {
    _sideRoads = List.unmodifiable(roads);
  }

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
        _remainingRouteCacheIndex = -1;
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

    // Route and junction previews use the same projection frame. Building it
    // once avoids traversing and projecting the remaining route twice for
    // every high-frequency GPS sample.
    final preview = _buildPreviewFrame(position);
    return NavState(
      direction: dir,
      distanceMeters: dist < 0 ? 0 : dist,
      routePreviewPoints: _routePreviewPoints(preview),
      sideRoadPreviewPoints: _sideRoadPreviewPoints(preview),
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
    final points = _remainingRoutePoints();
    for (var i = 0; i < points.length - 1; i++) {
      best = math.min(
        best,
        _distanceToSegmentMeters(position, points[i], points[i + 1]),
      );
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

  List<int> _routePreviewPoints(_PreviewFrame? preview) {
    if (preview == null) return const [];

    final screen = <({int x, int y})>[];
    for (final point in preview.route) {
      final pointOnScreen = preview.screenPoint(point);
      if (screen.isEmpty ||
          screen.last.x != pointOnScreen.x ||
          screen.last.y != pointOnScreen.y) {
        screen.add(pointOnScreen);
      }
    }

    final sampled = _sampleScreenPoints(screen, routePreviewMaxPoints);
    if (sampled.length < 2) return const [];

    return [
      for (final point in sampled) ...[point.x, point.y],
    ];
  }

  List<int> _sideRoadPreviewPoints(_PreviewFrame? preview) {
    if (_sideRoads.isEmpty) return const [];
    if (preview == null) return const [];

    final candidates = <_SideRoadCandidate>[];
    for (final road in _sideRoads) {
      final connection = _roadConnection(road, preview.remaining);
      if (connection == null ||
          connection.distanceMeters > sideRoadConnectionToleranceMeters) {
        continue;
      }

      final routeVector = preview.vector(
        connection.routeStart,
        connection.routeEnd,
      );
      final anchorMetric = preview.metric(connection.routePoint);
      if (anchorMetric.forward < -20 ||
          anchorMetric.forward > routePreviewDistanceMeters + 25 ||
          anchorMetric.lateral.abs() > 25) {
        continue;
      }

      for (final end in [road.start, road.end]) {
        final length = connection.roadPoint.distanceTo(end);
        if (length < sideRoadMinimumBranchMeters) continue;

        final branchVector = preview.vector(connection.roadPoint, end);
        final denominator = math.sqrt(
          (routeVector.dx * routeVector.dx + routeVector.dy * routeVector.dy) *
              (branchVector.dx * branchVector.dx +
                  branchVector.dy * branchVector.dy),
        );
        if (denominator == 0) continue;
        final crossingSin = (routeVector.dx * branchVector.dy -
                    routeVector.dy * branchVector.dx)
                .abs() /
            denominator;
        if (crossingSin < sideRoadMinimumCrossingSin) continue;

        final a = preview.screenPoint(connection.routePoint);
        final b = preview.screenPoint(end);
        if ((a.x - b.x).abs() + (a.y - b.y).abs() < 5) continue;
        candidates.add(_SideRoadCandidate(
          a: a,
          b: b,
          priority: anchorMetric.forward.abs() +
              connection.distanceMeters * 4 +
              length * 0.05,
        ));
      }
    }

    candidates.sort((a, b) => a.priority.compareTo(b.priority));
    final selected = candidates.take(sideRoadPreviewMaxSegments);
    return [
      for (final segment in selected) ...[
        segment.a.x,
        segment.a.y,
        segment.b.x,
        segment.b.y
      ],
    ];
  }

  static _RoadConnection? _roadConnection(
    RoadSegment road,
    List<LatLng> route,
  ) {
    _RoadConnection? best;
    for (var i = 0; i < route.length - 1; i++) {
      final routeStart = route[i];
      final routeEnd = route[i + 1];
      final crossing = _segmentIntersection(
        road.start,
        road.end,
        routeStart,
        routeEnd,
      );
      if (crossing != null) {
        return _RoadConnection(
          routePoint: crossing,
          roadPoint: crossing,
          routeStart: routeStart,
          routeEnd: routeEnd,
          distanceMeters: 0,
        );
      }

      for (final roadPoint in [road.start, road.end]) {
        final projected = _projectToSegment(roadPoint, routeStart, routeEnd);
        if (best == null || projected.distanceMeters < best.distanceMeters) {
          best = _RoadConnection(
            routePoint: projected.projected,
            roadPoint: roadPoint,
            routeStart: routeStart,
            routeEnd: routeEnd,
            distanceMeters: projected.distanceMeters,
          );
        }
      }
    }
    return best;
  }

  static LatLng? _segmentIntersection(
    LatLng a,
    LatLng b,
    LatLng c,
    LatLng d,
  ) {
    final abX = b.longitude - a.longitude;
    final abY = b.latitude - a.latitude;
    final cdX = d.longitude - c.longitude;
    final cdY = d.latitude - c.latitude;
    final denominator = abX * cdY - abY * cdX;
    if (denominator.abs() < 1e-15) return null;

    final acX = c.longitude - a.longitude;
    final acY = c.latitude - a.latitude;
    final roadT = (acX * cdY - acY * cdX) / denominator;
    final routeT = (acX * abY - acY * abX) / denominator;
    if (roadT < 0 || roadT > 1 || routeT < 0 || routeT > 1) return null;
    return _interpolate(a, b, roadT);
  }

  _PreviewFrame? _buildPreviewFrame(LatLng position) {
    final remaining = _remainingRoutePoints();
    if (remaining.length < 2) return null;

    final closest = _closestSegment(position, remaining);
    if (closest == null) return null;

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

    if (route.length < 2) return null;

    final heading = _bearingRadians(route[0], route[1]);
    const latScale = 111320.0;
    final lngScale =
        latScale * math.cos(_toRad(route[0].latitude).clamp(-1.4, 1.4));
    const scale = (_previewBottom - _previewTop) / routePreviewDistanceMeters;

    return _PreviewFrame(
      route: route,
      remaining: remaining,
      origin: route[0],
      heading: heading,
      lngScale: lngScale,
      scale: scale,
    );
  }

  List<LatLng> _remainingRoutePoints() {
    if (_remainingRouteCacheIndex == _index) return _remainingRouteCache;

    final output = <LatLng>[];
    for (var i = _index; i < _steps.length; i++) {
      for (final point in _geometryForStep(_steps[i])) {
        if (output.isEmpty || output.last.distanceTo(point) > 0.5) {
          output.add(point);
        }
      }
    }
    _remainingRouteCacheIndex = _index;
    _remainingRouteCache = List.unmodifiable(output);
    return _remainingRouteCache;
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

class _PreviewFrame {
  const _PreviewFrame({
    required this.route,
    required this.remaining,
    required this.origin,
    required this.heading,
    required this.lngScale,
    required this.scale,
  });

  final List<LatLng> route;
  final List<LatLng> remaining;
  final LatLng origin;
  final double heading;
  final double lngScale;
  final double scale;

  ({double forward, double lateral}) metric(LatLng point) {
    const latScale = 111320.0;
    final east = (point.longitude - origin.longitude) * lngScale;
    final north = (point.latitude - origin.latitude) * latScale;

    return (
      forward: east * math.sin(heading) + north * math.cos(heading),
      lateral: east * math.cos(heading) - north * math.sin(heading),
    );
  }

  ({double dx, double dy}) vector(LatLng from, LatLng to) {
    final a = metric(from);
    final b = metric(to);
    return (dx: b.lateral - a.lateral, dy: b.forward - a.forward);
  }

  ({int x, int y}) screenPoint(LatLng point) {
    final m = metric(point);
    return (
      x: (NavigationEngine._previewCenterX + m.lateral * scale)
          .round()
          .clamp(NavigationEngine._previewLeft, NavigationEngine._previewRight),
      y: (NavigationEngine._previewBottom - m.forward * scale)
          .round()
          .clamp(NavigationEngine._previewTop, NavigationEngine._previewBottom),
    );
  }
}

class _SideRoadCandidate {
  const _SideRoadCandidate({
    required this.a,
    required this.b,
    required this.priority,
  });

  final ({int x, int y}) a;
  final ({int x, int y}) b;
  final double priority;
}

class _RoadConnection {
  const _RoadConnection({
    required this.routePoint,
    required this.roadPoint,
    required this.routeStart,
    required this.routeEnd,
    required this.distanceMeters,
  });

  final LatLng routePoint;
  final LatLng roadPoint;
  final LatLng routeStart;
  final LatLng routeEnd;
  final double distanceMeters;
}
