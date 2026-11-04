import '../../models/device_direction.dart';
import '../../models/route_step.dart';
import 'guidance_curves.dart';

export 'guidance_curves.dart' show CurveCluster;

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
    return GuidanceRoute._(
      List.unmodifiable(steps),
      List.unmodifiable(maneuvers),
      List.unmodifiable(stepEndAlong),
      List.unmodifiable(
        GuidanceCurves.find(steps, [
          for (final m in maneuvers)
            if (!m.isSilent && m.kind != ManeuverKind.destination)
              m.alongMeters,
        ]),
      ),
    );
  }

  final List<RouteStep> steps;
  final List<GuidanceManeuver> maneuvers;
  final List<double> stepEndAlong;
  final List<CurveCluster> curves;

  /// The maneuver at the end of step [stepIndex] (the destination on the last
  /// step), or null for an index outside the route.
  GuidanceManeuver? upcoming(int stepIndex) =>
      stepIndex >= 0 && stepIndex < maneuvers.length
      ? maneuvers[stepIndex]
      : null;

  /// The next announced maneuver after [m], with the road distance between
  /// them; silent maneuvers in between are skipped.
  ({GuidanceManeuver maneuver, double gapMeters})? following(
    GuidanceManeuver m,
  ) {
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
}
