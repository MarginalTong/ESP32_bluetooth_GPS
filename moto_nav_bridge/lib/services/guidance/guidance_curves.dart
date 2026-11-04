import 'dart:math' as math;

import '../../models/lat_lng.dart';
import '../../models/route_step.dart';

/// A run of at least two sharp bends close together, away from maneuvers.
class CurveCluster {
  const CurveCluster(this.startAlong, this.endAlong);
  final double startAlong;
  final double endAlong;
}

/// Finds series of sharp bends in the route shape, for an optional "bends
/// ahead" warning. Geometry only: it never claims a safe speed.
class GuidanceCurves {
  const GuidanceCurves._();

  // Metres between heading samples along the route.
  static const double _sampleMeters = 5;
  // Heading is compared this far behind and ahead of each sample (metres).
  static const double _halfWindowMeters = 20;
  // Heading change within the window that counts as a sharp bend.
  static const double _sharpDegrees = 45;
  // A turn this close to a maneuver (metres) is the maneuver, not a bend.
  static const double _awayFromManeuverMeters = 40;
  // Bends closer than this (metres) belong to the same series.
  static const double _clusterGapMeters = 150;
  // A coarse polyline cannot show a bend reliably: no warning from it.
  static const double _maxPointSpacingMeters = 30;

  /// Bend series along [steps]. [maneuverAlong] lists the route distance of
  /// every announced maneuver; bends at those points are left out.
  static List<CurveCluster> find(
    List<RouteStep> steps,
    Iterable<double> maneuverAlong,
  ) {
    final line = _RouteLine.of(steps);
    if (line == null) return const [];
    final bends = _bends(line, maneuverAlong.toList()..sort());
    return _clusters(line, bends);
  }

  /// Stretches where the heading turns sharply within a short window.
  static List<(double, double)> _bends(_RouteLine line, List<double> sorted) {
    final bends = <(double, double)>[];
    double? bendStart;
    for (
      var s = _halfWindowMeters;
      s <= line.length - _halfWindowMeters;
      s += _sampleMeters
    ) {
      final turn = _turnDegrees(
        line.at(s - _halfWindowMeters),
        line.at(s),
        line.at(s + _halfWindowMeters),
      );
      if (turn.abs() >= _sharpDegrees && !_near(sorted, s)) {
        bendStart ??= s;
      } else if (bendStart != null) {
        bends.add((bendStart, s));
        bendStart = null;
      }
    }
    if (bendStart != null) bends.add((bendStart, line.length));
    return bends;
  }

  static List<CurveCluster> _clusters(
    _RouteLine line,
    List<(double, double)> bends,
  ) {
    final clusters = <CurveCluster>[];
    var i = 0;
    while (i < bends.length) {
      var j = i;
      while (j + 1 < bends.length &&
          bends[j + 1].$1 - bends[j].$2 <= _clusterGapMeters) {
        j++;
      }
      final start = bends[i].$1 - _halfWindowMeters;
      final end = bends[j].$2 + _halfWindowMeters;
      if (j > i && line.maxSpacing(start, end) <= _maxPointSpacingMeters) {
        clusters.add(CurveCluster(math.max(0, start), end));
      }
      i = j + 1;
    }
    return clusters;
  }

  /// Binary search: a long route has thousands of samples and maneuvers.
  static bool _near(List<double> sorted, double s) {
    var lo = 0, hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < s - _awayFromManeuverMeters) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < sorted.length && sorted[lo] <= s + _awayFromManeuverMeters;
  }

  /// Signed heading change a -> b -> c in degrees, on a local flat frame.
  static double _turnDegrees(LatLng a, LatLng b, LatLng c) {
    final scale = math.cos(b.latitude * math.pi / 180);
    final h1 = math.atan2(
      (b.longitude - a.longitude) * scale,
      b.latitude - a.latitude,
    );
    final h2 = math.atan2(
      (c.longitude - b.longitude) * scale,
      c.latitude - b.latitude,
    );
    var delta = (h2 - h1) * 180 / math.pi;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }
    return delta;
  }
}

/// The whole route as one polyline with distance along it.
class _RouteLine {
  _RouteLine(this.points, this.along);

  final List<LatLng> points;
  final List<double> along;

  double get length => along.last;

  static _RouteLine? of(List<RouteStep> steps) {
    final points = <LatLng>[];
    for (final step in steps) {
      for (final point in step.geometry) {
        // 0.5 m: steps share their junction point; keep it once.
        if (points.isEmpty || points.last.distanceTo(point) > 0.5) {
          points.add(point);
        }
      }
    }
    if (points.length < 3) return null;
    final along = <double>[0];
    for (var i = 1; i < points.length; i++) {
      along.add(along.last + points[i - 1].distanceTo(points[i]));
    }
    return _RouteLine(points, along);
  }

  /// The point [s] metres along the route.
  LatLng at(double s) {
    var lo = 0, hi = along.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (along[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = along[hi] - along[lo];
    final t = span > 0 ? ((s - along[lo]) / span).clamp(0.0, 1.0) : 0.0;
    return LatLng(
      points[lo].latitude + (points[hi].latitude - points[lo].latitude) * t,
      points[lo].longitude + (points[hi].longitude - points[lo].longitude) * t,
    );
  }

  /// The longest gap between shape points within [from]..[to].
  double maxSpacing(double from, double to) {
    var worst = 0.0;
    for (var i = 1; i < points.length; i++) {
      if (along[i] < from || along[i - 1] > to) continue;
      worst = math.max(worst, along[i] - along[i - 1]);
    }
    return worst;
  }
}
