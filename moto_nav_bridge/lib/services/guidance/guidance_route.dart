import 'dart:math' as math;

import '../../models/device_direction.dart';
import '../../models/lat_lng.dart';
import '../../models/route_step.dart';

/// What a maneuver asks the rider to do, read from the provider's own
/// maneuver type. `basic` = only the display direction is known.
enum ManeuverKind {
  basic,
  silent, // continue, name change, start: nothing to announce
  turn,
  sharpTurn,
  slightTurn,
  uturn,
  rampStraight,
  ramp,
  exit,
  forkStraight,
  fork,
  merge,
  roundaboutEnter,
  roundaboutExit,
  destination,
}

/// One maneuver of the route, as the provider described it. Index `m` is the
/// maneuver at the start of `steps[m]`; the destination is `steps.length`.
class GuidanceManeuver {
  const GuidanceManeuver({
    required this.index,
    required this.kind,
    required this.direction,
    required this.alongMeters,
    this.exitCount,
    this.streetName,
  });

  final int index;
  final ManeuverKind kind;

  /// The direction the display shows for it (`RouteStep.direction`).
  final DeviceDirection direction;

  /// Distance along the route from its start to this maneuver.
  final double alongMeters;
  final int? exitCount;
  final String? streetName;

  bool get isSilent => kind == ManeuverKind.silent;

  /// Needs more context than a plain turn: announced a little earlier.
  bool get isComplex => const {
        ManeuverKind.ramp,
        ManeuverKind.rampStraight,
        ManeuverKind.exit,
        ManeuverKind.fork,
        ManeuverKind.forkStraight,
        ManeuverKind.merge,
        ManeuverKind.roundaboutEnter,
      }.contains(kind);
}

/// A run of at least two sharp bends close together, away from maneuvers.
class CurveCluster {
  const CurveCluster(this.startAlong, this.endAlong);
  final double startAlong;
  final double endAlong;
}

/// Layer 1: the route's verified maneuvers and bends. Built once per route
/// from data the provider returned; it never adds a road, lane or name.
class GuidanceRoute {
  GuidanceRoute._(this.steps, this.maneuvers, this.stepEndAlong, this.curves);

  factory GuidanceRoute.fromSteps(List<RouteStep> steps) {
    final lengths = [for (final step in steps) _stepLength(step)];
    final stepEndAlong = <double>[];
    var along = 0.0;
    for (final length in lengths) {
      along += length;
      stepEndAlong.add(along);
    }
    final maneuvers = <GuidanceManeuver>[
      for (var m = 1; m < steps.length; m++)
        GuidanceManeuver(
          index: m,
          kind: _kind(steps[m]),
          direction: steps[m].direction,
          alongMeters: stepEndAlong[m - 1],
          exitCount: steps[m].roundaboutExitCount,
          streetName: steps[m].streetName,
        ),
      GuidanceManeuver(
        index: steps.length,
        kind: ManeuverKind.destination,
        direction: DeviceDirection.arrived,
        alongMeters: along,
      ),
    ];
    return GuidanceRoute._(List.unmodifiable(steps), List.unmodifiable(maneuvers),
        List.unmodifiable(stepEndAlong),
        List.unmodifiable(_findCurves(steps, maneuvers)));
  }

  final List<RouteStep> steps;
  final List<GuidanceManeuver> maneuvers;
  final List<double> stepEndAlong;
  final List<CurveCluster> curves;

  /// The maneuver at the end of step [stepIndex] (the destination on the last
  /// step), or null for an index outside the route.
  GuidanceManeuver? upcoming(int stepIndex) =>
      stepIndex >= 0 && stepIndex < maneuvers.length ? maneuvers[stepIndex] : null;

  /// The next announced maneuver after [m], with the road distance between
  /// them; silent maneuvers in between are skipped.
  ({GuidanceManeuver maneuver, double gapMeters})? following(GuidanceManeuver m) {
    for (var i = m.index; i < maneuvers.length; i++) {
      final next = maneuvers[i];
      if (next.index <= m.index || next.isSilent) continue;
      return (maneuver: next, gapMeters: next.alongMeters - m.alongMeters);
    }
    return null;
  }

  static double _stepLength(RouteStep step) {
    final points = step.geometry;
    if (points.length < 2) return step.distanceMeters.toDouble();
    var length = 0.0;
    for (var i = 1; i < points.length; i++) {
      length += points[i - 1].distanceTo(points[i]);
    }
    return length;
  }

  static ManeuverKind _kind(RouteStep step) {
    final raw = step.rawManeuver;
    final type = raw != null && raw.startsWith('valhalla:')
        ? int.tryParse(raw.substring('valhalla:'.length))
        : null;
    if (type == null) {
      return step.direction == DeviceDirection.up
          ? ManeuverKind.silent
          : ManeuverKind.basic;
    }
    return switch (type) {
      0 || 1 || 2 || 3 || 7 || 8 || 28 || 29 => ManeuverKind.silent,
      10 || 15 => ManeuverKind.turn,
      11 || 14 => ManeuverKind.sharpTurn,
      9 || 16 => ManeuverKind.slightTurn,
      12 || 13 => ManeuverKind.uturn,
      17 => ManeuverKind.rampStraight,
      18 || 19 => ManeuverKind.ramp,
      20 || 21 => ManeuverKind.exit,
      22 => ManeuverKind.forkStraight,
      23 || 24 => ManeuverKind.fork,
      25 || 37 || 38 => ManeuverKind.merge,
      26 => ManeuverKind.roundaboutEnter,
      27 => ManeuverKind.roundaboutExit,
      _ => ManeuverKind.basic,
    };
  }

  // ---- Bends ---------------------------------------------------------------

  static const double _sampleMeters = 5;
  static const double _halfWindowMeters = 20;
  static const double _sharpDegrees = 45;
  static const double _awayFromManeuverMeters = 40;
  static const double _clusterGapMeters = 150;
  // A coarse polyline cannot show a bend reliably: no warning from it.
  static const double _maxPointSpacingMeters = 30;

  static List<CurveCluster> _findCurves(
      List<RouteStep> steps, List<GuidanceManeuver> maneuvers) {
    final points = <LatLng>[];
    for (final step in steps) {
      for (final point in step.geometry) {
        if (points.isEmpty || points.last.distanceTo(point) > 0.5) points.add(point);
      }
    }
    if (points.length < 3) return const [];
    final along = <double>[0];
    for (var i = 1; i < points.length; i++) {
      along.add(along.last + points[i - 1].distanceTo(points[i]));
    }
    final total = along.last;
    final maneuverAlong = [
      for (final m in maneuvers)
        if (!m.isSilent && m.kind != ManeuverKind.destination) m.alongMeters
    ]..sort();

    // Binary search: a long route has thousands of samples and maneuvers.
    bool nearManeuver(double s) {
      var lo = 0, hi = maneuverAlong.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (maneuverAlong[mid] < s - _awayFromManeuverMeters) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo < maneuverAlong.length &&
          maneuverAlong[lo] <= s + _awayFromManeuverMeters;
    }

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
          points[lo].longitude +
              (points[hi].longitude - points[lo].longitude) * t);
    }

    double maxSpacing(double from, double to) {
      var worst = 0.0;
      for (var i = 1; i < points.length; i++) {
        if (along[i] < from || along[i - 1] > to) continue;
        worst = math.max(worst, along[i] - along[i - 1]);
      }
      return worst;
    }

    // Bends: stretches where the heading turns sharply within a short window.
    final bends = <(double, double)>[];
    double? bendStart;
    for (var s = _halfWindowMeters; s <= total - _halfWindowMeters; s += _sampleMeters) {
      final turn = _turnDegrees(at(s - _halfWindowMeters), at(s), at(s + _halfWindowMeters));
      if (turn.abs() >= _sharpDegrees && !nearManeuver(s)) {
        bendStart ??= s;
      } else if (bendStart != null) {
        bends.add((bendStart, s));
        bendStart = null;
      }
    }
    if (bendStart != null) bends.add((bendStart, total));

    final clusters = <CurveCluster>[];
    var i = 0;
    while (i < bends.length) {
      var j = i;
      while (j + 1 < bends.length && bends[j + 1].$1 - bends[j].$2 <= _clusterGapMeters) {
        j++;
      }
      final start = bends[i].$1 - _halfWindowMeters;
      final end = bends[j].$2 + _halfWindowMeters;
      if (j > i && maxSpacing(start, end) <= _maxPointSpacingMeters) {
        clusters.add(CurveCluster(math.max(0, start), end));
      }
      i = j + 1;
    }
    return clusters;
  }

  /// Signed heading change a -> b -> c in degrees, on a local flat frame.
  static double _turnDegrees(LatLng a, LatLng b, LatLng c) {
    final scale = math.cos(b.latitude * math.pi / 180);
    final h1 = math.atan2((b.longitude - a.longitude) * scale, b.latitude - a.latitude);
    final h2 = math.atan2((c.longitude - b.longitude) * scale, c.latitude - b.latitude);
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
