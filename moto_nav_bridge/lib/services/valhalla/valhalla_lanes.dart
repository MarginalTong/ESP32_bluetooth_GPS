import 'dart:convert';

import '../../models/lane_guidance.dart';
import '../../models/lat_lng.dart';
import '../../models/route_candidate.dart';
import 'valhalla_route_parser.dart';

/// Lane advice from Valhalla's OSRM-format response, which is the only
/// format that carries lanes. The routes themselves still come from the
/// native response; lanes are attached only where both describe the same
/// maneuvers at the same points, so a mismatch costs the advice, never
/// puts it on the wrong junction.
class ValhallaLanes {
  const ValhallaLanes._();

  /// 1 m: both formats report the same shape point for a maneuver.
  static const _sameMeters = 1.0;

  /// [routes] with lane advice from [osrmBody] added; unchanged when the
  /// body is missing or unusable.
  static List<RouteCandidate> attach(
    List<RouteCandidate> routes,
    String? osrmBody,
  ) {
    if (osrmBody == null) return routes;
    final List<List<_Maneuver>> parsed;
    try {
      parsed = _parse(osrmBody);
    } on FormatException {
      return routes;
    }
    return List.unmodifiable([
      for (var i = 0; i < routes.length; i++) _withLanes(routes[i], parsed, i),
    ]);
  }

  static RouteCandidate _withLanes(
    RouteCandidate route,
    List<List<_Maneuver>> parsed,
    int index,
  ) {
    // The OSRM route at the same position usually matches; try it first.
    final order = [
      if (index < parsed.length) index,
      for (var i = 0; i < parsed.length; i++)
        if (i != index) i,
    ];
    for (final i in order) {
      final maneuvers = parsed[i];
      if (!_matches(route, maneuvers)) continue;
      return route.copyWith(
        steps: List.unmodifiable([
          for (var s = 0; s < route.steps.length; s++)
            route.steps[s].copyWith(lanes: maneuvers[s].lanes),
        ]),
      );
    }
    return route;
  }

  static bool _matches(RouteCandidate route, List<_Maneuver> maneuvers) {
    if (maneuvers.length != route.steps.length) return false;
    for (var s = 0; s < maneuvers.length; s++) {
      if (maneuvers[s].location.distanceTo(route.steps[s].start) >
          _sameMeters) {
        return false;
      }
    }
    return true;
  }

  /// Per OSRM route, every maneuver except arrivals (which the native
  /// parser drops too), with the lanes marked at its junction.
  static List<List<_Maneuver>> _parse(String body) {
    if (body.length > ValhallaRouteParser.maxResponseBytes) {
      throw const FormatException();
    }
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      throw const FormatException();
    }
    final routes = root is Map ? root['routes'] : null;
    if (routes is! List) throw const FormatException();
    return [for (final route in routes) _routeManeuvers(route)];
  }

  static List<_Maneuver> _routeManeuvers(dynamic route) {
    final legs = route is Map ? route['legs'] : null;
    if (legs is! List) throw const FormatException();
    return [
      for (final leg in legs)
        for (final step in _list(leg is Map ? leg['steps'] : null))
          if (_maneuverType(step) != 'arrive') _maneuver(step),
    ];
  }

  static _Maneuver _maneuver(dynamic step) {
    final maneuver = step is Map ? step['maneuver'] : null;
    final location = maneuver is Map ? maneuver['location'] : null;
    if (location is! List ||
        location.length != 2 ||
        location[0] is! num ||
        location[1] is! num) {
      throw const FormatException();
    }
    // OSRM writes [longitude, latitude].
    final point = LatLng(
      (location[1] as num).toDouble(),
      (location[0] as num).toDouble(),
    );
    final intersections = step['intersections'];
    final junction = intersections is List && intersections.isNotEmpty
        ? intersections.first
        : null;
    return _Maneuver(point, _lanes(junction is Map ? junction['lanes'] : null));
  }

  /// Recommended ("active") lanes when the data has them, otherwise every
  /// lane that can make the maneuver ("valid"). Lanes are listed left to
  /// right. Anything malformed means no advice, not a rejected route.
  static LaneGuidance? _lanes(dynamic lanes) {
    if (lanes is! List) return null;
    final valid = <bool>[];
    final active = <bool>[];
    for (final lane in lanes) {
      if (lane is! Map || lane['valid'] is! bool) return null;
      valid.add(lane['valid'] as bool);
      active.add(lane['active'] == true && lane['valid'] == true);
    }
    return LaneGuidance.fromFlags(active.contains(true) ? active : valid);
  }

  static String? _maneuverType(dynamic step) {
    final maneuver = step is Map ? step['maneuver'] : null;
    final type = maneuver is Map ? maneuver['type'] : null;
    return type is String ? type : null;
  }

  static List<dynamic> _list(dynamic value) {
    if (value is! List) throw const FormatException();
    return value;
  }
}

class _Maneuver {
  const _Maneuver(this.location, this.lanes);
  final LatLng location;
  final LaneGuidance? lanes;
}
