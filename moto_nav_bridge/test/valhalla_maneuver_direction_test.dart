import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/valhalla/valhalla_maneuver_direction.dart';

// Local metres -> coordinates near (0, 0); x east, y north.
LatLng p(double x, double y) => LatLng(y / 111320.0, x / 111320.0);

void main() {
  // North 100 m, then a 100 m leg turning by [degrees] (positive = right).
  List<LatLng> turnBy(double degrees) {
    final rad = degrees * math.pi / 180;
    return [
      p(0, 0),
      p(0, 50),
      p(0, 100),
      p(100 * math.sin(rad), 100 + 100 * math.cos(rad)),
    ];
  }

  test('fixed Valhalla types map to their arrows', () {
    final shape = turnBy(0);
    DeviceDirection of(int type) =>
        ValhallaManeuverDirection.of(type, shape, 1, 2);
    expect(of(10), DeviceDirection.right);
    expect(of(15), DeviceDirection.left);
    expect(of(9), DeviceDirection.bearRight);
    expect(of(24), DeviceDirection.bearLeft);
    expect(of(12), DeviceDirection.uturn);
    expect(of(17), DeviceDirection.up);
  });

  test(
    'transit, stairs and unknown types are rejected, not shown straight',
    () {
      final shape = turnBy(0);
      for (final type in [30, 34, 99]) {
        expect(
          () => ValhallaManeuverDirection.of(type, shape, 1, 2),
          throwsFormatException,
        );
      }
    },
  );

  test('a roundabout entry uses the net turn from approach to exit', () {
    expect(
      ValhallaManeuverDirection.of(26, turnBy(90), 2, 2),
      DeviceDirection.right,
    );
    expect(
      ValhallaManeuverDirection.of(26, turnBy(-40), 2, 2),
      DeviceDirection.bearLeft,
    );
    expect(
      ValhallaManeuverDirection.of(26, turnBy(5), 2, 2),
      DeviceDirection.up,
    );
  });

  test('a roundabout at the very start has no approach and shows straight', () {
    expect(
      ValhallaManeuverDirection.of(26, turnBy(90), 0, 0),
      DeviceDirection.up,
    );
  });

  test('a new leg keeps the turn the rider makes at the stop', () {
    final previous = RouteStep(
      direction: DeviceDirection.up,
      start: p(0, 0),
      end: p(0, 100),
      distanceMeters: 100,
      geometry: [p(0, 0), p(0, 50), p(0, 100)],
    );
    int join(double degrees) => ValhallaManeuverDirection.joinType(
      previous,
      turnBy(degrees).sublist(2),
    );
    expect(join(0), 1);
    expect(join(30), 9);
    expect(join(90), 10);
    expect(join(-30), 16);
    expect(join(-90), 15);
    expect(join(175), 12);
  });
}
