import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moto_nav_bridge/config/api_config.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

// Explicit opt-in: normal test runs never require a server or send coordinates.
// Uses synthetic Sydney positions against the configured cloud endpoint.
void main() {
  test('cloud Valhalla status and routes are usable', () async {
    final client = http.Client();
    addTearDown(client.close);
    final status = await client
        .get(Uri.parse(ApiConfig.valhallaStatusUrl))
        .timeout(const Duration(seconds: 15));
    expect(status.statusCode, 200);
    expect(status.body, contains('3.9.0'));
    expect(ApiConfig.valhallaRouteUrl, 'https://nav.williamligallery.uk/route');
    final service = ValhallaDirectionsService();
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
  }, skip: !const bool.fromEnvironment('VALHALLA_CLOUD_TEST'));
}
