import 'dart:convert';

import '../../models/lat_lng.dart';
import '../../models/route_candidate.dart';
import '../../models/route_step.dart';
import 'polyline6.dart';
import 'valhalla_route_parser.dart';

/// Posted speed limits along a route, from Valhalla's `trace_attributes`
/// (the route response itself has none). A wrong limit is worse than no
/// limit: the route's own shape is matched edge by edge, never snapped to
/// nearby roads, and anything missing or unusable is left unknown, not
/// guessed from the road type.
class ValhallaSpeedLimits {
  const ValhallaSpeedLimits._();

  /// Signs the display can show, km/h. 130 is Australia's highest limit;
  /// values outside are data errors or "unlimited".
  static const minKph = 5;
  static const maxKph = 130;

  /// Longest leg asked about: beyond this the request is skipped.
  static const maxShapePoints = 30000;

  /// The legs of [route]: runs of steps ending at a stop or the destination.
  static List<List<RouteStep>> legs(RouteCandidate route) {
    final output = <List<RouteStep>>[];
    var leg = <RouteStep>[];
    for (final step in route.steps) {
      leg.add(step);
      if (step.waypointIndex != null) {
        output.add(leg);
        leg = <RouteStep>[];
      }
    }
    if (leg.isNotEmpty) output.add(leg);
    return output;
  }

  /// The `trace_attributes` request for one leg, or null when the leg cannot
  /// be asked about.
  static Map<String, Object>? request(List<RouteStep> leg) {
    final shape = _shape(leg);
    if (shape == null) return null;
    return {
      'encoded_polyline': Polyline6.encode(shape),
      // The shape is Valhalla's own: follow its edges exactly, or fail.
      'shape_match': 'edge_walk',
      'costing': 'auto',
      'units': 'kilometers',
      'filters': {
        'attributes': [
          'edge.speed_limit',
          'edge.begin_shape_index',
          'edge.end_shape_index',
        ],
        'action': 'include',
      },
    };
  }

  /// [route] with the limits from [bodies] (one response per leg, in order;
  /// null for a leg whose request failed) added to its steps. A leg with an
  /// unusable response keeps its steps unchanged.
  static RouteCandidate attach(RouteCandidate route, List<String?> bodies) {
    final routeLegs = legs(route);
    if (bodies.length != routeLegs.length) return route;
    final steps = <RouteStep>[];
    var changed = false;
    for (var i = 0; i < routeLegs.length; i++) {
      final limits = _parse(bodies[i], _shape(routeLegs[i])?.length ?? 0);
      if (limits == null) {
        steps.addAll(routeLegs[i]);
        continue;
      }
      changed = true;
      var offset = 0;
      for (final step in routeLegs[i]) {
        final count = step.geometry.length - 1;
        steps.add(
          step.copyWith(
            speedLimitsKph: List.unmodifiable(
              limits.sublist(offset, offset + count),
            ),
          ),
        );
        offset += count;
      }
    }
    return changed ? route.copyWith(steps: List.unmodifiable(steps)) : route;
  }

  /// The leg as one line. Each step starts on the point the previous one
  /// ended on, as the route parser built them; anything else has no single
  /// shape to ask about.
  static List<LatLng>? _shape(List<RouteStep> leg) {
    final shape = <LatLng>[];
    for (final step in leg) {
      final points = step.geometry;
      if (points.length < 2) return null;
      if (shape.isNotEmpty) {
        // 0.2 m: the same shape point (a decoded coordinate is ~0.1 m).
        if (shape.last.distanceTo(points.first) > 0.2) return null;
        shape.removeLast();
      }
      shape.addAll(points);
    }
    return shape.length < 2 || shape.length > maxShapePoints ? null : shape;
  }

  /// km/h for each of the `pointCount - 1` shape segments (0 = unknown), or
  /// null when the response is unusable as a whole.
  static List<int>? _parse(String? body, int pointCount) {
    if (body == null ||
        pointCount < 2 ||
        body.length > ValhallaRouteParser.maxResponseBytes) {
      return null;
    }
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    final edges = root is Map ? root['edges'] : null;
    if (edges is! List || edges.isEmpty) return null;
    final limits = List<int>.filled(pointCount - 1, 0);
    var known = false;
    for (final edge in edges) {
      if (edge is! Map) return null;
      final begin = edge['begin_shape_index'];
      final end = edge['end_shape_index'];
      if (begin is! int ||
          end is! int ||
          begin < 0 ||
          end < begin ||
          end >= pointCount) {
        return null;
      }
      final limit = edge['speed_limit'];
      if (limit is! int || limit < minKph || limit > maxKph) continue;
      known = true;
      for (var i = begin; i < end; i++) {
        limits[i] = limit;
      }
    }
    return known ? limits : null;
  }
}
