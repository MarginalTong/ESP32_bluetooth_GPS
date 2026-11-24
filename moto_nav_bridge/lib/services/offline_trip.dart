import '../models/device_direction.dart';
import '../models/lane_guidance.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/road_segment.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';

/// Local recovery document, never a cloud settings payload or a GPS fix.
class OfflineTrip {
  const OfflineTrip({
    required this.id,
    required this.destination,
    required this.routes,
    required this.stops,
    required this.preferences,
    required this.progress,
  });
  final String id;
  final LatLng destination;
  final List<RouteCandidate> routes;
  final List<PlaceResult> stops;
  final Map<String, Object> preferences;
  final TripProgress progress;

  OfflineTrip withProgress(TripProgress value) {
    if (value.id != id ||
        value.selected >= routes.length ||
        value.step >= routes[value.selected].steps.length ||
        value.completed > stops.length ||
        value.routeBase > value.completed) {
      throw const FormatException('Invalid trip progress');
    }
    return OfflineTrip(
      id: id,
      destination: destination,
      routes: routes,
      stops: stops,
      preferences: preferences,
      progress: value,
    );
  }

  Map<String, Object?> toMap() => {
    'version': 1,
    'id': id,
    'destination': _point(destination),
    'routes': routes.map(_route).toList(),
    'stops': stops.map((p) => p.toMap()).toList(),
    'preferences': preferences,
    'progress': progress.toMap(),
  };

  factory OfflineTrip.fromMap(Map<String, dynamic> map) {
    if (map['version'] != 1) {
      throw const FormatException('Unknown trip version');
    }
    final routes = (map['routes'] as List).map((r) => _readRoute(r)).toList();
    final stops = (map['stops'] as List)
        .map((p) => PlaceResult.fromMap(Map<String, dynamic>.from(p as Map)))
        .toList();
    if (routes.isEmpty || routes.length > 16 || stops.length > 5) {
      throw const FormatException('Invalid itinerary');
    }
    for (final stop in stops) {
      _readPoint(_point(stop.location));
    }
    final trip = OfflineTrip(
      id: map['id'] as String,
      destination: _readPoint(map['destination']),
      routes: routes,
      stops: stops,
      preferences: Map<String, Object>.from(map['preferences'] as Map),
      progress: TripProgress.fromMap(map['progress']),
    );
    return trip.withProgress(trip.progress);
  }

  static List<double> _point(LatLng p) => [p.latitude, p.longitude];
  static LatLng _readPoint(dynamic value) {
    final p = value as List;
    final lat = (p[0] as num).toDouble(), lon = (p[1] as num).toDouble();
    if (p.length != 2 ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      throw const FormatException('Invalid coordinate');
    }
    return LatLng(lat, lon);
  }

  static Map<String, Object?> _route(RouteCandidate r) => {
    'name': r.name,
    'distance': r.distanceMeters,
    'seconds': r.expectedTravelTimeSeconds,
    'attribution': r.attribution,
    'attributionUrl': r.attributionUrl,
    'sideRoads': r.sideRoads
        .map((s) => [_point(s.start), _point(s.end)])
        .toList(),
    'steps': r.steps.map(_step).toList(),
  };

  static Map<String, Object?> _step(RouteStep s) => {
    'direction': s.direction.name,
    'start': _point(s.start),
    'end': _point(s.end),
    'distance': s.distanceMeters,
    'geometry': s.geometry.map(_point).toList(),
    'maneuver': s.rawManeuver,
    'exit': s.roundaboutExitCount,
    'street': s.streetName,
    'waypoint': s.waypointIndex,
    'lanes': s.lanes == null
        ? null
        : List.generate(
            s.lanes!.laneCount,
            (i) => i >= s.lanes!.first && i <= s.lanes!.last,
          ),
    'arrivalSide': s.arrivalSide?.name,
    'limits': s.speedLimitsKph,
  };

  static RouteCandidate _readRoute(dynamic value) {
    final r = value as Map;
    final steps = (r['steps'] as List).map(_readStep).toList();
    if (steps.isEmpty || steps.length > 50000) {
      throw const FormatException('Empty route');
    }
    return RouteCandidate(
      steps: steps,
      name: r['name'] as String?,
      distanceMeters: r['distance'] as int?,
      expectedTravelTimeSeconds: r['seconds'] as int?,
      attribution: r['attribution'] as String?,
      attributionUrl: r['attributionUrl'] as String?,
      sideRoads: (r['sideRoads'] as List)
          .map(
            (s) => RoadSegment(start: _readPoint(s[0]), end: _readPoint(s[1])),
          )
          .toList(),
    );
  }

  static RouteStep _readStep(dynamic value) {
    final s = value as Map;
    final geometry = (s['geometry'] as List).map(_readPoint).toList();
    final distance = s['distance'] as int;
    if (distance < 0 || geometry.length > 1000000) {
      throw const FormatException('Invalid step');
    }
    return RouteStep(
      direction: DeviceDirection.values.byName(s['direction'] as String),
      start: _readPoint(s['start']),
      end: _readPoint(s['end']),
      distanceMeters: distance,
      geometry: geometry,
      rawManeuver: s['maneuver'] as String?,
      roundaboutExitCount: s['exit'] as int?,
      streetName: s['street'] as String?,
      waypointIndex: s['waypoint'] as int?,
      lanes: s['lanes'] == null
          ? null
          : LaneGuidance.fromFlags(List<bool>.from(s['lanes'] as List)),
      arrivalSide: s['arrivalSide'] == null
          ? null
          : RoadSide.values.byName(s['arrivalSide'] as String),
      speedLimitsKph: s['limits'] == null
          ? null
          : List<int>.from(s['limits'] as List),
    );
  }
}

/// Written separately from geometry; no accumulating location history.
class TripProgress {
  const TripProgress({
    required this.id,
    required this.active,
    required this.selected,
    required this.step,
    required this.completed,
    required this.routeBase,
    required this.savedAt,
    this.position,
  });
  final String id;
  final bool active;
  final int selected, step, completed, routeBase;
  final DateTime savedAt;
  final LatLng? position;

  Map<String, Object?> toMap() => {
    'id': id,
    'active': active,
    'selected': selected,
    'step': step,
    'completed': completed,
    'routeBase': routeBase,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'position': position == null ? null : OfflineTrip._point(position!),
  };
  factory TripProgress.fromMap(dynamic value) {
    final m = value as Map;
    final p = TripProgress(
      id: m['id'] as String,
      active: m['active'] as bool,
      selected: m['selected'] as int,
      step: m['step'] as int,
      completed: m['completed'] as int,
      routeBase: m['routeBase'] as int,
      savedAt: DateTime.parse(m['savedAt'] as String),
      position: m['position'] == null
          ? null
          : OfflineTrip._readPoint(m['position']),
    );
    if ([p.selected, p.step, p.completed, p.routeBase].any((n) => n < 0)) {
      throw const FormatException('Negative trip progress');
    }
    return p;
  }
}
