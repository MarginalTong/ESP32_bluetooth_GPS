import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/directions_exception.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';
import 'package:moto_nav_bridge/services/waypoint_plan.dart';
import 'valhalla_directions_service_test.dart' show encode;

const start = LatLng(0, 0), stop = LatLng(.001, 0), end = LatLng(.001, .001);
const place = PlaceResult(name: 'Stop', address: '', location: stop);
Map<String, dynamic> itinerary() => {
  'trip': {
    'status': 0,
    'units': 'kilometers',
    'summary': {'length': .222, 'time': 30},
    'legs': [leg(start, stop), leg(stop, end)],
  },
};
Map<String, dynamic> leg(LatLng a, LatLng b) => {
  'shape': encode([a, b]),
  'maneuvers': [
    {
      'type': 1,
      'begin_shape_index': 0,
      'end_shape_index': 1,
      'length': .111,
      'travel_mode': 'drive',
    },
    {'type': 4, 'begin_shape_index': 1, 'end_shape_index': 1, 'length': 0},
  ],
};

void main() {
  test(
    'ordered stops use breaks and multi-location requests disable alternates',
    () async {
      final service = ValhallaDirectionsService(
        client: MockClient((r) async {
          final json = jsonDecode(r.body);
          expect(json['locations'], [
            {'lat': 0.0, 'lon': 0.0},
            {'lat': .001, 'lon': 0.0, 'type': 'break'},
            {'lat': .001, 'lon': .001},
          ]);
          expect(json['alternates'], 0);
          return http.Response(jsonEncode(itinerary()), 200);
        }),
      );
      addTearDown(service.dispose);
      final route = (await service.fetchWaypointRoutes(
        origin: start,
        destination: end,
        waypoints: [stop],
      )).single;
      expect(route.steps, hasLength(2));
      expect(route.steps.first.waypointIndex, 0);
      expect(route.steps.last.waypointIndex, isNull);
      expect(route.steps.last.direction, DeviceDirection.right);
      expect(route.distanceMeters, 222);
      expect(route.expectedTravelTimeSeconds, 30);
      final engine = NavigationEngine(route.steps);
      expect(engine.update(stop).direction, isNot(DeviceDirection.arrived));
      expect(engine.isFinished, isFalse);
      expect(engine.update(end).direction, DeviceDirection.arrived);
    },
  );

  test('missing, extra and disconnected legs are rejected', () {
    expect(
      () => ValhallaDirectionsService.parseRoutesJson(jsonEncode(itinerary())),
      throwsA(isA<DirectionsException>()),
    );
    final missing = itinerary();
    (missing['trip']['legs'] as List).removeLast();
    expect(
      () => ValhallaDirectionsService.parseRoutesJson(
        jsonEncode(missing),
        expectedLegs: 2,
      ),
      throwsA(isA<DirectionsException>()),
    );
    final broken = itinerary();
    broken['trip']['legs'][1] = leg(const LatLng(1, 1), end);
    expect(
      () => ValhallaDirectionsService.parseRoutesJson(
        jsonEncode(broken),
        expectedLegs: 2,
      ),
      throwsA(isA<DirectionsException>()),
    );
  });

  test('invalid and over-limit waypoints do not issue a request', () async {
    var requests = 0;
    final service = ValhallaDirectionsService(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(service.dispose);
    for (final stops in [
      List.filled(6, stop),
      [const LatLng(double.nan, 0)],
    ]) {
      await expectLater(
        service.fetchWaypointRoutes(
          origin: start,
          destination: end,
          waypoints: stops,
        ),
        throwsA(isA<DirectionsException>()),
      );
    }
    expect(requests, 0);
  });

  test('progress consumes only the next stop on-route with a good fix', () {
    final route = ValhallaDirectionsService.parseRoutesJson(
      jsonEncode(itinerary()),
      expectedLegs: 2,
    ).single;
    final plan = WaypointPlan([place])..bindRoute();
    expect(plan.update(route, 0, end), isFalse);
    expect(
      plan.update(
        route,
        0,
        NavigationFix(
          stop.latitude,
          stop.longitude,
          accuracy: 60,
          heading: 0,
          speed: 0,
          timestamp: DateTime.now(),
        ),
      ),
      isFalse,
    );
    expect(plan.remaining, [stop]);
    expect(plan.update(route, 1, stop), isTrue);
    expect(plan.remaining, isEmpty);
    expect(plan.update(route, 1, stop), isFalse);
    expect(() => WaypointPlan(List.filled(6, place)), throwsArgumentError);
  });
}
