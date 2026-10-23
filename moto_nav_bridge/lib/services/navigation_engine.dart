import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/road_segment.dart';
import '../models/route_step.dart';
import 'dart:math' as math;
import 'route_alignment.dart';

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
  int _matchSegment = 0;
  int _matchStep = -1;
  bool reverseTravel = false;
  int _remainingRouteCacheIndex = -1;
  List<LatLng> _remainingRouteCache = const [];

  /// How close (meters) the rider must get to a maneuver point before we
  /// advance to the next step.
  static const double arrivalThresholdMeters = 15.0;

  /// Distance from the current route at which we consider the rider likely to
  /// be off-route. This is intentionally conservative to tolerate GPS drift,
  /// multi-lane roads, and simplified route geometry.
  static const double offRouteThresholdMeters = 60.0;
  // Shared route/side-road scale: show 200 m ahead without changing the BLE
  // coordinate frame or the firmware's map and pointer layout.
  static const double routePreviewDistanceMeters = 200.0;
  // Always this many points, evenly spaced along the road (about 10 m apart),
  // so the display can glide each point to its next position.
  static const int routePreviewMaxPoints = 20;
  // Preview coordinates are sent in tenths of a mini-map unit (one unit is
  // about 6 m): whole units made the route visibly step on the display.
  static const int previewResolution = 10;
  // Two well-chosen junction arms reproduce the cluster-style view and keep
  // the complete JSON below conservative iOS BLE write limits.
  static const int sideRoadPreviewMaxSegments = 2;
  static const double sideRoadConnectionToleranceMeters = 14.0;
  static const double sideRoadMinimumBranchMeters = 8.0;
  static const double sideRoadMinimumCrossingSin = 0.30;
  static const double _sideRoadDirectionPreviewUnits = 10.0;
  // Along-route distance: how far ahead of the last matched segment to look,
  // and how poor a match must be before searching the whole step again.
  static const double _progressSearchAheadMeters = 300.0;
  static const double _progressReseedMeters = 50.0;
  // Junctions up to 20 m behind the rider are still drawn; keep margin.
  static const double _sideRoadWindowBehindMeters = 40.0;
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
      var advance = reached || overshot;
      if (RouteAlignment.usable(position)) {
        final fix = position as NavigationFix;
        final next = _steps[_index + 1];
        final points = RouteAlignment.geometry(next);
        final followsNext = RouteAlignment.aligned(fix, points[0], points[1]);
        // Near a turn is not the same as having completed it. In particular,
        // keep an explicit U-turn until motion follows its outgoing segment.
        final onNext =
            _distanceToSegmentMeters(fix, points[0], points[1]) <= 15;
        advance = RouteAlignment.forward(fix, current.end) < 0 &&
            followsNext &&
            (distToCurrentEnd < arrivalThresholdMeters || (overshot && onNext));
        // A GPS update can miss the entire turn, or the next road can curve
        // away from its first segment. Recover only onto the immediate next
        // step, with a reliable matching course and an unambiguous road match.
        // Do not require its far endpoint to be nearer than the passed turn.
        if (!advance) {
          final match = _closestSegment(fix, points);
          final currentMatch = _closestSegment(fix, _geometryForStep(current));
          if (match != null && currentMatch != null) {
            var progress = 0.0;
            for (var i = 0; i < match.segmentIndex; i++) {
              progress += points[i].distanceTo(points[i + 1]);
            }
            progress += points[match.segmentIndex].distanceTo(match.projected);
            advance = match.distanceMeters <= 15 &&
                currentMatch.distanceMeters > match.distanceMeters + 8 &&
                progress >= arrivalThresholdMeters &&
                RouteAlignment.aligned(fix, points[match.segmentIndex],
                    points[match.segmentIndex + 1]);
          }
        }
      }
      if (advance) {
        _index++;
        _remainingRouteCacheIndex = -1;
      } else {
        break;
      }
    }

    final target = _steps[_index].end;
    final straight = position.distanceTo(target);
    // Announce the distance the rider will actually travel. On a bend or
    // hairpin the straight line to the turn is far shorter than the road.
    // Never report less than the straight line, e.g. when beside the road.
    final dist = math.max(straight, _remainingStepMeters(position)).round();

    // Otherwise show the maneuver performed at the current step's end, which is
    // the next step's mapped direction. On the final leg, keep showing a
    // forward instruction until the rider is actually at the destination.
    // Arrival is a proximity test, so it keeps the straight-line distance.
    DeviceDirection dir = (_index >= n - 1)
        ? (straight.round() <= arrivalThresholdMeters
            ? DeviceDirection.arrived
            : DeviceDirection.up)
        : _steps[_index + 1].direction;
    if (_steps[_index].direction == DeviceDirection.uturn &&
        RouteAlignment.usable(position)) {
      final points = RouteAlignment.geometry(_steps[_index]);
      if (!RouteAlignment.aligned(
          position as NavigationFix, points[0], points[1])) {
        dir = DeviceDirection.uturn;
      }
    }

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

  bool isOffRoute(LatLng position) {
    final distance = distanceFromRouteMeters(position);
    lastRouteDistanceMeters = distance;
    final accuracy = position is NavigationFix ? position.accuracy : null;
    final threshold = accuracy == null || !accuracy.isFinite || accuracy < 0
        ? offRouteThresholdMeters
        // Avoid a 25 -> 50 m jump at 10 m reported accuracy. A few metres of
        // road-centreline offset must not invalidate a newly returned route.
        : (25.0 + accuracy).clamp(30.0, 50.0).toDouble();
    lastOffRouteThresholdMeters = threshold;
    return distance > threshold || reverseTravel;
  }

  double? lastRouteDistanceMeters;
  double? lastOffRouteThresholdMeters;
  double? lastCourseDeltaDegrees;

  /// Match only the current geometry segment and three forward segments.
  /// A new engine seeds progress within its current maneuver once; subsequent
  /// fixes cannot jump across a distant bend in the remaining route.
  double distanceFromRouteMeters(LatLng position) {
    var best = double.infinity;
    final points = _remainingRoutePoints();
    reverseTravel = false;
    lastCourseDeltaDegrees = null;
    if (points.length < 2) return best;
    if (_matchStep != _index) {
      _matchSegment = 0;
      _matchStep = _index;
      final count = _geometryForStep(_steps[_index]).length - 1;
      for (var i = 0; i < math.min(count, points.length - 1); i++) {
        final distance =
            _distanceToSegmentMeters(position, points[i], points[i + 1]);
        if (distance < best) {
          best = distance;
          _matchSegment = i;
        }
      }
    }
    best = double.infinity;
    var selected = _matchSegment;
    for (var i = _matchSegment;
        i < math.min(_matchSegment + 4, points.length - 1);
        i++) {
      final distance =
          _distanceToSegmentMeters(position, points[i], points[i + 1]);
      if (distance < best) {
        best = distance;
        selected = i;
      }
    }
    if (position is NavigationFix && position.reliableCourse) {
      final a = points[selected];
      final b = points[selected + 1];
      final dx = (b.longitude - a.longitude) * math.cos(_toRad(a.latitude));
      final dy = b.latitude - a.latitude;
      final bearing = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
      final delta = ((position.heading - bearing + 540) % 360 - 180).abs();
      lastCourseDeltaDegrees = delta;
      reverseTravel = best < 60 && delta > 90 && a.distanceTo(b) >= 2;
    }
    if (best <= 50 && !reverseTravel) _matchSegment = selected;
    return best;
  }

  double? _distanceToStepEnd(RouteStep step, LatLng? from) =>
      from?.distanceTo(step.end);

  int _progressStep = -1;
  int _progressSegment = 0;
  List<double> _stepSuffixMeters = const [];

  /// Road distance from the rider's projection onto the current step to the
  /// step's end. Progress only moves forward and is searched within a short
  /// window ahead, so a hairpin's return leg, which can be closer in a
  /// straight line, is never matched. A poor window match (a route switched
  /// mid-trip, or the rider beside the road) falls back to the whole step.
  double _remainingStepMeters(LatLng position) {
    final points = _geometryForStep(_steps[_index]);
    if (_progressStep != _index) {
      _progressStep = _index;
      _progressSegment = 0;
      // suffix[i] = road length from points[i] to the step's end.
      final suffix = List<double>.filled(points.length, 0);
      for (var i = points.length - 2; i >= 0; i--) {
        suffix[i] = suffix[i + 1] + points[i].distanceTo(points[i + 1]);
      }
      _stepSuffixMeters = suffix;
    }

    _SegmentProjection? best;
    var bestIndex = _progressSegment;
    var scanned = 0.0;
    for (var i = _progressSegment; i < points.length - 1; i++) {
      final projection = _projectToSegment(position, points[i], points[i + 1]);
      if (best == null || projection.distanceMeters < best.distanceMeters) {
        best = projection;
        bestIndex = i;
      }
      scanned += _stepSuffixMeters[i] - _stepSuffixMeters[i + 1];
      if (scanned > _progressSearchAheadMeters) break;
    }
    if (best == null || best.distanceMeters > _progressReseedMeters) {
      final whole = _closestSegment(position, points);
      if (whole != null &&
          (best == null || whole.distanceMeters < best.distanceMeters)) {
        bestIndex = whole.segmentIndex;
        best = _SegmentProjection(
            projected: whole.projected, distanceMeters: whole.distanceMeters);
      }
    }
    if (best == null) return 0;
    _progressSegment = bestIndex;
    return best.projected.distanceTo(points[bestIndex + 1]) +
        _stepSuffixMeters[bestIndex + 1];
  }

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

    // Resample at equal distances along the road, in metres, so each point
    // keeps a fixed distance ahead of the rider from one fix to the next.
    final metric = [for (final point in preview.route) preview.metric(point)];
    final along = <double>[0];
    for (var i = 1; i < metric.length; i++) {
      final dForward = metric[i].forward - metric[i - 1].forward;
      final dLateral = metric[i].lateral - metric[i - 1].lateral;
      along.add(along.last +
          math.sqrt(dForward * dForward + dLateral * dLateral));
    }
    final total = along.last;
    if (total <= 0) return const [];

    final output = <int>[];
    var segment = 1;
    for (var i = 0; i < routePreviewMaxPoints; i++) {
      final target = total * i / (routePreviewMaxPoints - 1);
      while (segment < metric.length - 1 && along[segment] < target) {
        segment++;
      }
      final a = metric[segment - 1];
      final b = metric[segment];
      final span = along[segment] - along[segment - 1];
      final t =
          span > 0 ? ((target - along[segment - 1]) / span).clamp(0.0, 1.0) : 0.0;
      final point = preview.screenPointAt(
        forward: a.forward + (b.forward - a.forward) * t,
        lateral: a.lateral + (b.lateral - a.lateral) * t,
      );
      output
        ..add(point.x)
        ..add(point.y);
    }
    return output;
  }

  List<int> _sideRoadPreviewPoints(_PreviewFrame? preview) {
    if (_sideRoads.isEmpty) return const [];
    if (preview == null) return const [];

    final candidates = <_SideRoadCandidate>[];
    for (final road in _sideRoads) {
      final connection = _roadConnection(road, preview.nearby);
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
        // The BLE segment describes a direction, not the measured length of
        // the side road. Avoid clamping a distant endpoint to the source-map
        // edge: that used to distort the ray and vary its apparent length.
        final branchLength = math.sqrt(branchVector.dx * branchVector.dx +
            branchVector.dy * branchVector.dy);
        const reach = _sideRoadDirectionPreviewUnits * previewResolution;
        final b = (
          x: (a.x + branchVector.dx / branchLength * reach)
              .round()
              .clamp(0, 127 * previewResolution),
          y: (a.y - branchVector.dy / branchLength * reach)
              .round()
              .clamp(0, 63 * previewResolution),
        );
        if ((a.x - b.x).abs() + (a.y - b.y).abs() < 5 * previewResolution) {
          continue;
        }
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
    var lastSegment = remaining.length - 2;

    for (var i = closest.segmentIndex; i < remaining.length - 1; i++) {
      final target = remaining[i + 1];
      final segmentLength = cursor.distanceTo(target);
      if (segmentLength <= 0) continue;

      if (travelled + segmentLength >= routePreviewDistanceMeters) {
        final t = (routePreviewDistanceMeters - travelled) / segmentLength;
        route.add(_interpolate(cursor, target, t));
        lastSegment = i;
        break;
      }

      route.add(target);
      travelled += segmentLength;
      cursor = target;
    }

    if (route.length < 2) return null;

    // Side roads are only drawn within this window, so match them against
    // these segments rather than the whole remaining trip: on a long route
    // that was thousands of segment tests per road on every GPS fix.
    var firstSegment = closest.segmentIndex;
    var behind = remaining[firstSegment].distanceTo(closest.projected);
    while (firstSegment > 0 && behind < _sideRoadWindowBehindMeters) {
      firstSegment--;
      behind += remaining[firstSegment].distanceTo(remaining[firstSegment + 1]);
    }
    final nearby = remaining.sublist(firstSegment, lastSegment + 2);

    final heading = _bearingRadians(route[0], route[1]);
    const latScale = 111320.0;
    final lngScale =
        latScale * math.cos(_toRad(route[0].latitude).clamp(-1.4, 1.4));
    const scale = (_previewBottom - _previewTop) / routePreviewDistanceMeters;

    return _PreviewFrame(
      route: route,
      nearby: nearby,
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
    required this.nearby,
    required this.origin,
    required this.heading,
    required this.lngScale,
    required this.scale,
  });

  final List<LatLng> route;

  /// Remaining-route vertices spanning the preview window, plus a short
  /// stretch behind the rider. Side roads are matched against these only.
  final List<LatLng> nearby;
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

  /// Mini-map coordinates in tenths of a unit (see `previewResolution`).
  ({int x, int y}) screenPoint(LatLng point) {
    final m = metric(point);
    return screenPointAt(forward: m.forward, lateral: m.lateral);
  }

  ({int x, int y}) screenPointAt({
    required double forward,
    required double lateral,
  }) {
    const resolution = NavigationEngine.previewResolution;
    return (
      x: ((NavigationEngine._previewCenterX + lateral * scale) * resolution)
          .round()
          .clamp(NavigationEngine._previewLeft * resolution,
              NavigationEngine._previewRight * resolution),
      y: ((NavigationEngine._previewBottom - forward * scale) * resolution)
          .round()
          .clamp(NavigationEngine._previewTop * resolution,
              NavigationEngine._previewBottom * resolution),
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
