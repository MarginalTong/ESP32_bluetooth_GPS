import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';

import 'navigation_controller_test.dart'
    show
        FakeBle,
        FakePositions,
        FakeRoutes,
        FakeSideRoads,
        mainRoute,
        alternateRoute,
        p0,
        p2;

class _ChangingRoutes extends FakeRoutes {
  _ChangingRoutes(this.responses) : super(mainRoute);
  final List<List<RouteCandidate>> responses;
  int requests = 0;

  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async =>
      responses[
          requests < responses.length ? requests++ : responses.length - 1];
}

void main() {
  const slow = RouteCandidate(
      steps: mainRoute,
      name: 'Detour',
      expectedTravelTimeSeconds: 1200,
      distanceMeters: 12000);
  const fast = RouteCandidate(
      steps: alternateRoute,
      name: 'Fast',
      expectedTravelTimeSeconds: 600,
      distanceMeters: 8000);
  late FakeBle ble;
  late FakePositions positions;
  NavigationController? controller;

  NavigationController create(List<List<RouteCandidate>> responses) {
    return controller = NavigationController(
        ble: ble,
        directions: _ChangingRoutes(responses),
        location: positions,
        sideRoads: FakeSideRoads());
  }

  setUp(() {
    ble = FakeBle();
    positions = FakePositions(current: p0);
  });
  tearDown(() async {
    controller?.dispose();
    controller = null;
    await positions.close();
  });

  test('preview defaults to the faster alternate without sending BLE',
      () async {
    final nav = create([
      [slow, fast]
    ]);
    await nav.previewDestination(p2);
    expect(nav.selectedRouteIndex, 1);
    expect(nav.selectedRoute?.name, 'Fast');
    expect(ble.sent, isEmpty);
  });

  test('starting without a preview uses the fastest route in BLE guidance',
      () async {
    final nav = create([
      [slow, fast]
    ]);
    await nav.startNavigation(p2);
    expect(nav.selectedRoute?.name, 'Fast');
    positions.emit(p0);
    await pumpEventQueue();
    expect(ble.sent.last.direction, DeviceDirection.right);
  });

  test('Start re-evaluates the automatic preview choice using fresh ETAs',
      () async {
    final newFast = slow.copyWith(expectedTravelTimeSeconds: 300);
    final nav = create([
      [slow, fast],
      [newFast, fast]
    ]);
    await nav.previewDestination(p2);
    expect(nav.selectedRouteIndex, 1);
    await nav.startNavigation(p2);
    expect(nav.selectedRouteIndex, 0);
    expect(nav.selectedRoute?.expectedTravelTimeSeconds, 300);
    positions.emit(p0);
    await pumpEventQueue();
    expect(ble.sent.last.direction, DeviceDirection.left);
  });

  test('automatic preview index is not reused when provider order changes',
      () async {
    final nav = create([
      [slow, fast],
      [fast, slow]
    ]);
    await nav.previewDestination(p2);
    expect(nav.selectedRouteIndex, 1);
    await nav.startNavigation(p2);
    expect(nav.selectedRouteIndex, 0);
    expect(nav.selectedRoute?.name, 'Fast');
  });

  test('an explicit longer route choice is not silently replaced by fastest',
      () async {
    final nav = create([
      [slow, fast]
    ]);
    await nav.previewDestination(p2);
    await nav.selectRoute(0);
    expect(ble.sent, isEmpty);
    await nav.startNavigation(p2);
    expect(nav.selectedRoute?.name, 'Detour');
    positions.emit(p0);
    await pumpEventQueue();
    expect(ble.sent.last.direction, DeviceDirection.left);
  });

  test('tapping the already selected route also records explicit intent',
      () async {
    final newFast = slow.copyWith(expectedTravelTimeSeconds: 300);
    final nav = create([
      [slow, fast],
      [newFast, fast]
    ]);
    await nav.previewDestination(p2);
    await nav.selectRoute(1);
    await nav.startNavigation(p2);
    expect(nav.selectedRouteIndex, 1);
    expect(nav.selectedRoute?.name, 'Fast');
  });

  test('a new preview clears the previous manual route choice', () async {
    final nav = create([
      [slow, fast],
      [slow, fast],
      [slow, fast]
    ]);
    await nav.previewDestination(p2);
    await nav.selectRoute(0);
    await nav.previewDestination(p2);
    expect(nav.selectedRouteIndex, 1);
    await nav.startNavigation(p2);
    expect(nav.selectedRouteIndex, 1);
  });

  test('stopping clears explicit selection before the next trip', () async {
    final nav = create([
      [slow, fast]
    ]);
    await nav.previewDestination(p2);
    await nav.selectRoute(0);
    await nav.stopNavigation();
    await nav.startNavigation(p2);
    expect(nav.selectedRouteIndex, 1);
  });
}
