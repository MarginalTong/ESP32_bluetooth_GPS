import '../models/device_direction.dart';
import '../models/route_candidate.dart';

/// Prefer fewer known U-turns, retaining provider order for equal counts.
/// This is a preference, not a guarantee that the provider exposed every turn.
int preferredRouteIndex(List<RouteCandidate> routes,
    {bool Function(RouteCandidate)? eligible, bool avoidEarlyUTurns = false}) {
  var selected = -1;
  int? fewest;
  var selectedHasEarlyTurn = false;
  for (var i = 0; i < routes.length; i++) {
    final route = routes[i];
    if (route.steps.isEmpty || (eligible != null && !eligible(route))) continue;
    final turns = route.steps
        .where((step) => step.direction == DeviceDirection.uturn)
        .length;
    // Maneuvers apply at the start of each step. This is a preference among
    // returned candidates, not a claim about road class or legal permission.
    var traveled = 0.0;
    var hasEarlyTurn = false;
    for (final step in route.steps) {
      if (step.direction == DeviceDirection.uturn && traveled <= 500) {
        hasEarlyTurn = true;
      }
      traveled += step.distanceMeters;
    }
    final earlyRankBetter =
        avoidEarlyUTurns && selectedHasEarlyTurn && !hasEarlyTurn;
    final sameEarlyRank =
        !avoidEarlyUTurns || selectedHasEarlyTurn == hasEarlyTurn;
    if (fewest == null ||
        earlyRankBetter ||
        (sameEarlyRank && turns < fewest)) {
      selected = i;
      fewest = turns;
      selectedHasEarlyTurn = hasEarlyTurn;
    }
  }
  return selected;
}
