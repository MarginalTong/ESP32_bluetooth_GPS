import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/route_candidate.dart';

/// Trip-only state: never included in cloud preferences or a BLE packet.
class WaypointPlan {
  static const maxStops = 5;
  WaypointPlan(List<PlaceResult> stops) : stops = List.unmodifiable(stops) {
    if (stops.length > maxStops ||
        stops.any(
          (s) =>
              !s.location.latitude.isFinite ||
              !s.location.longitude.isFinite ||
              s.location.latitude.abs() > 90 ||
              s.location.longitude.abs() > 180,
        )) {
      throw ArgumentError('Invalid waypoints (maximum $maxStops)');
    }
  }

  final List<PlaceResult> stops;
  int completed = 0;
  int _routeBase = 0;
  List<LatLng> get remaining =>
      List.unmodifiable(stops.skip(completed).map((s) => s.location));

  /// A fresh route numbers only the stops still outstanding when requested.
  void bindRoute() {
    _routeBase = completed;
  }

  /// Starting while already at a stop must not request a zero-length first leg.
  /// This is called only for the actual trip start, never for an idle preview.
  void completeAtStart(LatLng fix) {
    if (fix is NavigationFix &&
        (!fix.accuracy.isFinite ||
            fix.accuracy < 0 ||
            fix.accuracy > 25 ||
            DateTime.now().difference(fix.timestamp).abs() >
                const Duration(seconds: 10))) {
      return;
    }
    while (completed < stops.length &&
        fix.distanceTo(stops[completed].location) <= 15) {
      completed++;
    }
  }

  bool update(RouteCandidate route, int stepIndex, LatLng fix) {
    if (completed == stops.length) return false;
    if (fix is NavigationFix &&
        (!fix.accuracy.isFinite ||
            fix.accuracy < 0 ||
            fix.accuracy > 25 ||
            DateTime.now().difference(fix.timestamp).abs() >
                const Duration(seconds: 10))) {
      return false;
    }
    // Use the server's road-snapped leg end, not the centre of a POI building.
    // Both route progress and proximity are required: merely riding past a
    // later stop on a loop, or a coarse GPS fix, cannot consume that stop.
    for (var i = 0; i < route.steps.length; i++) {
      final step = route.steps[i];
      if (step.waypointIndex == completed - _routeBase &&
          stepIndex >= i &&
          fix.distanceTo(step.end) <= 25) {
        completed++;
        return true;
      }
    }
    return false;
  }
}
