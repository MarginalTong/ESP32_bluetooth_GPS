import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_phrases.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_route.dart';

GuidanceManeuver maneuver(
  ManeuverKind kind,
  DeviceDirection direction, {
  int? exit,
  String? street,
}) => GuidanceManeuver(
  index: 1,
  kind: kind,
  direction: direction,
  alongMeters: 0,
  exitCount: exit,
  streetName: street,
);

void main() {
  const zh = GuidancePhrases(english: false);
  const en = GuidancePhrases(english: true);

  test('distances are rounded so the number does not jitter', () {
    expect(zh.distance(7), '前方10米');
    expect(zh.distance(143), '前方150米');
    expect(zh.distance(1000), '前方1公里');
    expect(en.distance(1260), 'In 1.3 kilometres, ');
  });

  test('maneuver detail is used only when it agrees with the display', () {
    final ramp = maneuver(ManeuverKind.ramp, DeviceDirection.bearRight);
    expect(zh.action(DeviceDirection.bearRight, ramp), '靠右进入匝道');
    expect(zh.action(DeviceDirection.left, ramp), '左转');
    expect(en.action(DeviceDirection.right, null), 'turn right');
  });

  test('a roundabout names its exit only when the route gave one', () {
    final named = maneuver(
      ManeuverKind.roundaboutEnter,
      DeviceDirection.right,
      exit: 2,
    );
    final unnamed = maneuver(
      ManeuverKind.roundaboutEnter,
      DeviceDirection.right,
    );
    expect(en.action(DeviceDirection.right, named), contains('2nd exit'));
    expect(zh.action(DeviceDirection.right, unnamed), '进入环岛');
  });

  test('a road name is added only for maneuvers that join a road', () {
    final turn = maneuver(
      ManeuverKind.turn,
      DeviceDirection.left,
      street: '人民路',
    );
    final roundabout = maneuver(
      ManeuverKind.roundaboutExit,
      DeviceDirection.left,
      street: '人民路',
    );
    expect(zh.onto(turn, DeviceDirection.left), '，进入人民路');
    expect(zh.onto(turn, DeviceDirection.right), '');
    expect(zh.onto(roundabout, DeviceDirection.left), '');
  });

  test('a close follow-up maneuver says "immediately"', () {
    final next = maneuver(ManeuverKind.turn, DeviceDirection.right);
    expect(zh.then(next, 40), '，随后立即右转');
    expect(en.then(next, 120), ', then turn right');
  });

  test('sentences end correctly in each language', () {
    expect(zh.sentence('前方100米左转'), '前方100米左转。');
    expect(
      en.sentence('in 100 metres, turn left'),
      'In 100 metres, turn left.',
    );
    expect(en.sentence(''), '');
  });
}
