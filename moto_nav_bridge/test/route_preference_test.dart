import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/route_preference.dart';

void main() {
  RouteCandidate route(int turns) => RouteCandidate(steps: [
        for (var i = 0; i <= turns; i++)
          RouteStep(
              direction: i == 0 ? DeviceDirection.up : DeviceDirection.uturn,
              start: const LatLng(0, 0),
              end: const LatLng(0.001, 0),
              distanceMeters: 111),
      ]);
  test('prefers alternate route with no U-turn', () {
    expect(preferredRouteIndex([route(1), route(0)]), 1);
  });
  test('all require U-turns: choose fewer without hiding maneuvers', () {
    expect(preferredRouteIndex([route(2), route(1)]), 1);
  });
  test('equal counts keep provider order', () {
    expect(preferredRouteIndex([route(0), route(0)]), 0);
  });
  test('heading eligibility takes precedence over fewer turns', () {
    final reverse = route(0);
    expect(
        preferredRouteIndex([reverse, route(1)],
            eligible: (r) => !identical(r, reverse)),
        1);
    expect(preferredRouteIndex([reverse], eligible: (_) => false), -1);
  });
}
