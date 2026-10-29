import '../models/device_direction.dart';
import '../models/route_candidate.dart';

/// Select the fastest eligible candidate, then the shortest for equal ETAs.
/// Routing constraints are applied by the provider and [eligible]; turn counts
/// are only tie-breakers, never a reason to choose a slower route. Missing or
/// invalid metrics rank after known ones. Exact ties retain provider order.
int preferredRouteIndex(List<RouteCandidate> routes,
    {bool Function(RouteCandidate)? eligible, bool avoidEarlyUTurns = false}) {
  var selected = -1;
  for (var i = 0; i < routes.length; i++) {
    final route = routes[i];
    if (route.steps.isEmpty || (eligible != null && !eligible(route))) continue;
    if (selected < 0 ||
        _compareRoutes(route, routes[selected], avoidEarlyUTurns) < 0) {
      selected = i;
    }
  }
  return selected;
}

int _compareRoutes(RouteCandidate a, RouteCandidate b, bool avoidEarlyUTurns) {
  final time =
      _compareMetric(a.expectedTravelTimeSeconds, b.expectedTravelTimeSeconds);
  if (time != 0) return time;
  final distance = _compareMetric(a.distanceMeters, b.distanceMeters);
  if (distance != 0) return distance;
  if (avoidEarlyUTurns) {
    final earlyA = _hasEarlyUTurn(a), earlyB = _hasEarlyUTurn(b);
    if (earlyA != earlyB) return earlyA ? 1 : -1;
  }
  int turns(RouteCandidate route) => route.steps
      .where((step) => step.direction == DeviceDirection.uturn)
      .length;
  return turns(a).compareTo(turns(b));
}

int _compareMetric(int? a, int? b) {
  final knownA = a != null && a >= 0, knownB = b != null && b >= 0;
  if (knownA != knownB) return knownA ? -1 : 1;
  return knownA ? a.compareTo(b!) : 0;
}

bool _hasEarlyUTurn(RouteCandidate route) {
  var traveled = 0.0;
  for (final step in route.steps) {
    if (step.direction == DeviceDirection.uturn && traveled <= 500) return true;
    traveled += step.distanceMeters;
  }
  return false;
}
