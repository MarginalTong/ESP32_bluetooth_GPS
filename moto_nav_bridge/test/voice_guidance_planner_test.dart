import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/guidance/guidance_route.dart';
import 'package:moto_nav_bridge/services/guidance/voice_guidance_planner.dart';

// Local metres -> coordinates near (0, 0).
LatLng p(double x, double y) => LatLng(y / 111320.0, x / 111320.0);

/// A polyline through [corners] with a point every [spacing] metres.
List<LatLng> path(List<(double, double)> corners, {double spacing = 5}) {
  final out = <LatLng>[p(corners.first.$1, corners.first.$2)];
  for (var i = 1; i < corners.length; i++) {
    final (x0, y0) = corners[i - 1];
    final (x1, y1) = corners[i];
    final length = ((x1 - x0).abs() + (y1 - y0).abs());
    final n = (length / spacing).ceil();
    for (var k = 1; k <= n; k++) {
      out.add(p(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n));
    }
  }
  return out;
}

RouteStep step(
  DeviceDirection direction,
  List<(double, double)> corners, {
  String? raw,
  int? exit,
  String? name,
  double spacing = 5,
}) {
  final points = path(corners, spacing: spacing);
  var length = 0.0;
  for (var i = 1; i < points.length; i++) {
    length += points[i - 1].distanceTo(points[i]);
  }
  return RouteStep(
    direction: direction,
    start: points.first,
    end: points.last,
    distanceMeters: length.round(),
    geometry: points,
    rawManeuver: raw,
    roundaboutExitCount: exit,
    streetName: name,
  );
}

/// North 1000 m, then the given maneuver onto an 800 m westward road.
List<RouteStep> oneTurn(
  DeviceDirection direction, {
  String? raw = 'valhalla:15',
  String? name,
  int? exit,
}) => [
  step(DeviceDirection.up, [(0, 0), (0, 1000)], raw: 'valhalla:1'),
  step(direction, [(0, 1000), (-800, 1000)], raw: raw, name: name, exit: exit),
];

class Rider {
  Rider({bool curves = false, this.english = false})
    : planner = VoiceGuidancePlanner(
        policy: VoiceGuidancePolicy(curveWarnings: curves),
      );

  final VoiceGuidancePlanner planner;
  final bool english;
  DateTime now = DateTime(2026, 1, 1);
  final spoken = <String>[];

  String? feed(
    List<RouteStep> steps,
    int stepIndex,
    DeviceDirection direction,
    int distance, {
    Object? route,
    double speed = 10,
    double accuracy = 0,
    bool rerouting = false,
    bool failed = false,
    bool speaking = false,
    bool reliable = true,
    Duration dt = const Duration(seconds: 1),
  }) {
    now = now.add(dt);
    final utterance = planner.next(
      GuidanceInput(
        route: route ?? steps,
        steps: steps,
        stepIndex: stepIndex,
        state: NavState(
          direction: direction,
          distanceMeters: distance,
          rerouting: rerouting,
        ),
        now: now,
        reliable: reliable,
        speedMps: speed,
        accuracyMeters: accuracy,
        rerouteFailed: failed,
        speaking: speaking,
      ),
      english: english,
    );
    if (utterance != null) spoken.add(utterance.text);
    return utterance?.text;
  }

  /// One update per second at [speed], from [from] down to [to] metres.
  void approach(
    List<RouteStep> steps,
    int stepIndex,
    DeviceDirection direction,
    int from,
    int to, {
    double speed = 10,
  }) {
    for (var d = from.toDouble(); d >= to; d -= speed) {
      feed(steps, stepIndex, direction, d.round(), speed: speed);
    }
  }
}

void main() {
  group('basic maneuvers', () {
    test(
      'left turn: far, prepare and a short final reminder, then arrival',
      () {
        final steps = oneTurn(DeviceDirection.left, name: '人民路');
        final rider = Rider();
        rider.approach(steps, 0, DeviceDirection.left, 600, 0);
        expect(rider.spoken, ['前方300米左转，进入人民路。', '前方100米左转。', '左转。']);
        rider.spoken.clear();
        rider.approach(steps, 1, DeviceDirection.up, 800, 20);
        rider.feed(steps, 1, DeviceDirection.arrived, 5);
        expect(rider.spoken, ['前方300米到达目的地。', '前方100米到达目的地。', '已到达目的地。']);
      },
    );

    test('right turn and U-turn use their own words', () {
      final right = Rider();
      right.approach(
        oneTurn(DeviceDirection.right, raw: 'valhalla:10'),
        0,
        DeviceDirection.right,
        400,
        290,
      );
      expect(right.spoken, ['前方300米右转。']);
      final uturn = Rider();
      uturn.approach(
        oneTurn(DeviceDirection.uturn, raw: 'valhalla:12'),
        0,
        DeviceDirection.uturn,
        400,
        290,
      );
      expect(uturn.spoken, ['前方300米在允许且安全的位置掉头。']);
    });

    test('a plain "continue" maneuver is not announced', () {
      final rider = Rider();
      rider.approach(
        oneTurn(DeviceDirection.up, raw: 'valhalla:8'),
        0,
        DeviceDirection.up,
        600,
        0,
      );
      expect(rider.spoken, isEmpty);
    });
  });

  group('complex junctions', () {
    test('two close turns are announced together, the second only briefly', () {
      final steps = [
        step(DeviceDirection.up, [(0, 0), (0, 1000)], raw: 'valhalla:1'),
        step(DeviceDirection.left, [
          (0, 1000),
          (-40, 1000),
        ], raw: 'valhalla:15'),
        step(DeviceDirection.right, [
          (-40, 1000),
          (-40, 1800),
        ], raw: 'valhalla:10'),
      ];
      final rider = Rider();
      rider.approach(steps, 0, DeviceDirection.left, 600, 0);
      expect(rider.spoken, [
        '前方350米左转，随后立即右转。',
        '前方150米左转，随后立即右转。',
        '左转，随后立即右转。',
      ]);
      rider.spoken.clear();
      rider.approach(steps, 1, DeviceDirection.right, 40, 0);
      expect(rider.spoken, ['右转。']);
    });

    test(
      'roundabout exit number, ramps, exits and forks come from Valhalla',
      () {
        String first(List<RouteStep> steps, DeviceDirection direction) {
          final rider = Rider();
          rider.approach(steps, 0, direction, 600, 0);
          return rider.spoken.first;
        }

        expect(
          first(
            oneTurn(DeviceDirection.left, raw: 'valhalla:26', exit: 2),
            DeviceDirection.left,
          ),
          '前方350米进入环岛，从第2个出口驶出。',
        );
        expect(
          first(
            oneTurn(DeviceDirection.left, raw: 'valhalla:26'),
            DeviceDirection.left,
          ),
          '前方350米进入环岛。',
        );
        expect(
          first(
            oneTurn(DeviceDirection.bearRight, raw: 'valhalla:18'),
            DeviceDirection.bearRight,
          ),
          '前方350米靠右进入匝道。',
        );
        expect(
          first(
            oneTurn(DeviceDirection.bearLeft, raw: 'valhalla:21'),
            DeviceDirection.bearLeft,
          ),
          '前方350米靠左从出口驶出。',
        );
        // A straight-on fork is still a decision point worth announcing.
        expect(
          first(
            oneTurn(DeviceDirection.up, raw: 'valhalla:22'),
            DeviceDirection.up,
          ),
          '前方350米在岔路保持直行。',
        );
      },
    );
  });

  group('timing', () {
    test(
      'high speed announces earlier, low speed skips the far announcement',
      () {
        final fast = Rider();
        fast.approach(
          oneTurn(DeviceDirection.left),
          0,
          DeviceDirection.left,
          1500,
          0,
          speed: 30,
        );
        expect(fast.spoken.first, '前方900米左转。');
        final slow = Rider();
        slow.approach(
          oneTurn(DeviceDirection.left),
          0,
          DeviceDirection.left,
          600,
          0,
          speed: 3,
        );
        expect(slow.spoken, ['前方80米左转。', '左转。']);
      },
    );

    test('GPS jitter around a threshold never repeats an announcement', () {
      final steps = oneTurn(DeviceDirection.left);
      final rider = Rider();
      for (final d in [310, 299, 305, 298, 302, 296, 301]) {
        rider.feed(steps, 0, DeviceDirection.left, d);
      }
      expect(rider.spoken, ['前方300米左转。']);
      for (final d in [130, 118, 125, 119, 60, 46, 44, 47, 43, 46, 44]) {
        rider.feed(steps, 0, DeviceDirection.left, d);
      }
      expect(rider.spoken, ['前方300米左转。', '前方100米左转。', '左转。']);
      // The step index briefly falls back across the junction.
      for (var i = 0; i < 3; i++) {
        rider.feed(steps, 1, DeviceDirection.up, 795);
        rider.feed(steps, 0, DeviceDirection.left, 5);
      }
      expect(rider.spoken, hasLength(3));
    });

    test('a poor fix moves the triggers earlier', () {
      final rider = Rider();
      rider.feed(
        oneTurn(DeviceDirection.left),
        0,
        DeviceDirection.left,
        310,
        accuracy: 30,
      );
      expect(rider.spoken, ['前方300米左转。']);
    });

    test('an unreliable fix announces no turn', () {
      final rider = Rider();
      for (var d = 600; d >= 0; d -= 10) {
        rider.feed(
          oneTurn(DeviceDirection.left),
          0,
          DeviceDirection.left,
          d,
          reliable: false,
        );
      }
      expect(rider.spoken, isEmpty);
    });
  });

  group('rerouting and data gaps', () {
    test(
      'off route is announced once; a failed retry once; the new route resumes',
      () {
        final old = oneTurn(DeviceDirection.left);
        final rider = Rider();
        for (var i = 0; i < 5; i++) {
          rider.feed(old, 0, DeviceDirection.stop, 0, rerouting: true);
        }
        for (var i = 0; i < 5; i++) {
          rider.feed(
            old,
            0,
            DeviceDirection.stop,
            0,
            rerouting: true,
            failed: true,
          );
        }
        expect(rider.spoken, ['已偏离路线，正在重新规划。', '暂时无法重新规划路线，正在重试。']);
        final fresh = oneTurn(DeviceDirection.right, raw: 'valhalla:10');
        rider.feed(fresh, 0, DeviceDirection.right, 200);
        expect(rider.spoken.last, '前方200米右转。');
        // A second episode soon after stays quiet.
        rider.feed(fresh, 0, DeviceDirection.stop, 0, rerouting: true);
        expect(rider.spoken, hasLength(3));
      },
    );

    test('missing maneuver data falls back to the display direction', () {
      final rider = Rider();
      rider.approach(
        oneTurn(DeviceDirection.left, raw: null),
        0,
        DeviceDirection.left,
        400,
        290,
      );
      expect(rider.spoken, ['前方300米左转。']);
      final apple = Rider();
      apple.approach(
        oneTurn(DeviceDirection.left, raw: 'turn-left', name: 'X'),
        0,
        DeviceDirection.left,
        400,
        290,
      );
      expect(apple.spoken, ['前方300米左转。']);
    });

    test('route data that disagrees with the display is not used', () {
      final rider = Rider();
      rider.approach(
        oneTurn(DeviceDirection.left, name: '人民路'),
        0,
        DeviceDirection.uturn,
        400,
        290,
      );
      expect(rider.spoken, ['前方300米在允许且安全的位置掉头。']);
    });
  });

  test('a playing announcement defers the next, except a final reminder', () {
    final steps = oneTurn(DeviceDirection.left);
    final rider = Rider();
    rider.feed(steps, 0, DeviceDirection.left, 300);
    expect(
      rider.feed(steps, 0, DeviceDirection.left, 120, speaking: true),
      isNull,
    );
    // Re-evaluated once the speech ends, with the fresh distance.
    expect(
      rider.feed(
        steps,
        0,
        DeviceDirection.left,
        110,
        dt: const Duration(seconds: 3),
      ),
      '前方100米左转。',
    );
    rider.feed(
      steps,
      0,
      DeviceDirection.left,
      60,
      dt: const Duration(seconds: 6),
    );
    expect(
      rider.feed(steps, 0, DeviceDirection.left, 40, speaking: true),
      '左转。',
    );
  });

  test('English uses the same rules', () {
    final rider = Rider(english: true);
    final steps = oneTurn(DeviceDirection.left, name: 'King Street');
    rider.approach(steps, 0, DeviceDirection.left, 600, 0);
    rider.feed(steps, 1, DeviceDirection.arrived, 5);
    expect(rider.spoken, [
      'In 300 metres, turn left onto King Street.',
      'In 100 metres, turn left.',
      'Turn left.',
      'You have arrived.',
    ]);
    final roundabout = Rider(english: true);
    roundabout.approach(
      oneTurn(DeviceDirection.left, raw: 'valhalla:26', exit: 3),
      0,
      DeviceDirection.left,
      600,
      300,
    );
    expect(
      roundabout.spoken.first,
      'In 350 metres, at the roundabout, take the 3rd exit.',
    );
  });

  group('sharp bends', () {
    final sBends = [
      step(DeviceDirection.up, [
        (0, 0),
        (0, 500),
        (60, 500),
        (60, 1100),
      ], raw: 'valhalla:1'),
    ];

    test('two close bends away from maneuvers form one cluster', () {
      expect(GuidanceRoute.fromSteps(sBends).curves, hasLength(1));
      final single = [
        step(DeviceDirection.up, [
          (0, 0),
          (0, 500),
          (500, 500),
        ], raw: 'valhalla:1'),
      ];
      expect(GuidanceRoute.fromSteps(single).curves, isEmpty);
      final straight = [
        step(DeviceDirection.up, [(0, 0), (0, 1100)], raw: 'valhalla:1'),
      ];
      expect(GuidanceRoute.fromSteps(straight).curves, isEmpty);
    });

    test('a coarse polyline is not trusted for bends', () {
      final coarse = [
        step(
          DeviceDirection.up,
          [(0, 0), (0, 500), (60, 500), (60, 1100)],
          raw: 'valhalla:1',
          spacing: 600,
        ),
      ];
      expect(GuidanceRoute.fromSteps(coarse).curves, isEmpty);
    });

    test('the warning is spoken once, shortly before the bends', () {
      final rider = Rider(curves: true);
      final total = GuidanceRoute.fromSteps(sBends).stepEndAlong.last;
      final start = GuidanceRoute.fromSteps(sBends).curves.single.startAlong;
      String? heardAt;
      for (var d = total; d >= total - 700; d -= 10) {
        final text = rider.feed(sBends, 0, DeviceDirection.up, d.round());
        if (text != null && heardAt == null) heardAt = '${start - (total - d)}';
      }
      expect(rider.spoken.where((t) => t.contains('连续急弯')), hasLength(1));
      expect(double.parse(heardAt!), inInclusiveRange(0, 100));
    });

    test('bends are off by policy', () {
      final rider = Rider();
      final total = GuidanceRoute.fromSteps(sBends).stepEndAlong.last;
      for (var d = total; d >= total - 700; d -= 10) {
        rider.feed(sBends, 0, DeviceDirection.up, d.round());
      }
      expect(rider.spoken.where((t) => t.contains('连续急弯')), isEmpty);
    });
  });
}
