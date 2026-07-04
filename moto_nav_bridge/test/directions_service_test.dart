import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/services/directions_service.dart';

// A trimmed but realistic Directions response: 3 steps, first has no maneuver.
const _fixture = '''
{
  "status": "OK",
  "routes": [
    {
      "legs": [
        {
          "steps": [
            {
              "distance": {"value": 120},
              "start_location": {"lat": 37.0, "lng": -122.0},
              "end_location": {"lat": 37.001, "lng": -122.0}
            },
            {
              "maneuver": "turn-left",
              "distance": {"value": 300},
              "start_location": {"lat": 37.001, "lng": -122.0},
              "end_location": {"lat": 37.001, "lng": -122.003}
            },
            {
              "maneuver": "fork-right",
              "distance": {"value": 80},
              "start_location": {"lat": 37.001, "lng": -122.003},
              "end_location": {"lat": 37.002, "lng": -122.004}
            }
          ]
        }
      ]
    }
  ]
}
''';

void main() {
  group('DirectionsService.parseRouteJson', () {
    test('parses steps and maps maneuvers', () {
      final steps = DirectionsService.parseRouteJson(_fixture);
      expect(steps.length, 3);
      expect(steps[0].direction, DeviceDirection.up); // no maneuver
      expect(steps[0].distanceMeters, 120);
      expect(steps[1].direction, DeviceDirection.left);
      expect(steps[2].direction, DeviceDirection.bearRight);
      expect(steps[2].start.longitude, closeTo(-122.003, 1e-9));
    });

    test('throws on non-OK status', () {
      expect(
        () => DirectionsService.parseRouteJson(
            '{"status":"ZERO_RESULTS","routes":[]}'),
        throwsA(isA<DirectionsException>()),
      );
    });

    test('throws on empty routes', () {
      expect(
        () => DirectionsService.parseRouteJson('{"status":"OK","routes":[]}'),
        throwsA(isA<DirectionsException>()),
      );
    });

    test('throws on invalid JSON', () {
      expect(
        () => DirectionsService.parseRouteJson('not json'),
        throwsA(isA<DirectionsException>()),
      );
    });
  });
}
