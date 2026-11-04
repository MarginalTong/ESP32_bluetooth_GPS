import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lane_guidance.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_phrases.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_route.dart';

GuidanceManeuver maneuver(
  ManeuverKind kind,
  DeviceDirection direction, {
  int? exit,
  String? street,
  LaneGuidance? lanes,
  RoadSide? side,
}) => GuidanceManeuver(
  index: 1,
  kind: kind,
  direction: direction,
  alongMeters: 0,
  exitCount: exit,
  streetName: street,
  lanes: lanes,
  arrivalSide: side,
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

  group('lanes', () {
    String say(GuidancePhrases phrases, List<bool> flags) => phrases.lanes(
      maneuver(
        ManeuverKind.turn,
        DeviceDirection.right,
        lanes: LaneGuidance.fromFlags(flags),
      ),
      DeviceDirection.right,
    );

    test('runs at an edge are named by that edge', () {
      expect(say(zh, [false, false, true]), '走最右侧车道');
      expect(say(zh, [false, true, true]), '走右侧两条车道');
      expect(say(zh, [true, true, false, false]), '走左侧两条车道');
      expect(say(en, [false, true, true]), ', using the right two lanes');
      expect(say(en, [true, false]), ', using the left lane');
    });

    test('inner runs count from the nearer edge', () {
      expect(say(zh, [false, false, true, false]), '走右数第二条车道');
      expect(say(zh, [false, true, false, false, false]), '走左数第二条车道');
      expect(say(zh, [false, false, true, true, false]), '走右数第二到第三条车道');
      expect(
        say(en, [false, false, true, false]),
        ', using the second lane from the right',
      );
      expect(
        say(en, [false, true, true, false, false]),
        ', using lanes 2 to 3 from the left',
      );
    });

    test('a centred run is the middle', () {
      expect(say(zh, [false, true, false]), '走中间车道');
      expect(
        say(en, [false, true, true, false]),
        ', using the middle two lanes',
      );
    });

    test('no lane data, or lanes for another maneuver, say nothing', () {
      expect(say(zh, [true, true]), '');
      final lanes = maneuver(
        ManeuverKind.turn,
        DeviceDirection.right,
        lanes: LaneGuidance.fromFlags([false, true]),
      );
      expect(zh.lanes(lanes, DeviceDirection.left), '');
      expect(zh.lanes(null, DeviceDirection.left), '');
    });

    test('each language keeps its word order', () {
      expect(zh.clause('右转', '，进入人民路', '走右侧车道'), '走右侧车道右转，进入人民路');
      expect(
        en.clause('turn right', ' onto King Street', ', using the right lane'),
        'turn right onto King Street, using the right lane',
      );
    });
  });

  test('the destination side is named when the route gave it', () {
    final left = maneuver(
      ManeuverKind.destination,
      DeviceDirection.arrived,
      side: RoadSide.left,
    );
    final unknown = maneuver(ManeuverKind.destination, DeviceDirection.arrived);
    expect(zh.action(DeviceDirection.arrived, left), '到达目的地，目的地在您左手边');
    expect(zh.action(DeviceDirection.arrived, unknown), '到达目的地');
    expect(
      en.arrived(RoadSide.right),
      'You have arrived. Your destination is on the right.',
    );
    expect(zh.arrived(null), '已到达目的地。');
  });
}
