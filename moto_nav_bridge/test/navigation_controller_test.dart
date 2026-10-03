import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_ports.dart';

void main() {
  late FakeBle ble;
  late FakeRoutes routes;
  late FakePositions positions;
  late FakeSideRoads sideRoads;
  late NavigationController controller;

  setUp(() {
    ble = FakeBle();
    routes = FakeRoutes(mainRoute);
    positions = FakePositions(current: p0);
    sideRoads = FakeSideRoads();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
      sideRoads: sideRoads,
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

  test('opposite-course candidates fail safely instead of replacing the route',
      () async {
    await controller.startNavigation(p2);
    final now = DateTime.now();
    for (var i = 0; i < 2; i++) {
      positions.emit(NavigationFix(0.0002, 0,
          heading: 180,
          accuracy: 5,
          speed: 2,
          timestamp: now.add(Duration(milliseconds: i))));
      await pumpEventQueue();
    }
    expect(routes.fetchCount, 2);
    expect(controller.current?.rerouting, isFalse);
    expect(ble.sent.last.rerouting, isFalse);
    expect(ble.sent.last, NavState.stopped);
    expect(controller.error, contains('travel direction'));
  });

  test('route planning does not wait for nearby-road lookup', () async {
    await controller.startNavigation(p2);

    expect(controller.phase, NavPhase.navigating);
    expect(sideRoads.fetchCount, 0);

    positions.emit(p0);
    await pumpEventQueue();
    expect(sideRoads.fetchCount, 1);
  });

  test('explicit reroute override uses separate provider', () async {
    final replacement = FakeRoutes(rerouteRoute);
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: replacement,
        location: positions,
        sideRoads: sideRoads);
    await controller.previewDestination(p2);
    expect(routes.fetchCount, 1);
    expect(replacement.fetchCount, 0);
    await controller.startNavigation(p2);
    final first = NavigationFix(offRoute.latitude, offRoute.longitude,
        heading: 0, accuracy: 5, speed: 3, timestamp: DateTime.now());
    positions.emit(first);
    await pumpEventQueue();
    expect(replacement.fetchCount, 0);
    final confirmed = NavigationFix(
        offRoute.latitude + 0.00001, offRoute.longitude,
        heading: 0, accuracy: 5, speed: 3, timestamp: DateTime.now());
    positions.emit(confirmed);
    await pumpEventQueue();
    expect(routes.fetchCount, 2); // preview + initial only
    expect(replacement.fetchCount, 1);
    expect(replacement.lastOrigin, same(confirmed)); // retain course metadata
    expect(
        controller.selectedRoute!.steps.last.direction, DeviceDirection.right);
    expect(ble.sent.last.direction, DeviceDirection.right);
  });

  test(
      'missing Valhalla configuration fails explicitly, without Apple fallback',
      () async {
    controller.dispose();
    controller = NavigationController(
        ble: ble, location: positions, sideRoads: sideRoads);
    await controller.previewDestination(p2);
    expect(controller.error, contains('VALHALLA_ROUTE_URL'));
    await controller.startNavigation(p2);
    expect(controller.phase, NavPhase.error);
    expect(routes.fetchCount, 0);
    expect(controller.error, contains('VALHALLA_ROUTE_URL'));
  });

  test('one provider handles preview, start and reroute and is disposed once',
      () async {
    await controller.previewDestination(p2);
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(routes.fetchCount, 3);
    controller.dispose();
    expect(routes.disposeCount, 1);
    controller = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads());
  });

  test(
      'only one reroute is in flight; returned route reconciles latest location',
      () async {
    final deferred = DeferredRoutes();
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: deferred,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(deferred.fetchCount, 1);
    final latest = NavigationFix(offRoute.latitude + 0.0005, offRoute.longitude,
        heading: 0, accuracy: 5, speed: 3, timestamp: DateTime.now());
    positions.emit(latest);
    await pumpEventQueue();
    expect(deferred.fetchCount, 1);
    deferred.requests.single
        .complete([const RouteCandidate(steps: rerouteRoute)]);
    await pumpEventQueue();
    expect(controller.origin, same(latest));
    expect(ble.sent.last.direction, DeviceDirection.right);
    expect(ble.sent.last.distanceMeters, lessThan(70));
    expect(controller.current?.rerouting, isFalse);
  });

  for (final action in ['pause', 'stop', 'gps error', 'select route']) {
    test('late reroute success/failure cannot undo $action', () async {
      final deferred = DeferredRoutes();
      routes = FakeRoutes(mainRoute, alternates: [
        const RouteCandidate(steps: mainRoute),
        const RouteCandidate(steps: alternateRoute),
      ]);
      controller.dispose();
      controller = NavigationController(
          ble: ble,
          directions: routes,
          rerouteDirections: deferred,
          location: positions,
          sideRoads: sideRoads);
      await controller.startNavigation(p2);
      positions.emit(offRoute);
      positions.emit(offRoute);
      await pumpEventQueue();
      switch (action) {
        case 'pause':
          await controller.pause();
        case 'stop':
          await controller.stopNavigation();
        case 'gps error':
          positions.fail();
          await pumpEventQueue();
        case 'select route':
          await controller.selectRoute(1);
      }
      final phase = controller.phase;
      final current = controller.current;
      final error = controller.error;
      final sends = ble.sent.length;
      if (action == 'gps error' || action == 'stop') {
        deferred.requests.single.completeError(Exception('late failure'));
      } else {
        deferred.requests.single
            .complete([const RouteCandidate(steps: rerouteRoute)]);
      }
      await pumpEventQueue();
      expect(controller.phase, phase);
      expect(controller.current, same(current));
      expect(controller.error, error);
      expect(ble.sent.length, sends);
    });
  }

  test('old trip response cannot clear new trip reroute single-flight guard',
      () async {
    final deferred = DeferredRoutes();
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: deferred,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(deferred.fetchCount, 2);
    deferred.requests.first.completeError(Exception('old trip error'));
    await pumpEventQueue();
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(deferred.fetchCount, 2);
    expect(controller.current?.rerouting, isTrue);
    expect(controller.error, isNot(contains('old trip')));
    deferred.requests.last
        .complete([const RouteCandidate(steps: rerouteRoute)]);
    await pumpEventQueue();
    expect(controller.current?.direction, DeviceDirection.right);
  });

  test('route already far behind at response time is not installed', () async {
    final deferred = DeferredRoutes();
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: deferred,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    positions.emit(const LatLng(0.02, 0.02));
    await pumpEventQueue();
    deferred.requests.single
        .complete([const RouteCandidate(steps: rerouteRoute)]);
    await pumpEventQueue();
    expect(ble.sent.last, NavState.stopped);
    expect(controller.selectedRoute!.steps, mainRoute);
    expect(controller.error, contains('current position'));
  });

  test('disposal suppresses late responses and disposes both providers',
      () async {
    final deferred = DeferredRoutes();
    controller.dispose();
    final subject = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: deferred,
        location: positions,
        sideRoads: sideRoads);
    // Give tearDown a separate, live controller; subject is disposed below.
    controller = NavigationController(
        ble: FakeBle(),
        directions: FakeRoutes(mainRoute),
        rerouteDirections: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads());
    await subject.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    subject.dispose();
    final sends = ble.sent.length;
    deferred.requests.single
        .complete([const RouteCandidate(steps: rerouteRoute)]);
    await pumpEventQueue();
    expect(routes.disposed, isTrue);
    expect(deferred.disposed, isTrue);
    expect(ble.sent.length, sends);
  });

  test(
      'off-route confirmation keeps normal turn updates to avoid frozen screen',
      () async {
    await controller.startNavigation(p2);

    positions.emit(offRoute);
    await pumpEventQueue();

    expect(controller.phase, NavPhase.navigating);
    expect(controller.error, anyOf(contains('偏离路线'), contains('Off route')));
    expect(ble.sent, hasLength(1));
    expect(ble.sent.map((state) => state.direction), [
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
      rerouteDirections: routes,
      location: positions,
      sideRoads: sideRoads,
    );

    await controller.startNavigation(p2);

    positions.emit(offRoute);
    await pumpEventQueue();
    final sendsBeforeConfirmedReroute = ble.sent.length;

    positions.emit(offRoute);
    await pumpEventQueue(times: 10);

    expect(controller.phase, NavPhase.navigating);
    expect(ble.sent.length, sendsBeforeConfirmedReroute + 2);
    expect(ble.sent.last, NavState.stopped);
    expect(controller.error, contains('simulated reroute failure'));

    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(routes.fetchCount, 2);
    expect(ble.sent.last, NavState.stopped);
    expect(controller.error, contains('simulated reroute failure'));
  });

  test('confirmed off-route fetches a new route from the current position',
      () async {
    routes = FakeRoutes(mainRoute, reroute: rerouteRoute);
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      rerouteDirections: routes,
      location: positions,
      sideRoads: sideRoads,
    );

    await controller.startNavigation(p2);

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
      rerouteDirections: routes,
      location: positions,
      sideRoads: sideRoads,
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
  int disposeCount = 0;

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
    disposeCount++;
    disposed = true;
  }
}

class FakeSideRoads implements SideRoadProvider {
  int fetchCount = 0;
  bool disposed = false;

  @override
  Future<List<RoadSegment>> fetchSideRoadsNear(LatLng position) async {
    fetchCount++;
    return const [];
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class DeferredRoutes extends FakeRoutes {
  DeferredRoutes() : super(mainRoute);
  final requests = <Completer<List<RouteCandidate>>>[];
  @override
  Future<List<RouteCandidate>> fetchRoutes(
      {required LatLng origin, required LatLng destination}) {
    fetchCount++;
    lastOrigin = origin;
    final request = Completer<List<RouteCandidate>>();
    requests.add(request);
    return request.future;
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

  void fail() => _controller.addError(Exception('GPS lost'));

  Future<void> close() => _controller.close();
}
