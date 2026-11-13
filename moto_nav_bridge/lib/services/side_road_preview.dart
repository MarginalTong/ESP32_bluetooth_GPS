import 'dart:math' as math;

import '../models/lat_lng.dart';
import '../models/road_segment.dart';
import 'map_preview.dart';
import 'route_geometry.dart';

/// Chooses the side roads the display draws: junction arms near the route,
/// as schematic rays in mini-map coordinates.
class SideRoadPreview {
  const SideRoadPreview._();

  // Every arm the display can show at once: its map reaches about 115 m
  // ahead, so eight arms cover four crossroads in view. `NavState.toWire`
  // drops the farthest if the packet would exceed the firmware's limit.
  // Must match MapMotion::kRoadSegments in the firmware.
  static const int maxSegments = 8;
  // A road ending farther than this from the route does not join it.
  static const double connectionToleranceMeters = 14.0;
  // Shorter stubs are driveways and mapping noise, not branches.
  static const double minimumBranchMeters = 8.0;
  // sin of the angle to the route (about 17°); flatter roads run alongside.
  static const double minimumCrossingSin = 0.30;
  // Length of the direction segment sent for an arm, in mini-map units. The
  // display uses its direction only.
  static const double _directionUnits = 10.0;
  // Junctions from this far behind the rider to just past the preview end,
  // and this close to the route line, are candidates (metres).
  static const double _behindMeters = 20.0;
  static const double _beyondPreviewMeters = 25.0;
  static const double _lateralMeters = 25.0;

  /// Up to [maxSegments] arms as flattened `x0,y0,x1,y1` segments, each from
  /// its route junction outwards, nearest junction first.
  static List<int> points(MapPreview? preview, List<RoadSegment> roads) {
    if (roads.isEmpty || preview == null) return const [];

    final candidates = <_Candidate>[];
    // One arm per junction and side: both ends of a road that curves back
    // to the same side would otherwise draw the same ray twice.
    final arms = <String>{};
    for (final road in roads) {
      final connection = _connection(road, preview.nearby);
      if (connection == null ||
          connection.distanceMeters > connectionToleranceMeters) {
        continue;
      }
      final anchor = preview.metric(connection.routePoint);
      if (anchor.forward < -_behindMeters ||
          anchor.forward > MapPreview.distanceMeters + _beyondPreviewMeters ||
          anchor.lateral.abs() > _lateralMeters) {
        continue;
      }
      for (final end in [road.start, road.end]) {
        final candidate = _arm(preview, connection, end, anchor.forward, arms);
        if (candidate != null) candidates.add(candidate);
      }
    }

    candidates.sort((a, b) => a.priority.compareTo(b.priority));
    return [
      for (final segment in candidates.take(maxSegments)) ...[
        segment.a.x,
        segment.a.y,
        segment.b.x,
        segment.b.y,
      ],
    ];
  }

  /// The arm from [connection] towards the road's [end], or null when it is
  /// too short, runs alongside the route, or its junction side is in [arms].
  static _Candidate? _arm(
    MapPreview preview,
    _Connection connection,
    LatLng end,
    double forward,
    Set<String> arms,
  ) {
    final length = connection.roadPoint.distanceTo(end);
    if (length < minimumBranchMeters) return null;

    final route = preview.vector(connection.routeStart, connection.routeEnd);
    final branch = preview.vector(connection.roadPoint, end);
    final routeLength = math.sqrt(route.dx * route.dx + route.dy * route.dy);
    final denominator =
        routeLength * math.sqrt(branch.dx * branch.dx + branch.dy * branch.dy);
    if (denominator == 0) return null;
    final cross = route.dx * branch.dy - route.dy * branch.dx;
    if (cross.abs() / denominator < minimumCrossingSin) return null;

    final a = preview.screenPoint(connection.routePoint);
    // A schematic junction: every arm is drawn at right angles to the
    // route, on the side the real road leaves it. The real angle is not
    // shown; only roads that genuinely cross the route qualify (above).
    // The BLE segment describes a direction, not the side road's length.
    final rightSide = cross < 0;
    final side = rightSide ? 1.0 : -1.0;
    // (lateral, forward) of the route turned 90° towards that side.
    final perpendicular = (
      dx: side * route.dy / routeLength,
      dy: -side * route.dx / routeLength,
    );
    // 20 tenths: arms within 2 mini-map units are the same junction.
    if (!arms.add('${a.x ~/ 20},${a.y ~/ 20},$rightSide')) return null;
    const resolution = MapPreview.resolution;
    const reach = _directionUnits * resolution;
    // The firmware's mini-map is 128x64 units.
    final b = (
      x: (a.x + perpendicular.dx * reach).round().clamp(0, 127 * resolution),
      y: (a.y - perpendicular.dy * reach).round().clamp(0, 63 * resolution),
    );
    // Clamped to under half its length: no usable direction is left.
    if ((a.x - b.x).abs() + (a.y - b.y).abs() < 5 * resolution) return null;
    return _Candidate(
      a: a,
      b: b,
      // Nearest junction first; then the cleanest connection.
      priority: forward.abs() + connection.distanceMeters * 4 + length * 0.05,
    );
  }

  /// Where [road] meets the [route]: its crossing point, else the road end
  /// closest to the route.
  static _Connection? _connection(RoadSegment road, List<LatLng> route) {
    _Connection? best;
    for (var i = 0; i < route.length - 1; i++) {
      final routeStart = route[i];
      final routeEnd = route[i + 1];
      final crossing = RouteGeometry.segmentIntersection(
        road.start,
        road.end,
        routeStart,
        routeEnd,
      );
      if (crossing != null) {
        return _Connection(
          routePoint: crossing,
          roadPoint: crossing,
          routeStart: routeStart,
          routeEnd: routeEnd,
          distanceMeters: 0,
        );
      }
      for (final roadPoint in [road.start, road.end]) {
        final projected = RouteGeometry.projectToSegment(
          roadPoint,
          routeStart,
          routeEnd,
        );
        if (best == null || projected.distanceMeters < best.distanceMeters) {
          best = _Connection(
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
}

class _Candidate {
  const _Candidate({required this.a, required this.b, required this.priority});

  final ({int x, int y}) a;
  final ({int x, int y}) b;
  final double priority;
}

class _Connection {
  const _Connection({
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
