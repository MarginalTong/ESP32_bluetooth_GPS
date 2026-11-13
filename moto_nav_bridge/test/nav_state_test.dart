import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/config/ble_constants.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';

void main() {
  group('NavState wire format', () {
    test('matches the firmware contract exactly', () {
      const s = NavState(direction: DeviceDirection.left, distanceMeters: 200);
      expect(s.toWire(), '{"dir":"LEFT","dist":200}');
    });

    test('BEAR_RIGHT serializes with the firmware token', () {
      const s = NavState(
        direction: DeviceDirection.bearRight,
        distanceMeters: 40,
      );
      expect(s.toWire(), '{"dir":"BEAR_RIGHT","dist":40}');
    });

    test('stopped state is STOP/0', () {
      expect(NavState.stopped.toWire(), '{"dir":"STOP","dist":0}');
    });

    test('end of trip is distinct from a temporary STOP', () {
      expect(NavState.ended.toWire(), '{"dir":"STOP","dist":0,"end":true}');
      expect(NavState.ended, isNot(NavState.stopped));
    });

    test('route preview serializes as compact p array', () {
      const s = NavState(
        direction: DeviceDirection.up,
        distanceMeters: 120,
        routePreviewPoints: [64, 20, 64, 12, 58, 2],
      );
      expect(s.toWire(), '{"dir":"UP","dist":120,"P":[64,20,64,12,58,2]}');
    });

    test('side roads are dropped, farthest first, to fit the firmware', () {
      // Widest coordinates: 20 route points and 8 arms would be too long.
      final wide = NavState(
        direction: DeviceDirection.bearRight,
        distanceMeters: 9999,
        rerouting: true,
        routePreviewPoints: List.filled(40, 1270),
        sideRoadPreviewPoints: [
          for (var arm = 0; arm < 8; arm++) ...[1000 + arm, 100, 1100, 100],
        ],
      );
      final wire = wide.toWire();
      expect(wire.length, lessThanOrEqualTo(BleConstants.maxNavJsonBytes));
      final roads = RegExp(r'"R":\[([0-9,]*)\]').firstMatch(wire)!.group(1)!;
      final values = roads.split(',').map(int.parse).toList();
      // Whole segments only, and the nearest ones are the ones kept.
      expect(values.length % 4, 0);
      expect(values.length, inInclusiveRange(4, 28));
      expect(values.sublist(0, 4), [1000, 100, 1100, 100]);
      expect(wire, endsWith(']}'));
    });

    test('a typical packet keeps all eight side roads', () {
      final typical = NavState(
        direction: DeviceDirection.left,
        distanceMeters: 120,
        routePreviewPoints: [
          for (var i = 0; i < 20; i++) ...[640, 340 - i * 16],
        ],
        sideRoadPreviewPoints: [
          for (var arm = 0; arm < 8; arm++) ...[640, 300, 740, 300],
        ],
      );
      expect('640,300,740,300'.allMatches(typical.toWire()), hasLength(8));
    });

    test('side roads serialize as compact r array after route preview', () {
      const s = NavState(
        direction: DeviceDirection.left,
        distanceMeters: 80,
        routePreviewPoints: [64, 34, 64, 20],
        sideRoadPreviewPoints: [42, 22, 86, 22],
      );
      expect(
        s.toWire(),
        '{"dir":"LEFT","dist":80,"P":[64,34,64,20],"R":[42,22,86,22]}',
      );
    });

    test('temporary cached map has no stale turn or distance', () {
      const s = NavState(
        direction: DeviceDirection.stop,
        distanceMeters: 0,
        rerouting: true,
        routePreviewPoints: [64, 34, 64, 20],
      );
      expect(
        s.toWire(),
        '{"dir":"STOP","dist":0,"P":[64,34,64,20],"rerouting":true}',
      );
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
