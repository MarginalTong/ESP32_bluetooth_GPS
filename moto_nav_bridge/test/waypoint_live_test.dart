import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

void main() {
  test(
    'configured Valhalla supports a real Sydney three-location itinerary',
    () async {
      // Fixed public landmarks, never the rider's current location or addresses.
      const origin = LatLng(-33.8842, 151.1941);
      const via = LatLng(-33.8895, 151.1907);
      const end = LatLng(-33.8929, 151.1797);
      final service = ValhallaDirectionsService(
        timeout: const Duration(seconds: 20),
      );
      addTearDown(service.dispose);
      final routes = await service.fetchWaypointRoutes(
        origin: origin,
        destination: end,
        waypoints: [via],
      );
      expect(routes, isNotEmpty);
      final route = routes.first;
      expect(route.steps.where((s) => s.waypointIndex != null), hasLength(1));
      expect(route.steps.first.start.distanceTo(origin), lessThan(150));
      expect(route.steps.last.end.distanceTo(end), lessThan(150));
      expect(
        route.steps
            .singleWhere((s) => s.waypointIndex == 0)
            .end
            .distanceTo(via),
        lessThan(150),
      );
      expect(route.expectedTravelTimeSeconds, greaterThan(0));
      expect(route.distanceMeters, greaterThan(0));
    },
    skip: !const bool.fromEnvironment('NAVIO_LIVE_ROUTE_TEST'),
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
