import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_ports.dart';

void main() {
  late FakeBle ble;
  late FakeRoutes routes;
  late FakePositions positions;
  late NavigationController controller;

  setUp(() {
    ble = FakeBle();
    routes = FakeRoutes(mainRoute);
    positions = FakePositions(current: p0);
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
    );
  });

  tearDown(() async {
    controller.dispose();
    await positions.close();
  });

  test('starts navigation and sends the first real maneuver to ESP32',
      () async {
    await controller.startNavigation(p2);

    positions.emit(p0);
    await pumpEventQueue();

    expect(controller.phase, NavPhase.navigating);
    expect(ble.sent, isNotEmpty);
    expect(ble.sent.last.direction, DeviceDirection.left);
    expect(ble.sent.last.distanceMeters, greaterThan(100));
  });

  test(
      'off-route confirmation keeps normal turn updates to avoid frozen screen',
      () async {
    await controller.startNavigation(p2);

    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();

    expect(controller.phase, NavPhase.navigating);
    expect(controller.error, contains('偏离路线'));
    expect(ble.sent, hasLength(2));
    expect(ble.sent.map((state) => state.direction), [
      DeviceDirection.left,
      DeviceDirection.left,
    ]);
  });

  test('reroute failure does not fall through and send the old route',
      () async {
    routes = FakeRoutes(mainRoute, throwAfterInitialRoute: true);
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
    );

    await controller.startNavigation(p2);

    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    final sendsBeforeConfirmedReroute = ble.sent.length;

    positions.emit(offRoute);
    await pumpEventQueue(times: 10);

    expect(controller.phase, NavPhase.navigating);
    expect(ble.sent.length, sendsBeforeConfirmedReroute);
  });

  test('confirmed off-route fetches a new route from the current position',
      () async {
    routes = FakeRoutes(mainRoute, reroute: rerouteRoute);
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
    );

    await controller.startNavigation(p2);

    positions.emit(offRoute);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue(times: 10);

    expect(routes.fetchCount, 2);
    expect(routes.lastOrigin, offRoute);
    expect(controller.phase, NavPhase.navigating);
    expect(ble.sent.last.direction, DeviceDirection.right);
  });

  test('selecting an alternate route switches engine and sends new instruction',
      () async {
    routes = FakeRoutes(mainRoute, alternates: [
      const RouteCandidate(steps: mainRoute, name: 'Route 1'),
      const RouteCandidate(steps: alternateRoute, name: 'Route 2'),
    ]);
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
    );

    await controller.startNavigation(p2);
    positions.emit(p0);
    await pumpEventQueue();

    await controller.selectRoute(1);

    expect(controller.selectedRouteIndex, 1);
    expect(ble.sent.last.direction, DeviceDirection.right);
  });

  test('only sends ARRIVED at the destination and then ignores GPS drift',
      () async {
    await controller.startNavigation(p2);

    positions.emit(p2);
    await pumpEventQueue();
    positions.emit(offRoute);
    await pumpEventQueue();

    expect(controller.phase, NavPhase.arrived);
    expect(ble.sent.map((state) => state.direction), [DeviceDirection.arrived]);
  });

  test('pause sends STOP and ignores further location updates', () async {
    await controller.startNavigation(p2);

    await controller.pause();
    positions.emit(p0);
    await pumpEventQueue();

    expect(controller.phase, NavPhase.paused);
    expect(ble.sent, [NavState.stopped]);
  });

  test('endNavigation clears route state, sends STOP, and disconnects BLE',
      () async {
    await controller.startNavigation(p2);

    await controller.endNavigation();

    expect(controller.phase, NavPhase.idle);
    expect(controller.destination, isNull);
    expect(controller.origin, isNull);
    expect(controller.current, isNull);
    expect(ble.sent, [NavState.stopped]);
    expect(ble.disconnectCount, 1);
  });
}

const p0 = LatLng(0.000, 0.0);
const p1 = LatLng(0.001, 0.0);
const p2 = LatLng(0.002, 0.0);
const offRoute = LatLng(0.0004, 0.0020);

const mainRoute = [
  RouteStep(
    direction: DeviceDirection.up,
    start: p0,
    end: p1,
    distanceMeters: 111,
    rawManeuver: null,
  ),
  RouteStep(
    direction: DeviceDirection.left,
    start: p1,
    end: p2,
    distanceMeters: 111,
    rawManeuver: 'turn-left',
  ),
];

const rerouteRoute = [
  RouteStep(
    direction: DeviceDirection.up,
    start: offRoute,
    end: rerouteTurn,
    distanceMeters: 111,
    rawManeuver: null,
  ),
  RouteStep(
    direction: DeviceDirection.right,
    start: rerouteTurn,
    end: p2,
    distanceMeters: 111,
    rawManeuver: 'turn-right',
  ),
];

const rerouteTurn = LatLng(0.0014, 0.0020);

const alternateRoute = [
  RouteStep(
    direction: DeviceDirection.up,
    start: p0,
    end: alternateTurn,
    distanceMeters: 111,
    rawManeuver: null,
  ),
  RouteStep(
    direction: DeviceDirection.right,
    start: alternateTurn,
    end: p2,
    distanceMeters: 111,
    rawManeuver: 'turn-right',
  ),
];

const alternateTurn = LatLng(0.001, -0.001);

class FakeBle implements NavigationBlePort {
  final sent = <NavState>[];
  int disconnectCount = 0;

  @override
  Future<bool> send(NavState state) async {
    sent.add(state);
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
  }
}

class FakeRoutes implements RouteProvider {
  FakeRoutes(
    this.routes, {
    this.reroute,
    this.alternates,
    this.throwAfterInitialRoute = false,
  });

  final List<RouteStep> routes;
  final List<RouteStep>? reroute;
  final List<RouteCandidate>? alternates;
  final bool throwAfterInitialRoute;
  int fetchCount = 0;
  LatLng? lastOrigin;
  bool disposed = false;

  @override
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final routes = await fetchRoutes(origin: origin, destination: destination);
    return routes.first.steps;
  }

  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async {
    fetchCount++;
    lastOrigin = origin;
    if (throwAfterInitialRoute && fetchCount > 1) {
      throw Exception('simulated reroute failure');
    }
    if (fetchCount > 1 && reroute != null) {
      return [RouteCandidate(steps: reroute!, name: 'Reroute')];
    }
    return alternates ?? [RouteCandidate(steps: routes, name: 'Main')];
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class FakePositions implements PositionProvider {
  FakePositions({required this.current});

  final LatLng current;
  final _controller = StreamController<LatLng>.broadcast();
  bool permissionGranted = true;

  @override
  Future<bool> ensurePermission() async => permissionGranted;

  @override
  Future<LatLng> currentPosition() async => current;

  @override
  Stream<LatLng> positionStream() => _controller.stream;

  void emit(LatLng position) => _controller.add(position);

  Future<void> close() => _controller.close();
}
