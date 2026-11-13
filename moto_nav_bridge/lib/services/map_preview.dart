import 'dart:math' as math;

import '../models/lat_lng.dart';
import 'route_geometry.dart';

/// The display's mini-map projection for one fix: the route ahead, drawn
/// heading-up from the rider. Route and side-road previews share one frame,
/// so the remaining route is traversed and projected once per GPS sample.
class MapPreview {
  const MapPreview._({
    required this.route,
    required this.nearby,
    required this.origin,
    required this.heading,
    required this.lngScale,
  });

  // Shared route/side-road scale: show 200 m ahead without changing the BLE
  // coordinate frame or the firmware's map and pointer layout.
  static const double distanceMeters = 200.0;
  // Always this many points, evenly spaced along the road (about 10 m apart),
  // so the display can glide each point to its next position.
  static const int routeMaxPoints = 20;
  // Preview coordinates are sent in tenths of a mini-map unit (one unit is
  // about 6 m): whole units made the route visibly step on the display.
  static const int resolution = 10;
  // Junctions up to 20 m behind the rider are still drawn; keep margin.
  static const double _windowBehindMeters = 40.0;
  // The part of the firmware's 128x64 mini-map the preview may use, in units.
  static const int _left = 18;
  static const int _top = 2;
  static const int _right = 110;
  static const int _bottom = 34;
  static const int _centerX = 64;
  static const double _scale = (_bottom - _top) / distanceMeters;

  /// The rider's projection onto the route, then the route ahead.
  final List<LatLng> route;

  /// Remaining-route vertices spanning the preview window, plus a short
  /// stretch behind the rider. Side roads are matched against these only.
  final List<LatLng> nearby;
  final LatLng origin;
  final double heading;
  final double lngScale;

  /// The frame for [position] on the [remaining] route, or null when there
  /// is no route ahead to draw.
  static MapPreview? build(LatLng position, List<LatLng> remaining) {
    if (remaining.length < 2) return null;
    final closest = RouteGeometry.closestSegment(position, remaining);
    if (closest == null) return null;

    final route = <LatLng>[closest.projected];
    var travelled = 0.0;
    var cursor = closest.projected;
    var lastSegment = remaining.length - 2;
    for (var i = closest.segmentIndex; i < remaining.length - 1; i++) {
      final target = remaining[i + 1];
      final segmentLength = cursor.distanceTo(target);
      if (segmentLength <= 0) continue;
      if (travelled + segmentLength >= distanceMeters) {
        final t = (distanceMeters - travelled) / segmentLength;
        route.add(RouteGeometry.interpolate(cursor, target, t));
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
    while (firstSegment > 0 && behind < _windowBehindMeters) {
      firstSegment--;
      behind += remaining[firstSegment].distanceTo(remaining[firstSegment + 1]);
    }

    return MapPreview._(
      route: route,
      nearby: remaining.sublist(firstSegment, lastSegment + 2),
      origin: route[0],
      heading: RouteGeometry.bearingRadians(route[0], route[1]),
      // Clamped (radians) so the scale stays finite near the poles.
      lngScale:
          RouteGeometry.latScale *
          math.cos(RouteGeometry.toRad(route[0].latitude).clamp(-1.4, 1.4)),
    );
  }

  /// Metres ahead of and to the right of the rider.
  ({double forward, double lateral}) metric(LatLng point) {
    final east = (point.longitude - origin.longitude) * lngScale;
    final north = (point.latitude - origin.latitude) * RouteGeometry.latScale;
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

  /// Mini-map coordinates in tenths of a unit (see [resolution]).
  ({int x, int y}) screenPoint(LatLng point) {
    final m = metric(point);
    return screenPointAt(forward: m.forward, lateral: m.lateral);
  }

  ({int x, int y}) screenPointAt({
    required double forward,
    required double lateral,
  }) => (
    x: ((_centerX + lateral * _scale) * resolution).round().clamp(
      _left * resolution,
      _right * resolution,
    ),
    y: ((_bottom - forward * _scale) * resolution).round().clamp(
      _top * resolution,
      _bottom * resolution,
    ),
  );

  /// The route as [routeMaxPoints] flattened `x,y` points, resampled at
  /// equal distances along the road, in metres, so each point keeps a fixed
  /// distance ahead of the rider from one fix to the next.
  List<int> routePoints() {
    final metrics = [for (final point in route) metric(point)];
    final along = <double>[0];
    for (var i = 1; i < metrics.length; i++) {
      final dForward = metrics[i].forward - metrics[i - 1].forward;
      final dLateral = metrics[i].lateral - metrics[i - 1].lateral;
      along.add(
        along.last + math.sqrt(dForward * dForward + dLateral * dLateral),
      );
    }
    final total = along.last;
    if (total <= 0) return const [];

    final output = <int>[];
    var segment = 1;
    for (var i = 0; i < routeMaxPoints; i++) {
      final target = total * i / (routeMaxPoints - 1);
      while (segment < metrics.length - 1 && along[segment] < target) {
        segment++;
      }
      final a = metrics[segment - 1];
      final b = metrics[segment];
      final span = along[segment] - along[segment - 1];
      final t = span > 0
          ? ((target - along[segment - 1]) / span).clamp(0.0, 1.0)
          : 0.0;
      final point = screenPointAt(
        forward: a.forward + (b.forward - a.forward) * t,
        lateral: a.lateral + (b.lateral - a.lateral) * t,
      );
      output
        ..add(point.x)
        ..add(point.y);
    }
    return output;
  }
}
