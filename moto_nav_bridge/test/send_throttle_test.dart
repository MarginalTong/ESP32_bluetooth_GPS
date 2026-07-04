import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/services/send_throttle.dart';

void main() {
  NavState s(DeviceDirection d, int dist) =>
      NavState(direction: d, distanceMeters: dist);

  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  test('always sends the first state', () {
    final th = SendThrottle();
    expect(th.shouldSend(s(DeviceDirection.up, 500), t0), isTrue);
  });

  test('suppresses tiny distance changes within the interval', () {
    final th = SendThrottle(minDistanceDeltaMeters: 5);
    final first = s(DeviceDirection.up, 500);
    th.markSent(first, t0);
    // 2 m change, 100 ms later -> below both thresholds.
    expect(
      th.shouldSend(s(DeviceDirection.up, 498),
          t0.add(const Duration(milliseconds: 100))),
      isFalse,
    );
  });

  test('sends when distance change meets the threshold', () {
    final th = SendThrottle(minDistanceDeltaMeters: 5);
    th.markSent(s(DeviceDirection.up, 500), t0);
    expect(
      th.shouldSend(s(DeviceDirection.up, 495),
          t0.add(const Duration(milliseconds: 100))),
      isTrue,
    );
  });

  test('sends immediately on direction change', () {
    final th = SendThrottle();
    th.markSent(s(DeviceDirection.up, 500), t0);
    expect(
      th.shouldSend(s(DeviceDirection.left, 500),
          t0.add(const Duration(milliseconds: 10))),
      isTrue,
    );
  });

  test('heartbeat: sends after the min interval even with no change', () {
    final th = SendThrottle(minInterval: Duration(seconds: 1));
    final state = s(DeviceDirection.up, 500);
    th.markSent(state, t0);
    expect(
      th.shouldSend(state, t0.add(const Duration(seconds: 1, milliseconds: 1))),
      isTrue,
    );
  });

  test('reset clears history so next send always fires', () {
    final th = SendThrottle();
    th.markSent(s(DeviceDirection.up, 500), t0);
    th.reset();
    expect(th.shouldSend(s(DeviceDirection.up, 500), t0), isTrue);
  });
}
