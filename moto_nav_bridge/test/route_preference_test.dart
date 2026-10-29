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
  test('selects the shortest ETA even when the provider lists it last', () {
    final slow = route(0)
        .copyWith(expectedTravelTimeSeconds: 1200, distanceMeters: 12000);
    final medium =
        route(0).copyWith(expectedTravelTimeSeconds: 900, distanceMeters: 9000);
    final fast =
        route(0).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 8000);
    final candidates = List<RouteCandidate>.unmodifiable([slow, medium, fast]);
    expect(preferredRouteIndex(candidates), 2);
    expect(candidates.first, same(slow));
  });
  test('fewer U-turns never justify a longer ETA', () {
    final detour = route(0).copyWith(expectedTravelTimeSeconds: 1200);
    final direct = route(1).copyWith(expectedTravelTimeSeconds: 600);
    expect(preferredRouteIndex([detour, direct]), 1);
    expect(preferredRouteIndex([detour, direct], avoidEarlyUTurns: true), 1);
  });
  test('shorter distance wins equal ETAs before the turn preference', () {
    final long =
        route(0).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 9000);
    final short =
        route(1).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 6000);
    expect(preferredRouteIndex([long, short]), 1);
  });
  test('fastest is not the same as shortest distance', () {
    final short =
        route(0).copyWith(expectedTravelTimeSeconds: 900, distanceMeters: 5000);
    final fast =
        route(0).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 7000);
    expect(preferredRouteIndex([short, fast]), 1);
  });
  test('uses fewer turns only when time and distance tie', () {
    final turn =
        route(1).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 6000);
    final noTurn =
        route(0).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 6000);
    expect(preferredRouteIndex([turn, noTurn]), 1);
    expect(preferredRouteIndex([noTurn, noTurn]), 0);
  });
  test('missing or negative metrics must not look like a zero-minute route',
      () {
    final known =
        route(1).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: 6000);
    expect(preferredRouteIndex([route(0), known]), 1);
    expect(
        preferredRouteIndex([
          route(0).copyWith(expectedTravelTimeSeconds: -1),
          known,
        ]),
        1);
    final badDistance =
        route(0).copyWith(expectedTravelTimeSeconds: 600, distanceMeters: -1);
    expect(preferredRouteIndex([badDistance, known]), 1);
  });
  test('eligibility and usability override a faster ETA', () {
    final bad = route(0).copyWith(expectedTravelTimeSeconds: 60);
    final usable = route(1).copyWith(expectedTravelTimeSeconds: 600);
    final empty = const RouteCandidate(steps: [], expectedTravelTimeSeconds: 1);
    expect(
        preferredRouteIndex([empty, bad, usable],
            eligible: (r) => !identical(r, bad)),
        2);
    expect(preferredRouteIndex([bad], eligible: (_) => false), -1);
    expect(preferredRouteIndex([]), -1);
  });
  test('rerouting prefers later turns but preserves all maneuvers', () {
    final early = route(1);
    final later = RouteCandidate(steps: [
      const RouteStep(
        direction: DeviceDirection.up,
        start: LatLng(0, 0),
        end: LatLng(0.006, 0),
        distanceMeters: 600,
      ),
      ...route(2).steps.skip(1),
    ]);
    expect(preferredRouteIndex([early, later]), 0);
    expect(preferredRouteIndex([early, later], avoidEarlyUTurns: true), 1);
    expect(preferredRouteIndex([early], avoidEarlyUTurns: true), 0);
    expect(
        preferredRouteIndex([early, later],
            avoidEarlyUTurns: true, eligible: (r) => identical(r, early)),
        0);
    expect(later.steps.last.direction, DeviceDirection.uturn);
    expect(preferredRouteIndex([later, route(0)], avoidEarlyUTurns: true), 1);
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
