import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';
import 'package:moto_nav_bridge/services/valhalla/polyline6.dart';
import 'package:moto_nav_bridge/services/valhalla/valhalla_speed_limits.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

import 'valhalla_directions_service_test.dart' show points, response;

/// A `trace_attributes` response: edges as (begin, end, limit or null).
String trace(List<(int, int, Object?)> edges) => jsonEncode({
  'units': 'kilometers',
  'edges': [
    for (final (begin, end, limit) in edges)
      {
        'begin_shape_index': begin,
        'end_shape_index': end,
        'speed_limit': ?limit,
      },
  ],
});

/// Five points 100 m apart heading north, as two steps and one leg.
final line = [for (var i = 0; i < 5; i++) LatLng(-33.9 + i * 0.0009, 151.2)];
RouteStep step(int from, int to, {int? stop}) => RouteStep(
  direction: DeviceDirection.up,
  start: line[from],
  end: line[to],
  distanceMeters: (to - from) * 100,
  geometry: line.sublist(from, to + 1),
  waypointIndex: stop,
);
final route = RouteCandidate(steps: [step(0, 2), step(2, 4)]);

void main() {
  test('a decoded shape encodes back to the same line', () {
    const shape = [
      LatLng(-33.868820, 151.209296),
      LatLng(-33.815001, 151.001),
      LatLng(0, 0),
      LatLng(12.345678, -98.765432),
    ];
    final decoded = Polyline6.decode(Polyline6.encode(shape));
    expect(decoded, hasLength(shape.length));
    for (var i = 0; i < shape.length; i++) {
      expect(decoded[i].latitude, closeTo(shape[i].latitude, 1e-9));
      expect(decoded[i].longitude, closeTo(shape[i].longitude, 1e-9));
    }
  });

  group('request', () {
    test('asks about the leg as one line, matched edge by edge', () {
      final request = ValhallaSpeedLimits.request(route.steps)!;
      final shape = Polyline6.decode(request['encoded_polyline']);
      // The point shared by the two steps is sent once.
      expect(shape, hasLength(5));
      expect(request['shape_match'], 'edge_walk');
    });

    test('a route with stops is asked about leg by leg', () {
      final stops = RouteCandidate(steps: [step(0, 2, stop: 0), step(2, 4)]);
      final legs = ValhallaSpeedLimits.legs(stops);
      expect(legs.map((leg) => leg.length), [1, 1]);
    });

    test('steps that do not join have no shape to ask about', () {
      expect(ValhallaSpeedLimits.request([step(0, 1), step(2, 4)]), isNull);
    });
  });

  group('attach', () {
    test('gives every segment of every step its limit', () {
      final out = ValhallaSpeedLimits.attach(route, [
        trace([(0, 1, 50), (1, 3, 60), (3, 4, 80)]),
      ]);
      expect(out.steps[0].speedLimitsKph, [50, 60]);
      expect(out.steps[1].speedLimitsKph, [60, 80]);
    });

    test('a road with no recorded limit stays unknown', () {
      final out = ValhallaSpeedLimits.attach(route, [
        trace([(0, 2, 50), (2, 3, null), (3, 4, 0)]),
      ]);
      expect(out.steps[0].speedLimitsKph, [50, 50]);
      expect(out.steps[1].speedLimitsKph, [0, 0]);
    });

    test('limits no sign could show are not passed on', () {
      final out = ValhallaSpeedLimits.attach(route, [
        trace([(0, 1, 50), (1, 2, 255), (2, 3, 3), (3, 4, '60')]),
      ]);
      expect(out.steps[0].speedLimitsKph, [50, 0]);
      expect(out.steps[1].speedLimitsKph, [0, 0]);
    });

    test('an unusable response leaves the route unchanged', () {
      final bodies = [
        null,
        '{broken',
        '{}',
        '{"edges": []}',
        // Indexes outside the shape that was sent.
        trace([(0, 9, 50)]),
        trace([(3, 2, 50)]),
        // No limit anywhere: nothing to attach.
        trace([(0, 4, null)]),
      ];
      for (final body in bodies) {
        expect(ValhallaSpeedLimits.attach(route, [body]), same(route));
      }
      // One response for a route with two legs.
      final stops = RouteCandidate(steps: [step(0, 2, stop: 0), step(2, 4)]);
      expect(
        ValhallaSpeedLimits.attach(stops, [
          trace([(0, 2, 50)]),
        ]),
        same(stops),
      );
    });

    test('a failed leg does not cost the other leg its limits', () {
      final stops = RouteCandidate(steps: [step(0, 2, stop: 0), step(2, 4)]);
      final out = ValhallaSpeedLimits.attach(stops, [
        null,
        trace([(0, 2, 70)]),
      ]);
      expect(out.steps[0].speedLimitsKph, isNull);
      expect(out.steps[1].speedLimitsKph, [70, 70]);
    });
  });

  group('engine', () {
    final limited = ValhallaSpeedLimits.attach(route, [
      trace([(0, 1, 50), (1, 3, 60), (3, 4, null)]),
    ]);
    LatLng at(double metersNorth, {double metersEast = 0}) =>
        LatLng(-33.9 + metersNorth * 0.000009, 151.2 + metersEast * 0.0000108);

    test('reports the limit of the segment the rider is on', () {
      final engine = NavigationEngine(limited.steps);
      expect(engine.update(at(50)).speedLimitKph, 50);
      expect(engine.update(at(150)).speedLimitKph, 60);
      // Through the maneuver point and onto the second step.
      engine.update(at(195));
      expect(engine.update(at(250)).speedLimitKph, 60);
    });

    test('reports nothing where the map has no limit', () {
      final engine = NavigationEngine(limited.steps);
      engine.update(at(195));
      expect(engine.update(at(350)).speedLimitKph, isNull);
    });

    test('reports nothing when the rider is not on the route', () {
      final engine = NavigationEngine(limited.steps);
      expect(engine.update(at(50, metersEast: 40)).speedLimitKph, isNull);
      expect(engine.update(at(50, metersEast: 5)).speedLimitKph, 50);
    });

    test('a route without limits reports nothing', () {
      expect(
        NavigationEngine(route.steps).update(at(50)).speedLimitKph,
        isNull,
      );
    });
  });

  group('service', () {
    test(
      'asks for limits along the returned route and attaches them',
      () async {
        final paths = <String>[];
        final service = ValhallaDirectionsService(
          routeUrl: 'https://routing.example/api/route',
          laneGuidance: false,
          client: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/trace_attributes')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(Polyline6.decode(body['encoded_polyline']), hasLength(3));
              return http.Response(trace([(0, 1, 40), (1, 2, 60)]), 200);
            }
            return http.Response(jsonEncode(response()), 200);
          }),
        );
        addTearDown(service.dispose);
        final routes = await service.fetchRoutes(
          origin: points.first,
          destination: points.last,
        );
        expect(paths, ['/api/route', '/api/trace_attributes']);
        expect(routes.single.steps[0].speedLimitsKph, [40]);
        expect(routes.single.steps[1].speedLimitsKph, [60]);
      },
    );

    test('a failed limit request still returns the route', () async {
      final service = ValhallaDirectionsService(
        routeUrl: 'https://routing.example/route',
        laneGuidance: false,
        client: MockClient(
          (request) async => request.url.path.endsWith('/trace_attributes')
              ? http.Response('busy', 503)
              : http.Response(jsonEncode(response()), 200),
        ),
      );
      addTearDown(service.dispose);
      final routes = await service.fetchRoutes(
        origin: points.first,
        destination: points.last,
      );
      expect(routes.single.steps, hasLength(2));
      expect(routes.single.steps[0].speedLimitsKph, isNull);
    });
  });
}
