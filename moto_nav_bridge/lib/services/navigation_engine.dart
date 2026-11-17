import 'dart:math' as math;

import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/road_segment.dart';
import '../models/route_step.dart';
import 'map_preview.dart';
import 'route_alignment.dart';
import 'route_geometry.dart';
import 'side_road_preview.dart';

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
  }) : _steps = List.unmodifiable(steps),
       _sideRoads = List.unmodifiable(sideRoads),
       assert(steps.isNotEmpty, 'route must have at least one step');

  final List<RouteStep> _steps;
  List<RoadSegment> _sideRoads;

  int _index = 0;
  final Set<int> _reachedWaypoints = {};
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

  /// How far ahead the mini-map shows; see [MapPreview.distanceMeters].
  static const double routePreviewDistanceMeters = MapPreview.distanceMeters;
  // Along-route distance: how far ahead of the last matched segment to look,
  // and how poor a match must be before searching the whole step again.
  static const double _progressSearchAheadMeters = 300.0;
  static const double _progressReseedMeters = 50.0;
  // A required stop counts as visited within this distance, from a fix at
  // least this accurate (metres) and no older than [_waypointFixMaxAge].
  static const double _waypointReachedMeters = 25.0;
  static const Duration _waypointFixMaxAge = Duration(seconds: 10);
  // A fix this close to a road (metres) is travelling on it.
  static const double _onRoadMeters = 15.0;

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
    _advanceSteps(position);

    final straight = position.distanceTo(_steps[_index].end);
    // Announce the distance the rider will actually travel. On a bend or
    // hairpin the straight line to the turn is far shorter than the road.
    // Never report less than the straight line, e.g. when beside the road.
    final dist = math.max(straight, _remainingStepMeters(position)).round();
    // After _remainingStepMeters: it matches the rider to a route segment.
    final limit = _speedLimitKph();

    // Route and junction previews use the same projection frame.
    final preview = MapPreview.build(position, _remainingRoutePoints());
    return NavState(
      direction: _direction(position, straight),
      distanceMeters: dist < 0 ? 0 : dist,
      routePreviewPoints: preview?.routePoints() ?? const [],
      sideRoadPreviewPoints: SideRoadPreview.points(preview, _sideRoads),
      speedLimitKph: limit,
    );
  }

  /// The limit of the route segment the rider was just matched to. Null when
  /// the map has none there, or the rider is too far from the route for its
  /// limit to be the limit of the road they are on.
  int? _speedLimitKph() {
    final limits = _steps[_index].speedLimitsKph;
    if (limits == null ||
        _progressSegment >= limits.length ||
        _progressOffsetMeters > _onRoadMeters) {
      return null;
    }
    final limit = limits[_progressSegment];
    return limit > 0 ? limit : null;
  }

  /// Advances while the rider has effectively reached the current step's
  /// end, or clearly overshot it toward the next one.
  void _advanceSteps(LatLng position) {
    while (_index < _steps.length - 1) {
      final current = _steps[_index];
      final stop = current.waypointIndex;
      if (stop != null && _atWaypoint(position, current)) {
        if (_reachedWaypoints.add(stop)) _remainingRouteCacheIndex = -1;
      }
      // A required stop must not be skipped by the normal overshoot heuristic.
      if (stop != null && !_reachedWaypoints.contains(stop)) break;
      if (!_shouldAdvance(position, current, _steps[_index + 1])) break;
      _index++;
      _remainingRouteCacheIndex = -1;
    }
  }

  bool _atWaypoint(LatLng position, RouteStep step) =>
      position.distanceTo(step.end) <= _waypointReachedMeters &&
      (position is! NavigationFix ||
          (position.accuracy.isFinite &&
              position.accuracy >= 0 &&
              position.accuracy <= _waypointReachedMeters &&
              DateTime.now().difference(position.timestamp).abs() <=
                  _waypointFixMaxAge));

  bool _shouldAdvance(LatLng position, RouteStep current, RouteStep next) {
    final distToCurrentEnd = position.distanceTo(current.end);
    final reached = distToCurrentEnd <= arrivalThresholdMeters;
    final overshot = position.distanceTo(next.end) < distToCurrentEnd;
    if (!RouteAlignment.usable(position)) return reached || overshot;

    final fix = position as NavigationFix;
    final points = RouteAlignment.geometry(next);
    // Near a turn is not the same as having completed it. In particular,
    // keep an explicit U-turn until motion follows its outgoing segment.
    final onNext =
        RouteGeometry.distanceToSegmentMeters(fix, points[0], points[1]) <=
        _onRoadMeters;
    if (RouteAlignment.forward(fix, current.end) < 0 &&
        RouteAlignment.aligned(fix, points[0], points[1]) &&
        (distToCurrentEnd < arrivalThresholdMeters || (overshot && onNext))) {
      return true;
    }
    return _recoveredOntoNext(fix, current, points);
  }

  /// A GPS update can miss the entire turn, or the next road can curve away
  /// from its first segment. Recover only onto the immediate next step, with
  /// a reliable matching course and an unambiguous road match. Its far
  /// endpoint need not be nearer than the passed turn.
  bool _recoveredOntoNext(
    NavigationFix fix,
    RouteStep current,
    List<LatLng> next,
  ) {
    final match = RouteGeometry.closestSegment(fix, next);
    final currentMatch = RouteGeometry.closestSegment(
      fix,
      _geometryForStep(current),
    );
    if (match == null || currentMatch == null) return false;
    var progress = 0.0;
    for (var i = 0; i < match.segmentIndex; i++) {
      progress += next[i].distanceTo(next[i + 1]);
    }
    progress += next[match.segmentIndex].distanceTo(match.projected);
    // 8 m: clearly nearer the next road than the one being left.
    return match.distanceMeters <= _onRoadMeters &&
        currentMatch.distanceMeters > match.distanceMeters + 8 &&
        progress >= arrivalThresholdMeters &&
        RouteAlignment.aligned(
          fix,
          next[match.segmentIndex],
          next[match.segmentIndex + 1],
        );
  }

  /// The maneuver performed at the current step's end, which is the next
  /// step's mapped direction. On the final leg, keep showing a forward
  /// instruction until the rider is actually at the destination. Arrival is
  /// a proximity test, so it uses the [straight]-line distance.
  DeviceDirection _direction(LatLng position, double straight) {
    final step = _steps[_index];
    if (step.direction == DeviceDirection.uturn &&
        RouteAlignment.usable(position)) {
      // Still shown until motion follows the U-turn's outgoing segment.
      final points = RouteAlignment.geometry(step);
      if (!RouteAlignment.aligned(
        position as NavigationFix,
        points[0],
        points[1],
      )) {
        return DeviceDirection.uturn;
      }
    }
    if (_index < _steps.length - 1) return _steps[_index + 1].direction;
    return straight.round() <= arrivalThresholdMeters
        ? DeviceDirection.arrived
        : DeviceDirection.up;
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
        final distance = RouteGeometry.distanceToSegmentMeters(
          position,
          points[i],
          points[i + 1],
        );
        if (distance < best) {
          best = distance;
          _matchSegment = i;
        }
      }
    }
    best = double.infinity;
    var selected = _matchSegment;
    for (
      var i = _matchSegment;
      i < math.min(_matchSegment + 4, points.length - 1);
      i++
    ) {
      final distance = RouteGeometry.distanceToSegmentMeters(
        position,
        points[i],
        points[i + 1],
      );
      if (distance < best) {
        best = distance;
        selected = i;
      }
    }
    if (position is NavigationFix && position.reliableCourse) {
      final a = points[selected];
      final b = points[selected + 1];
      final dx =
          (b.longitude - a.longitude) *
          math.cos(RouteGeometry.toRad(a.latitude));
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
  // Distance from the rider to the matched segment, metres.
  double _progressOffsetMeters = double.infinity;
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

    SegmentProjection? best;
    var bestIndex = _progressSegment;
    var scanned = 0.0;
    for (var i = _progressSegment; i < points.length - 1; i++) {
      final projection = RouteGeometry.projectToSegment(
        position,
        points[i],
        points[i + 1],
      );
      if (best == null || projection.distanceMeters < best.distanceMeters) {
        best = projection;
        bestIndex = i;
      }
      scanned += _stepSuffixMeters[i] - _stepSuffixMeters[i + 1];
      if (scanned > _progressSearchAheadMeters) break;
    }
    if (best == null || best.distanceMeters > _progressReseedMeters) {
      final whole = RouteGeometry.closestSegment(position, points);
      if (whole != null &&
          (best == null || whole.distanceMeters < best.distanceMeters)) {
        bestIndex = whole.segmentIndex;
        best = SegmentProjection(
          projected: whole.projected,
          distanceMeters: whole.distanceMeters,
        );
      }
    }
    _progressOffsetMeters = best?.distanceMeters ?? double.infinity;
    if (best == null) return 0;
    _progressSegment = bestIndex;
    return best.projected.distanceTo(points[bestIndex + 1]) +
        _stepSuffixMeters[bestIndex + 1];
  }

  List<LatLng> _geometryForStep(RouteStep step) =>
      step.geometry.length >= 2 ? step.geometry : [step.start, step.end];

  List<LatLng> _remainingRoutePoints() {
    if (_remainingRouteCacheIndex == _index) return _remainingRouteCache;

    final output = <LatLng>[];
    for (var i = _index; i < _steps.length; i++) {
      for (final point in _geometryForStep(_steps[i])) {
        if (output.isEmpty || output.last.distanceTo(point) > 0.5) {
          output.add(point);
        }
      }
      final stop = _steps[i].waypointIndex;
      if (stop != null && !_reachedWaypoints.contains(stop)) break;
    }
    _remainingRouteCacheIndex = _index;
    _remainingRouteCache = List.unmodifiable(output);
    return _remainingRouteCache;
  }
}
