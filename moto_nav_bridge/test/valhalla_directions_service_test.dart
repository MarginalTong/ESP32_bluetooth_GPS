import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/directions_exception.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

void main() {
  const endpoint = 'https://routing.example/route';
  final fails = throwsA(isA<DirectionsException>());

  test('route preferences are included for every route request', () async {
    final service = ValhallaDirectionsService(
        routePreferences: () => {
              'use_highways': 0.0,
              'use_tolls': 0.0,
              'use_ferry': 0.0,
              'exclude_tunnels': true
            },
        client: MockClient((request) async {
          expect(jsonDecode(request.body)['costing_options'], {
            'auto': {
              'use_highways': 0.0,
              'use_tolls': 0.0,
              'use_ferry': 0.0,
              'exclude_tunnels': true
            }
          });
          return http.Response(jsonEncode(response()), 200);
        }));
    addTearDown(service.dispose);
    await service.fetchRoutes(origin: points.first, destination: points.last);
    await service.fetchRoutes(origin: points[1], destination: points.last);
  });

  test('default endpoint is the cloud HTTPS route on port 443', () async {
    final service =
        ValhallaDirectionsService(client: MockClient((request) async {
      expect(request.url.toString(), 'https://nav.williamligallery.uk/route');
      expect(request.url.port, 443);
      expect(jsonDecode(request.body)['costing'], 'auto');
      return http.Response(jsonEncode(response()), 200);
    }));
    addTearDown(service.dispose);
    await service.fetchRoutes(origin: points.first, destination: points.last);
  });

  test('malformed HTTP body becomes a handled routing error', () async {
    for (final body in ['<html>upstream error</html>', '{broken', '{}']) {
      final service = ValhallaDirectionsService(
          client: MockClient((_) async => http.Response(body, 200)));
      addTearDown(service.dispose);
      await expectLater(
          service.fetchRoutes(origin: points.first, destination: points.last),
          fails);
    }
  });

  test(
      'POST sends measured travel heading and actual origin, not a shifted point',
      () async {
    late Map<String, dynamic> payload;
    final service = ValhallaDirectionsService(
      routeUrl: endpoint,
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), endpoint);
        expect(request.followRedirects, isFalse);
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(response()), 200);
      }),
    );
    addTearDown(service.dispose);
    final fix = NavigationFix(0, 0,
        heading: 359.9,
        accuracy: 5,
        speed: 5,
        timestamp: DateTime.now().subtract(const Duration(milliseconds: 10)));
    final routes =
        await service.fetchRoutes(origin: fix, destination: points.last);
    final start = (payload['locations'] as List).first as Map;
    expect(
        start, {'lat': 0.0, 'lon': 0.0, 'heading': 0, 'heading_tolerance': 60});
    expect(payload['costing'], 'auto');
    expect(payload['alternates'], 2);
    expect(payload['units'], 'kilometers');
    expect(payload['format'], 'json');
    expect(payload['directions_type'], 'maneuvers');
    expect(routes, hasLength(1));
    expect(
        routes.first.attributionUrl, 'https://www.openstreetmap.org/copyright');
  });

  test('plain, stationary, inaccurate, invalid and stale courses are not sent',
      () async {
    final now = DateTime.now();
    final origins = <LatLng>[
      points.first,
      NavigationFix(0, 0, heading: 90, accuracy: 5, speed: 0, timestamp: now),
      NavigationFix(0, 0, heading: 90, accuracy: 40, speed: 5, timestamp: now),
      NavigationFix(0, 0, heading: -1, accuracy: 5, speed: 5, timestamp: now),
      NavigationFix(0, 0,
          heading: double.nan, accuracy: 5, speed: 5, timestamp: now),
      NavigationFix(0, 0,
          heading: 90, accuracy: 5, speed: double.infinity, timestamp: now),
      NavigationFix(0, 0,
          heading: 90,
          accuracy: 5,
          speed: 5,
          timestamp: now.subtract(const Duration(seconds: 11))),
      NavigationFix(0, 0,
          heading: 90,
          accuracy: 5,
          speed: 5,
          timestamp: now.add(const Duration(seconds: 30))),
    ];
    final service = ValhallaDirectionsService(
        routeUrl: endpoint,
        client: MockClient((request) async {
          final start =
              (jsonDecode(request.body)['locations'] as List).first as Map;
          expect(start.containsKey('heading'), isFalse);
          return http.Response(jsonEncode(response()), 200);
        }));
    addTearDown(service.dispose);
    for (final origin in origins) {
      await service.fetchRoutes(origin: origin, destination: points.last);
    }
  });

  test('polyline6 and maneuver start indices announce left before the junction',
      () {
    final route =
        ValhallaDirectionsService.parseRoutesJson(jsonEncode(response())).first;
    expect(route.steps, hasLength(2));
    expect(route.steps[0].direction, DeviceDirection.up);
    expect(route.steps[1].direction, DeviceDirection.left);
    expect(route.steps[0].end.latitude, 0.001);
    expect(route.steps[1].end.longitude, -0.001);
    expect(route.distanceMeters, 222);
    expect(route.expectedTravelTimeSeconds, 25);
    final engine = NavigationEngine(route.steps);
    expect(engine.update(points.first).direction, DeviceDirection.left);
    expect(engine.update(points[1]).direction, DeviceDirection.up);
    expect(engine.update(points.last).direction, DeviceDirection.arrived);
  });

  test(
      'parses native alternates and retains U-turns, signed coordinates and units',
      () {
    final input = response();
    final alternate = trip(turnType: 12);
    alternate['units'] = 'miles';
    input['alternates'] = [
      {'trip': alternate},
      {'trip': trip(turnType: 10)}
    ];
    final routes = ValhallaDirectionsService.parseRoutesJson(jsonEncode(input));
    expect(routes, hasLength(3));
    expect(routes[1].steps[1].direction, DeviceDirection.uturn);
    expect(routes[1].distanceMeters, 357);
    expect(routes[2].steps[1].direction, DeviceDirection.right);
    final southern = trip();
    (southern['legs'] as List).first['shape'] = encode([
      const LatLng(-33.9, 151.1),
      const LatLng(-33.899, 151.1),
      const LatLng(-33.899, 151.099),
    ]);
    final parsed = ValhallaDirectionsService.parseRoutesJson(
        jsonEncode({'trip': southern})).first;
    expect(parsed.polyline.first.latitude, -33.9);
    expect(parsed.polyline.last.longitude, 151.099);
  });

  for (final entry in <int, DeviceDirection>{
    8: DeviceDirection.up,
    9: DeviceDirection.bearRight,
    10: DeviceDirection.right,
    11: DeviceDirection.right,
    12: DeviceDirection.uturn,
    13: DeviceDirection.uturn,
    14: DeviceDirection.left,
    15: DeviceDirection.left,
    16: DeviceDirection.bearLeft,
    18: DeviceDirection.bearRight,
    19: DeviceDirection.bearLeft,
    23: DeviceDirection.bearRight,
    24: DeviceDirection.bearLeft,
    37: DeviceDirection.bearRight,
    38: DeviceDirection.bearLeft,
  }.entries) {
    test('maps maneuver ${entry.key} without disguising explicit U-turns', () {
      final routes = ValhallaDirectionsService.parseRoutesJson(
          jsonEncode({'trip': trip(turnType: entry.key)}));
      expect(routes.first.steps[1].direction, entry.value);
    });
  }

  test('rejects malformed JSON, API error, empty trip and truncated polyline',
      () {
    for (final bad in [
      'not json',
      '[]',
      '{}',
      '{"error_code":442}',
      '{"trip":{"status":1}}'
    ]) {
      expect(() => ValhallaDirectionsService.parseRoutesJson(bad), fails);
    }
    for (final shape in ['?', '_', '?_', '\u0000?', '~~~~~~~?']) {
      final input = trip();
      (input['legs'] as List).first['shape'] = shape;
      expect(
          () => ValhallaDirectionsService.parseRoutesJson(
              jsonEncode({'trip': input})),
          fails);
    }
  });

  test(
      'rejects invalid indices, missing destination, unknown or non-drive maneuvers',
      () {
    for (var kind = 0; kind < 5; kind++) {
      final input = trip();
      final maneuvers = (input['legs'] as List).first['maneuvers'] as List;
      switch (kind) {
        case 0:
          maneuvers[1]['begin_shape_index'] = 0;
        case 1:
          maneuvers[1]['end_shape_index'] = 999;
        case 2:
          maneuvers.removeLast();
        case 3:
          maneuvers[1]['type'] = 999;
        case 4:
          maneuvers[1]['travel_mode'] = 'pedestrian';
      }
      expect(
          () => ValhallaDirectionsService.parseRoutesJson(
              jsonEncode({'trip': input})),
          fails);
    }
  });

  test('missing/unsafe endpoint and bad coordinates fail before network',
      () async {
    var calls = 0;
    for (final url in [
      '',
      'http://example.com/route',
      'https://example.com:8002/route',
      'https://u:p@example.com/route',
      'https://example.com/route#secret',
      'https://example.com/other',
      'not a URL'
    ]) {
      final service = ValhallaDirectionsService(
          routeUrl: url,
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }));
      await expectLater(
          service.fetchRoutes(origin: points.first, destination: points.last),
          fails);
      service.dispose();
    }
    final service = ValhallaDirectionsService(
        routeUrl: endpoint,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    addTearDown(service.dispose);
    await expectLater(
        service.fetchRoutes(
            origin: const LatLng(double.nan, 0), destination: points.last),
        fails);
    expect(calls, 0);
  });

  test('HTTP and network errors are bounded and do not leak auth-bearing URLs',
      () async {
    for (final status in [301, 400, 429, 500]) {
      var calls = 0;
      final service = ValhallaDirectionsService(
          routeUrl: '$endpoint?key=secret',
          client: MockClient((_) async {
            calls++;
            return http.Response('secret', status);
          }));
      await expectLater(
          service.fetchRoutes(origin: points.first, destination: points.last),
          throwsA(isA<DirectionsException>()
              .having((e) => e.message, 'message', 'Valhalla HTTP $status')));
      expect(calls, 1);
      service.dispose();
    }
    final service = ValhallaDirectionsService(
        routeUrl: endpoint,
        client: MockClient((_) async {
          throw http.ClientException('secret at $endpoint');
        }));
    addTearDown(service.dispose);
    await expectLater(
        service.fetchRoutes(origin: points.first, destination: points.last),
        throwsA(isA<DirectionsException>().having(
            (e) => e.message, 'sanitized', 'Valhalla network request failed')));
  });

  test(
      'timeout aborts the outstanding request; dispose cancels and prevents reuse',
      () async {
    final client = HangingClient();
    final service = ValhallaDirectionsService(
        routeUrl: endpoint,
        client: client,
        timeout: const Duration(milliseconds: 5));
    await expectLater(
        service.fetchRoutes(origin: points.first, destination: points.last),
        throwsA(isA<DirectionsException>()
            .having((e) => e.message, 'timeout', contains('timed out'))));
    await pumpEventQueue();
    expect(client.aborted, isTrue);
    service.dispose();
    expect(client.closed, isTrue);
    await expectLater(
        service.fetchRoutes(origin: points.first, destination: points.last),
        fails);
  });
}

const points = [LatLng(0, 0), LatLng(0.001, 0), LatLng(0.001, -0.001)];

Map<String, dynamic> response() => {'trip': trip()};
Map<String, dynamic> trip({int turnType = 15}) => {
      'status': 0,
      'status_message': 'Found route between points',
      'units': 'kilometers',
      'summary': {'length': 0.222, 'time': 25},
      'legs': [
        {
          'shape': encode(points),
          'maneuvers': [
            {
              'type': 1,
              'begin_shape_index': 0,
              'end_shape_index': 1,
              'length': 0.111,
              'travel_mode': 'drive'
            },
            {
              'type': turnType,
              'begin_shape_index': 1,
              'end_shape_index': 2,
              'length': 0.111,
              'travel_mode': 'drive'
            },
            {
              'type': 4,
              'begin_shape_index': 2,
              'end_shape_index': 2,
              'length': 0.0,
              'travel_mode': 'drive'
            },
          ],
        }
      ],
    };

String encode(List<LatLng> shape) {
  final output = StringBuffer();
  var lat = 0, lon = 0;
  void append(int delta) {
    var n = delta < 0 ? ~(delta << 1) : delta << 1;
    while (n >= 32) {
      output.writeCharCode((n & 31) + 95);
      n >>= 5;
    }
    output.writeCharCode(n + 63);
  }

  for (final point in shape) {
    final nextLat = (point.latitude * 1e6).round();
    final nextLon = (point.longitude * 1e6).round();
    append(nextLat - lat);
    append(nextLon - lon);
    lat = nextLat;
    lon = nextLon;
  }
  return output.toString();
}

class HangingClient extends http.BaseClient {
  bool aborted = false, closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await (request as http.AbortableRequest).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException();
  }

  @override
  void close() {
    closed = true;
  }
}
