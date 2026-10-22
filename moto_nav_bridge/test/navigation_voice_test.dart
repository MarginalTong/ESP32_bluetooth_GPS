import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/services/navigation_voice.dart';

void main() {
  test('announces thresholds once despite distance jitter', () {
    final voice = NavigationVoice();
    final route = Object();
    String? next(int d) => voice.next(
        NavState(direction: DeviceDirection.right, distanceMeters: d), route, 0,
        english: true);
    expect(next(600), contains('600 metres'));
    expect(next(590), isNull);
    expect(next(499), contains('499 metres'));
    expect(next(510), isNull);
    expect(next(490), isNull);
    expect(next(190), isNotNull);
    expect(next(45), isNotNull);
    expect(next(40), isNull);
  });
  test('new maneuver or route rearms even with identical direction', () {
    final voice = NavigationVoice();
    final route = Object();
    const state =
        NavState(direction: DeviceDirection.left, distanceMeters: 100);
    expect(voice.next(state, route, 0, english: false), contains('左转'));
    expect(voice.next(state, route, 0, english: false), isNull);
    expect(voice.next(state, route, 1, english: false), isNotNull);
    expect(voice.next(state, Object(), 1, english: false), isNotNull);
  });
  test('no turn instruction for stopped or rerouting; arrival once', () {
    final voice = NavigationVoice();
    final route = Object();
    expect(voice.next(NavState.stopped, route, 0, english: true), isNull);
    expect(voice.next(NavState.recalculating, route, 0, english: true), isNull);
    const arrived =
        NavState(direction: DeviceDirection.arrived, distanceMeters: 0);
    expect(voice.next(arrived, route, 0, english: true), 'You have arrived.');
    expect(voice.next(arrived, route, 0, english: true), isNull);
  });

}
