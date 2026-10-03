import '../models/device_direction.dart';
import '../models/route_candidate.dart';

/// Prefer fewer known U-turns, retaining provider order for equal counts.
/// This is a preference, not a guarantee that the provider exposed every turn.
int preferredRouteIndex(List<RouteCandidate> routes,
    {bool Function(RouteCandidate)? eligible}) {
  var selected = -1;
  int? fewest;
  for (var i = 0; i < routes.length; i++) {
    final route = routes[i];
    if (route.steps.isEmpty || (eligible != null && !eligible(route))) continue;
    final turns = route.steps
        .where((step) => step.direction == DeviceDirection.uturn)
        .length;
    if (fewest == null || turns < fewest) {
      selected = i;
      fewest = turns;
    }
  }
  return selected;
}
