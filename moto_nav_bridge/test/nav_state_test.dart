import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';

void main() {
  group('NavState wire format', () {
    test('matches the firmware contract exactly', () {
      const s = NavState(direction: DeviceDirection.left, distanceMeters: 200);
      expect(s.toWire(), '{"dir":"LEFT","dist":200}');
    });

    test('BEAR_RIGHT serializes with the firmware token', () {
      const s =
          NavState(direction: DeviceDirection.bearRight, distanceMeters: 40);
      expect(s.toWire(), '{"dir":"BEAR_RIGHT","dist":40}');
    });

    test('stopped state is STOP/0', () {
      expect(NavState.stopped.toWire(), '{"dir":"STOP","dist":0}');
    });

    test('route preview serializes as compact p array', () {
      const s = NavState(
        direction: DeviceDirection.up,
        distanceMeters: 120,
        routePreviewPoints: [64, 20, 64, 12, 58, 2],
      );
      expect(s.toWire(), '{"dir":"UP","dist":120,"p":[64,20,64,12,58,2]}');
    });

    test('toJson keys are dir/dist', () {
      const s = NavState(direction: DeviceDirection.up, distanceMeters: 500);
      expect(s.toJson(), {'dir': 'UP', 'dist': 500});
    });

    test('every direction wire token is uppercase and matches enum', () {
      for (final d in DeviceDirection.values) {
        expect(d.wire, d.wire.toUpperCase());
      }
    });

    test('equality and copyWith', () {
      const a = NavState(direction: DeviceDirection.up, distanceMeters: 100);
      expect(a.copyWith(distanceMeters: 100), a);
      expect(a.copyWith(distanceMeters: 90) == a, isFalse);
    });
  });
}
