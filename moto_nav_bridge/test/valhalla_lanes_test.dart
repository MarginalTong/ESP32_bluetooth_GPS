import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/lane_guidance.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/valhalla/valhalla_lanes.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

import 'valhalla_directions_service_test.dart' show points, response;

/// A lane as Valhalla's OSRM format writes it.
Map<String, Object> lane(bool valid, {bool active = false}) => {
  'indications': ['straight'],
  'valid': valid,
  'active': active,
};

/// The OSRM-format twin of the test route: depart at points[0], turn at
/// points[1] with [lanes], arrive at points[2].
Map<String, dynamic> osrm({
  List<Map<String, Object>>? lanes,
  LatLng? turnAt,
  int routes = 1,
}) {
  final turn = turnAt ?? points[1];
  Map<String, Object> step(String type, LatLng at, [Object? lanes]) => {
    'maneuver': {
      'type': type,
      'location': [at.longitude, at.latitude],
    },
    'intersections': [
      {'lanes': ?lanes},
    ],
  };
  return {
    'routes': [
      for (var i = 0; i < routes; i++)
        {
          'legs': [
            {
              'steps': [
                step('depart', points[0]),
                step('turn', turn, lanes),
                step('arrive', points[2]),
              ],
            },
          ],
        },
    ],
  };
}

final threeLanes = [lane(false), lane(true), lane(true)];

void main() {
  final route = ValhallaDirectionsService.parseRoutesJson(
    jsonEncode(response()),
  );

  group('LaneGuidance', () {
    test('keeps a contiguous run that leaves some lanes out', () {
      final lanes = LaneGuidance.fromFlags([false, true, true])!;
      expect((lanes.first, lanes.last, lanes.count), (1, 2, 2));
      expect((lanes.fromLeft, lanes.fromRight), (1, 0));
    });

    test('says nothing for no lane, every lane or a split run', () {
      expect(LaneGuidance.fromFlags([false, false]), isNull);
      expect(LaneGuidance.fromFlags([true, true, true]), isNull);
      expect(LaneGuidance.fromFlags([true, false, true]), isNull);
      expect(LaneGuidance.fromFlags([true]), isNull);
      expect(LaneGuidance.fromFlags(List.filled(9, false)..[0] = true), isNull);
    });
  });

  group('attach', () {
    test('puts lanes on the maneuver at the same point', () {
      final out = ValhallaLanes.attach(
        route,
        jsonEncode(osrm(lanes: threeLanes)),
      );
      expect(out.single.steps.first.lanes, isNull);
      expect(
        out.single.steps[1].lanes,
        LaneGuidance.fromFlags([false, true, true]),
      );
    });

    test('prefers the recommended lanes over every usable one', () {
      final out = ValhallaLanes.attach(
        route,
        jsonEncode(
          osrm(lanes: [lane(true), lane(true, active: true), lane(false)]),
        ),
      );
      expect(
        out.single.steps[1].lanes,
        LaneGuidance.fromFlags([false, true, false]),
      );
    });

    test('a route that does not line up gets no lanes', () {
      final moved = LatLng(points[1].latitude + 0.0001, points[1].longitude);
      final out = ValhallaLanes.attach(
        route,
        jsonEncode(osrm(lanes: threeLanes, turnAt: moved)),
      );
      expect(out.single.steps[1].lanes, isNull);
    });

    test('a missing or malformed lane response leaves routes unchanged', () {
      for (final body in [null, '{broken', '{}', '{"routes": [{"legs": 1}]}']) {
        expect(ValhallaLanes.attach(route, body), same(route));
      }
      final badLane = jsonEncode(
        osrm(
          lanes: [
            {'valid': 'yes'},
            lane(true),
          ],
        ),
      );
      expect(
        ValhallaLanes.attach(route, badLane).single.steps[1].lanes,
        isNull,
      );
    });
  });

  group('service', () {
    test('asks for the OSRM format with the same route request', () async {
      final formats = <String, Map<String, dynamic>>{};
      final service = ValhallaDirectionsService(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          formats[body['format'] as String] = body;
          return http.Response(
            jsonEncode(
              body['format'] == 'osrm' ? osrm(lanes: threeLanes) : response(),
            ),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final routes = await service.fetchRoutes(
        origin: points.first,
        destination: points.last,
      );
      expect(formats.keys, unorderedEquals(['json', 'osrm']));
      expect(formats['osrm']!['locations'], formats['json']!['locations']);
      expect(routes.single.steps[1].lanes, isNotNull);
    });

    test('a failed lane request still returns the route', () async {
      final service = ValhallaDirectionsService(
        client: MockClient((request) async {
          final osrmRequest = jsonDecode(request.body)['format'] == 'osrm';
          return osrmRequest
              ? http.Response('busy', 503)
              : http.Response(jsonEncode(response()), 200);
        }),
      );
      addTearDown(service.dispose);
      final routes = await service.fetchRoutes(
        origin: points.first,
        destination: points.last,
      );
      expect(routes.single.steps, hasLength(2));
      expect(routes.single.steps[1].lanes, isNull);
    });

    test('lane guidance can be switched off', () async {
      var calls = 0;
      final service = ValhallaDirectionsService(
        laneGuidance: false,
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(response()), 200);
        }),
      );
      addTearDown(service.dispose);
      await service.fetchRoutes(origin: points.first, destination: points.last);
      expect(calls, 1);
    });
  });
}
