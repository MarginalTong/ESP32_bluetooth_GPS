import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/voice_navigation_query.dart';

void main() {
  const state = NavState(direction: DeviceDirection.left, distanceMeters: 120);
  test('spoken repeat variants are local navigation commands', () {
    expect(isVoiceRepeatRequest('再讲一遍。'), isTrue);
    expect(isVoiceRepeatRequest('Say it again!'), isTrue);
    expect(isVoiceRepeatRequest('How long until arrival?'), isFalse);
  });
  test('answers from actual maneuver, never agrees with guessed right turn',
      () {
    expect(
        answerVoiceQuery('下一个路口右转吗？',
            english: false, state: state, reliable: true),
        '前方120米，左转。');
    expect(
        answerVoiceQuery('Repeat the instruction.',
            english: true, state: state, reliable: true),
        'In 120 metres, turn left.');
  });
  test('stale or recalculating routes cannot produce a turn answer', () {
    expect(
        answerVoiceQuery('再说一遍', english: false, state: state, reliable: false),
        contains('无法确认'));
    expect(
        answerVoiceQuery('再说一遍',
            english: false, state: NavState.recalculating, reliable: true),
        contains('无法确认'));
  });
  test('model intent maps to the current turn and explains inactive navigation',
      () {
    expect(
        answerVoiceQuery('repeat',
            english: false, state: state, reliable: true),
        '前方120米，左转。');
    expect(
        answerVoiceQuery('repeat',
            english: true,
            state: null,
            reliable: false,
            navigationActive: false),
        contains('Start navigation first'));
    expect(
        answerVoiceQuery('eta',
            english: false,
            state: null,
            reliable: false,
            navigationActive: false),
        contains('请先开始导航'));
  });
  test('remaining ETA uses progress along the selected route', () {
    const a = LatLng(0, 0), b = LatLng(0, .001), c = LatLng(0, .002);
    const route = RouteCandidate(expectedTravelTimeSeconds: 600, steps: [
      RouteStep(
          direction: DeviceDirection.up, start: a, end: b, distanceMeters: 111),
      RouteStep(
          direction: DeviceDirection.left,
          start: b,
          end: c,
          distanceMeters: 111),
    ]);
    final remaining =
        estimateRemainingRouteSeconds(route, const LatLng(0, .0015), 1);
    expect(remaining, closeTo(150, 2));
    expect(
        answerVoiceQuery('eta',
            english: true,
            state: state,
            reliable: false,
            remainingSeconds: remaining),
        contains('About 3 minutes'));
    expect(estimateRemainingRouteSeconds(route, const LatLng(.01, .0015), 1),
        isNull);
  });
  test('does not fabricate remaining ETA or execute mutation', () {
    expect(
        answerVoiceQuery('还有多久到', english: false, state: state, reliable: true),
        contains('暂时无法回答'));
    expect(
        answerVoiceQuery('不要走收费路',
            english: false, state: state, reliable: true),
        contains('路线没有改变'));
    expect(
        answerVoiceQuery('换成去机场', english: false, state: state, reliable: true),
        contains('路线没有改变'));
  });
}
