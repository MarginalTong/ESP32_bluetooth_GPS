import 'dart:math' as math;
import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';

/// Conservative progress recovery after a directions request. Never connect
/// the rider to an arbitrary forward node across a block or a hairpin.
class RouteAlignment {
  static bool conflictsWithCourse(RouteCandidate route, LatLng latest) {
    if (!usable(latest) ||
        route.steps.isEmpty ||
        route.steps.first.direction == DeviceDirection.uturn) {
      return false;
    }
    final points = geometry(route.steps.first);
    for (var i = 0; i + 1 < points.length; i++) {
      if (points[i].distanceTo(points[i + 1]) >= 2) {
        return !aligned(latest as NavigationFix, points[i], points[i + 1],
            tolerance: 90);
      }
    }
    return false;
  }

  static bool usable(LatLng p) =>
      p is NavigationFix &&
      p.reliableCourse &&
      DateTime.now().difference(p.timestamp).abs() <=
          const Duration(seconds: 10);

  static double forward(NavigationFix p, LatLng target) {
    final angle = p.heading * math.pi / 180;
    return (target.latitude - p.latitude) * 111320 * math.cos(angle) +
        (target.longitude - p.longitude) *
            111320 *
            math.cos(p.latitude * math.pi / 180) *
            math.sin(angle);
  }

  static bool aligned(NavigationFix p, LatLng a, LatLng b,
      {double tolerance = 60}) {
    if (a.distanceTo(b) < 2) return false;
    final bearing = math.atan2(
            (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180),
            b.latitude - a.latitude) *
        180 /
        math.pi;
    return ((p.heading - bearing + 540) % 360 - 180).abs() <= tolerance;
  }

  static List<LatLng> geometry(RouteStep step) =>
      step.geometry.length >= 2 ? step.geometry : [step.start, step.end];

  static RouteCandidate trim(
      RouteCandidate route, LatLng origin, LatLng latest) {
    if (!usable(latest) || route.steps.isEmpty) return route;
    final fix = latest as NavigationFix;
    // Only recover progress plausible during the request, not later loop legs.
    final budget = origin.distanceTo(fix) + 30;
    var travelled = 0.0;
    for (var i = 0; i < route.steps.length; i++) {
      final step = route.steps[i];
      if (step.direction == DeviceDirection.uturn) return route;
      final points = geometry(step);
      for (var j = 0; j + 1 < points.length; j++) {
        final a = points[j];
        final b = points[j + 1];
        final length = a.distanceTo(b);
        if (travelled > budget) return route;
        final scale = math.cos(fix.latitude * math.pi / 180);
        final ax = (a.longitude - fix.longitude) * scale;
        final ay = a.latitude - fix.latitude;
        final dx = (b.longitude - a.longitude) * scale;
        final dy = b.latitude - a.latitude;
        final denominator = dx * dx + dy * dy;
        final t = denominator == 0
            ? 0.0
            : (-(ax * dx + ay * dy) / denominator).clamp(0.0, 1.0);
        final projected = LatLng(a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t);
        if (fix.distanceTo(projected) <= 15 &&
            travelled + length * t <= budget &&
            aligned(fix, a, b) &&
            forward(fix, b) > 0) {
          final remaining = [projected, ...points.skip(j + 1)];
          return route.copyWith(steps: [
            RouteStep(
                direction: DeviceDirection.up,
                start: projected,
                end: step.end,
                geometry: remaining,
                distanceMeters: remaining
                    .asMap()
                    .entries
                    .skip(1)
                    .fold<double>(
                        0,
                        (sum, e) =>
                            sum + remaining[e.key - 1].distanceTo(e.value))
                    .round(),
                rawManeuver: null),
            ...route.steps.skip(i + 1)
          ]);
        }
        travelled += length;
      }
    }
    // An opposite course alone does not prove a turn was already passed.
    return route;
  }
}
