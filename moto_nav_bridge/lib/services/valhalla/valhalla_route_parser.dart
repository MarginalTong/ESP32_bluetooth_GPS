import 'dart:convert';
import 'dart:math' as math;

import '../../models/lane_guidance.dart';
import '../../models/lat_lng.dart';
import '../../models/route_candidate.dart';
import '../../models/route_step.dart';
import '../directions_exception.dart';
import '../waypoint_plan.dart';
import 'polyline6.dart';
import 'valhalla_maneuver_direction.dart';

/// Parses native Valhalla JSON (polyline6), not its optional OSRM format.
/// Every field is validated: an unusable response is rejected as a whole
/// rather than turned into a route the rider cannot trust.
class ValhallaRouteParser {
  const ValhallaRouteParser._();

  static const maxResponseBytes = 4 * 1024 * 1024;

  /// The main route plus at most two alternates. [expectedLegs] is the
  /// number of stops plus one; a response dropping a stop is rejected.
  static List<RouteCandidate> parse(String body, {int expectedLegs = 1}) {
    if (body.length > maxResponseBytes) {
      throw DirectionsException('Valhalla response is too large');
    }
    try {
      final root = _object(jsonDecode(body));
      if (root.containsKey('error') ||
          root.containsKey('error_code') ||
          (root.containsKey('status_code') && root['status_code'] != 200)) {
        throw const FormatException();
      }
      final alternatives = root['alternates'];
      if (alternatives != null && alternatives is! List) {
        throw const FormatException();
      }
      if (expectedLegs < 1 || expectedLegs > WaypointPlan.maxStops + 1) {
        throw const FormatException();
      }
      final output = [_parseTrip(_object(root['trip']), 0, expectedLegs)];
      if (alternatives is List) {
        for (var i = 0; i < math.min(alternatives.length, 2); i++) {
          output.add(
            _parseTrip(
              _object(_object(alternatives[i])['trip']),
              i + 1,
              expectedLegs,
            ),
          );
        }
      }
      return List.unmodifiable(output);
    } catch (_) {
      throw DirectionsException('Invalid or unusable Valhalla route response');
    }
  }

  static RouteCandidate _parseTrip(
    Map<String, dynamic> trip,
    int index,
    int expectedLegs,
  ) {
    if (trip['status'] != 0) throw const FormatException();
    final metersPerUnit = switch (trip['units']) {
      'kilometers' => 1000.0,
      'miles' => 1609.344,
      _ => throw const FormatException(),
    };
    final legs = trip['legs'];
    if (legs is! List || legs.length != expectedLegs) {
      throw const FormatException();
    }
    final steps = <RouteStep>[];
    for (var i = 0; i < legs.length; i++) {
      final segment = _parseLeg(
        _object(legs[i]),
        metersPerUnit,
        waypointIndex: i < legs.length - 1 ? i : null,
        previous: steps.isEmpty ? null : steps.last,
      );
      // 5 m: consecutive legs must meet at the stop they share.
      if (steps.isNotEmpty &&
          steps.last.end.distanceTo(segment.first.start) > 5) {
        throw const FormatException();
      }
      steps.addAll(segment);
    }
    final summary = _object(trip['summary']);
    return RouteCandidate(
      steps: List.unmodifiable(steps),
      name: 'Valhalla ${index + 1}',
      distanceMeters: (_nonnegative(summary['length']) * metersPerUnit).round(),
      expectedTravelTimeSeconds: _nonnegative(summary['time']).round(),
      attribution: '© OpenStreetMap contributors',
      attributionUrl: 'https://www.openstreetmap.org/copyright',
    );
  }

  /// Destination maneuvers are not travel legs: dropping their zero-length
  /// step prevents the engine from announcing ARRIVED before the destination.
  static List<RouteStep> _parseLeg(
    Map<String, dynamic> leg,
    double metersPerUnit, {
    int? waypointIndex,
    RouteStep? previous,
  }) {
    final shape = Polyline6.decode(leg['shape']);
    final maneuvers = leg['maneuvers'];
    // 10000: far above any real leg; guards against a corrupt response.
    if (maneuvers is! List ||
        maneuvers.length < 2 ||
        maneuvers.length > 10000) {
      throw const FormatException();
    }
    final steps = <RouteStep>[];
    var previousEnd = 0;
    var foundDestination = false;
    for (var i = 0; i < maneuvers.length; i++) {
      final maneuver = _object(maneuvers[i]);
      final begin = _integer(maneuver['begin_shape_index']);
      final end = _integer(maneuver['end_shape_index']);
      final length = _nonnegative(maneuver['length']);
      if (begin != previousEnd || end < begin || end >= shape.length) {
        throw const FormatException();
      }
      previousEnd = end;
      final type = _integer(maneuver['type']);
      if (type >= 4 && type <= 6) {
        if (i != maneuvers.length - 1 ||
            begin != end ||
            end != shape.length - 1 ||
            length != 0) {
          throw const FormatException();
        }
        foundDestination = true;
        // 5 and 6: the stop is on the right or left of the road.
        final side = type == 5
            ? RoadSide.right
            : type == 6
            ? RoadSide.left
            : null;
        if (side != null && steps.isNotEmpty) {
          steps.last = steps.last.copyWith(arrivalSide: side);
        }
        continue;
      }
      if (end == begin) throw const FormatException();
      final mode = maneuver['travel_mode'];
      if (mode != null && mode != 'drive') throw const FormatException();
      steps.add(
        _step(
          maneuver,
          // A new leg's START is not necessarily straight ahead. Retain the
          // turn across the stop instead of announcing UP at a turn.
          i == 0 && previous != null && type >= 1 && type <= 3
              ? ValhallaManeuverDirection.joinType(
                  previous,
                  shape.sublist(begin, end + 1),
                )
              : type,
          shape,
          begin,
          end,
          (length * metersPerUnit).round(),
          end == shape.length - 1 ? waypointIndex : null,
        ),
      );
    }
    if (!foundDestination || steps.isEmpty) throw const FormatException();
    return steps;
  }

  static RouteStep _step(
    Map<String, dynamic> maneuver,
    int type,
    List<LatLng> shape,
    int begin,
    int end,
    int meters,
    int? waypointIndex,
  ) {
    return RouteStep(
      direction: ValhallaManeuverDirection.of(type, shape, begin, end),
      start: shape[begin],
      end: shape[end],
      distanceMeters: meters,
      geometry: List.unmodifiable(shape.sublist(begin, end + 1)),
      rawManeuver: 'valhalla:$type',
      roundaboutExitCount: _exitCount(maneuver['roundabout_exit_count']),
      streetName: _streetName(maneuver['street_names']),
      waypointIndex: waypointIndex,
    );
  }

  /// Optional voice details: an unusable value is dropped, never guessed, and
  /// never rejects an otherwise valid route.
  static int? _exitCount(dynamic value) =>
      value is int && value >= 1 && value <= 20 ? value : null;

  /// 40 characters: longer is not a road name a rider can use.
  static String? _streetName(dynamic value) {
    if (value is! List || value.isEmpty || value.first is! String) return null;
    final name = (value.first as String).trim();
    if (name.isEmpty ||
        name.length > 40 ||
        name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return name;
  }

  static Map<String, dynamic> _object(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  static int _integer(dynamic value) {
    if (value is! int || value < 0) throw const FormatException();
    return value;
  }

  static double _nonnegative(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 1e9) {
      throw const FormatException();
    }
    return value.toDouble();
  }
}
