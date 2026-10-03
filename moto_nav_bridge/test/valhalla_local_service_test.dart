import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

// Explicit opt-in: normal test runs never require a server or send coordinates.
// Uses synthetic Sydney positions and a hard-coded loopback endpoint only.
void main() {
  test('local Valhalla returns parseable routes for opposite travel courses',
      () async {
    final service = ValhallaDirectionsService(
      routeUrl: 'http://127.0.0.1:8002/route',
    );
    addTearDown(service.dispose);
    final lengths = <double>[];
    for (final heading in [0.0, 180.0]) {
      final routes = await service.fetchRoutes(
        origin: NavigationFix(-33.883, 151.185,
            heading: heading, accuracy: 5, speed: 5, timestamp: DateTime.now()),
        destination: const LatLng(-33.875, 151.205),
      );
      expect(routes, isNotEmpty);
      expect(routes.first.steps, isNotEmpty);
      expect(routes.first.attributionUrl,
          'https://www.openstreetmap.org/copyright');
      expect(routes.first.distanceMeters, isNotNull);
      lengths.add(routes.first.distanceMeters!.toDouble());
    }
    expect(lengths.first, isNot(lengths.last));
  }, skip: !const bool.fromEnvironment('VALHALLA_LOCAL_TEST'));
}
