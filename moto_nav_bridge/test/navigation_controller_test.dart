import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_ports.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';

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

  Future<DeferredRoutes> prepareDestinationChange() async {
    controller.dispose();
    final deferred = DeferredRoutes();
    controller = NavigationController(
        ble: ble,
        directions: deferred,
        location: positions,
        sideRoads: sideRoads);
    final starting = controller.startNavigation(p2);
    await pumpEventQueue();
    deferred.requests.single.complete([const RouteCandidate(steps: mainRoute)]);
    await starting;
    positions.emit(NavigationFix(p0.latitude, p0.longitude,
        heading: 0, accuracy: 5, speed: 0, timestamp: DateTime.now()));
    await pumpEventQueue();
    return deferred;
  }

  const newDestination = LatLng(.003, 0);

  test('map diagnostics retain camera and preview events, not arbitrary data',
      () {
    controller.recordMapDiagnostic('fit_requested');
    controller.recordMapDiagnostic('fit_skipped_active_gesture');
    controller.recordMapDiagnostic('route_preview_started');
    controller.recordMapDiagnostic('route_preview_stopped');
    controller.recordMapDiagnostic('private_location=123');
    expect(controller.diagnostics, contains('map fit_requested'));
    expect(controller.diagnostics, contains('map fit_skipped_active_gesture'));
    expect(controller.diagnostics, contains('map route_preview_started'));
    expect(controller.diagnostics, contains('map route_preview_stopped'));
    expect(controller.diagnostics, isNot(contains('private_location')));
  });

  test('route cache prefetches once and GPS never fetches side roads',
      () async {
    controller.dispose();
    final cache = FakeRouteSideRoads();
    controller = NavigationController(
        ble: ble, directions: routes, location: positions, sideRoads: cache);
    await controller.startNavigation(p2);
    expect(cache.prefetchCount, 1);
    expect(cache.route.first, p0);
    expect(cache.route.last, p2);
    positions.emit(NavigationFix(p0.latitude, p0.longitude,
        heading: 0, accuracy: 5, speed: 4, timestamp: DateTime.now()));
    await pumpEventQueue();
    expect(cache.fetchCount, 0);
    expect(cache.cacheReads, greaterThan(0));
  });

  test('preview warms side-road tiles without sending BLE guidance', () async {
    controller.dispose();
    final cache = FakeRouteSideRoads();
    controller = NavigationController(
        ble: ble, directions: routes, location: positions, sideRoads: cache);

    await controller.previewDestination(p2);
    expect(cache.prefetchCount, 1);
    expect(cache.route.first, p0);
    expect(cache.route.last, p2);
    expect(ble.sent, isEmpty);

    await controller.startNavigation(p2);
    expect(cache.prefetchCount, 2);
  });

  const newRoutes = [
    RouteCandidate(steps: [
      RouteStep(
          direction: DeviceDirection.up,
          start: p0,
          end: newDestination,
          distanceMeters: 333),
    ])
  ];

  test('nearby ranking uses route time without changing active navigation',
      () async {
    final deferred = await prepareDestinationChange();
    const far = LatLng(.004, 0);
    final ranking = controller.rankNearbyPlaces(const [
      PlaceResult(name: 'BP near', address: '', location: newDestination),
      PlaceResult(name: 'BP far', address: '', location: far),
    ], controller.voiceSearchOrigin!, () => true);
    await pumpEventQueue();
    deferred.requests.last.complete([
      RouteCandidate(
          steps: newRoutes.first.steps, expectedTravelTimeSeconds: 300)
    ]);
    await pumpEventQueue();
    deferred.requests.last.complete(const [
      RouteCandidate(steps: [
        RouteStep(
            direction: DeviceDirection.up,
            start: p0,
            end: far,
            distanceMeters: 444)
      ], expectedTravelTimeSeconds: 120)
    ]);
    final result = await ranking;
    expect(result.first.place.name, 'BP far');
    expect(result.first.seconds, 120);
    expect(controller.destination, same(p2));
  });
  test('cancelled nearby ranking discards late results', () async {
    final deferred = await prepareDestinationChange();
    var current = true;
    final ranking = controller.rankNearbyPlaces(
        const [PlaceResult(name: 'BP', address: '', location: newDestination)],
        controller.voiceSearchOrigin!,
        () => current);
    await pumpEventQueue();
    current = false;
    deferred.requests.last.complete([
      RouteCandidate(
          steps: newRoutes.first.steps, expectedTravelTimeSeconds: 100)
    ]);
    expect(await ranking, isEmpty);
    expect(controller.destination, same(p2));
  });

  test('destination replacement commits only after valid new route succeeds',
      () async {
    final deferred = await prepareDestinationChange();
    final oldState = controller.current;
    final change = controller.changeDestination(newDestination,
        expectedDestination: p2, stillConfirmed: () => true);
    await pumpEventQueue();
    expect(controller.destination, same(p2));
    expect(controller.current, oldState);
    deferred.requests.last.complete(newRoutes);
    expect(await change, isTrue);
    expect(controller.destination, same(newDestination));
    expect(controller.phase, NavPhase.navigating);
  });

  test('destination lookup failure preserves old route and guidance', () async {
    final deferred = await prepareDestinationChange();
    final oldRoute = controller.selectedRoute;
    final oldState = controller.current;
    final change = controller.changeDestination(newDestination,
        expectedDestination: p2, stillConfirmed: () => true);
    await pumpEventQueue();
    deferred.requests.last.completeError(Exception('network'));
    expect(await change, isFalse);
    expect(controller.destination, same(p2));
    expect(controller.selectedRoute, same(oldRoute));
    expect(controller.current, oldState);
  });

  for (final action in ['cancel', 'stop', 'pause']) {
    test('late destination result cannot commit after $action', () async {
      final deferred = await prepareDestinationChange();
      var confirmed = true;
      final change = controller.changeDestination(newDestination,
          expectedDestination: p2, stillConfirmed: () => confirmed);
      await pumpEventQueue();
      if (action == 'cancel') confirmed = false;
      if (action == 'stop') await controller.stopNavigation();
      if (action == 'pause') await controller.pause();
      deferred.requests.last.complete(newRoutes);
      expect(await change, isFalse);
      expect(controller.destination, isNot(same(newDestination)));
    });
  }

  test('unmatched new route does not replace navigation', () async {
    final deferred = await prepareDestinationChange();
    final change = controller.changeDestination(newDestination,
        expectedDestination: p2, stillConfirmed: () => true);
    await pumpEventQueue();
    deferred.requests.last.complete(const []);
    expect(await change, isFalse);
    expect(controller.destination, same(p2));
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

  test('preferences clear previews and cannot change during a ride', () async {
    await controller.previewDestination(p2);
    expect(controller.routeOptions, isNotEmpty);
    controller.updatePreferences(highways: true, tolls: true, ferries: false);
    expect(controller.routeOptions, isEmpty);
    await controller.startNavigation(p2);
    controller.updatePreferences(highways: false, tolls: false, ferries: true);
    expect(controller.avoidHighways, isTrue);
    expect(controller.avoidHighways, isTrue);
    expect(controller.avoidFerries, isFalse);
  });

  test('opposite-course candidates fail safely instead of replacing the route',
      () async {
    await controller.startNavigation(p2);
    final now = DateTime.now();
    for (var i = 0; i < 2; i++) {
      positions.emit(NavigationFix(0.0002, 0,
          heading: 180,
          accuracy: 5,
          speed: 3,
          timestamp: now.add(Duration(milliseconds: i))));
      await pumpEventQueue();
    }
    expect(routes.fetchCount, 2);
    expect(controller.current?.rerouting, isTrue);
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.direction, DeviceDirection.stop);
    expect(ble.sent.last.distanceMeters, 0);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);
    expect(controller.error, contains('travel direction'));
  });

  test('nearby reroute with unreliable course survives former 25 m cliff',
      () async {
    final candidate = FakeRoutes(const [
      RouteStep(
          direction: DeviceDirection.up,
          start: LatLng(0.0004, 0.00223),
          end: LatLng(0.0014, 0.00223),
          distanceMeters: 111),
      RouteStep(
          direction: DeviceDirection.right,
          start: LatLng(0.0014, 0.00223),
          end: p2,
          distanceMeters: 200),
    ]);
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: candidate,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    for (var i = 0; i < 2; i++) {
      positions.emit(NavigationFix(offRoute.latitude, offRoute.longitude,
          heading: 248,
          accuracy: 9.57,
          speed: 1.57,
          timestamp: DateTime.now().add(Duration(milliseconds: i))));
      await pumpEventQueue();
    }
    expect(candidate.fetchCount, 1);
    expect(controller.error, isNull);
    expect(ble.sent.last.direction, isNot(DeviceDirection.stop));
    expect(controller.diagnostics, contains('distanceRejected=false'));
  });

  test('distant reroute reports distance rather than a false direction error',
      () async {
    final candidate = FakeRoutes(const [
      RouteStep(
          direction: DeviceDirection.up,
          start: LatLng(0.0004, 0.00265),
          end: LatLng(0.0014, 0.00265),
          distanceMeters: 111),
      RouteStep(
          direction: DeviceDirection.right,
          start: LatLng(0.0014, 0.00265),
          end: p2,
          distanceMeters: 200),
    ]);
    controller.dispose();
    controller = NavigationController(
        ble: ble,
        directions: routes,
        rerouteDirections: candidate,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    for (var i = 0; i < 2; i++) {
      positions.emit(NavigationFix(offRoute.latitude, offRoute.longitude,
          heading: -1,
          accuracy: 9.57,
          speed: 0,
          timestamp: DateTime.now().add(Duration(milliseconds: i))));
      await pumpEventQueue();
    }
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.direction, DeviceDirection.stop);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);
    expect(controller.error, contains('close enough'));
    expect(controller.diagnostics, contains('distanceRejected=true'));
    expect(controller.diagnostics, contains('directionRejected=false'));
  });

  test('walking-speed opposite headings do not withdraw valid guidance',
      () async {
    await controller.startNavigation(p2);
    for (final speed in [1.67, .67, 1.05]) {
      positions.emit(NavigationFix(.0002, 0,
          heading: 180, accuracy: 7, speed: speed, timestamp: DateTime.now()));
      await pumpEventQueue();
    }
    expect(routes.fetchCount, 1);
    expect(controller.error, isNull);
    expect(ble.sent.last.direction, DeviceDirection.left);
    expect(ble.sent.last.distanceMeters, greaterThan(0));
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
        ble: ble,
        directions: ValhallaDirectionsService(routeUrl: ''),
        location: positions,
        sideRoads: sideRoads);
    await controller.previewDestination(p2);
    expect(controller.error, contains('endpoint is empty'));
    await controller.startNavigation(p2);
    expect(controller.phase, NavPhase.error);
    expect(routes.fetchCount, 0);
    expect(controller.error, contains('endpoint is empty'));
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
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.direction, DeviceDirection.stop);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);
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
    expect(controller.error, isNull);
    expect(ble.sent, hasLength(1));
    expect(ble.sent.map((state) => state.direction), [
      DeviceDirection.left,
    ]);
  });

  test('startup GPS offset near origin does not announce or reroute', () async {
    await controller.startNavigation(p2);
    final now = DateTime.now();
    positions.emit(NavigationFix(0, .0003,
        heading: -1, accuracy: 5, speed: 0, timestamp: now));
    await pumpEventQueue();
    positions.emit(NavigationFix(0, .0003,
        heading: -1,
        accuracy: 5,
        speed: 0,
        timestamp: now.add(const Duration(milliseconds: 1))));
    await pumpEventQueue();
    expect(controller.error, isNull);
    expect(controller.diagnostics, isNot(contains('reroute_start')));
    expect(routes.fetchCount, 1);
    expect(controller.current?.rerouting, isFalse);
  });

  test('voice place search refreshes a quiet stream independently of turn',
      () async {
    await controller.startNavigation(p2);
    expect(controller.voiceSearchOrigin, isNull);
    positions.current = NavigationFix(p0.latitude, p0.longitude,
        heading: -1, accuracy: 8, speed: 0, timestamp: DateTime.now());
    final origin = await controller.refreshVoiceSearchOrigin();
    expect(origin, isA<NavigationFix>());
    expect(controller.voiceSearchOrigin, same(origin));
    expect(routes.fetchCount, 1);
  });

  test('reroute failure keeps cached map but withdraws old turn and distance',
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
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.direction, DeviceDirection.stop);
    expect(ble.sent.last.distanceMeters, 0);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);
    expect(controller.error, contains('simulated reroute failure'));

    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(routes.fetchCount, 2);
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);
    expect(controller.error, contains('simulated reroute failure'));
  });

  test('failed reroute resumes cached guidance after a fresh on-route fix',
      () async {
    final deferred = DeferredRoutes();
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      rerouteDirections: deferred,
      location: positions,
      sideRoads: sideRoads,
    );
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(deferred.fetchCount, 1);
    expect(ble.sent.last.rerouting, isTrue);
    expect(ble.sent.last.direction, DeviceDirection.stop);
    expect(ble.sent.last.routePreviewPoints, isNotEmpty);

    final recovered = NavigationFix(p0.latitude, p0.longitude,
        heading: 0, accuracy: 5, speed: 0, timestamp: DateTime.now());
    positions.emit(recovered);
    await pumpEventQueue();
    deferred.requests.single.completeError(Exception('network unavailable'));
    await pumpEventQueue(times: 10);

    expect(controller.phase, NavPhase.navigating);
    expect(controller.error, isNull);
    expect(controller.selectedRoute?.steps, mainRoute);
    expect(controller.current?.direction, DeviceDirection.left);
    expect(ble.sent.last.direction, DeviceDirection.left);
    expect(controller.diagnostics,
        contains('reroute_failed_recovered_on_cached_route'));
  });

  test('failed reroute retries latest fresh fix without another stream event',
      () async {
    controller.dispose();
    routes = FakeRoutes(mainRoute, throwAfterInitialRoute: true);
    controller = NavigationController(
        ble: ble,
        directions: routes,
        location: positions,
        sideRoads: sideRoads);
    await controller.startNavigation(p2);
    positions.emit(offRoute);
    await pumpEventQueue();
    positions.emit(offRoute);
    await pumpEventQueue();
    expect(routes.fetchCount, 2);
    await Future<void>.delayed(const Duration(seconds: 8));
    positions.emit(NavigationFix(offRoute.latitude, offRoute.longitude,
        heading: 90, accuracy: 5, speed: 5, timestamp: DateTime.now()));
    await pumpEventQueue();
    expect(routes.fetchCount, 2);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(routes.fetchCount, 3);
    expect(controller.diagnostics, contains('automatic_retry'));
    expect(controller.diagnostics, contains('accuracy=5'));
    controller.clearDiagnostics();
    expect(controller.diagnostics, isEmpty);
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

  group('stationary heartbeat', () {
    NavigationFix still(DateTime at, {LatLng at_ = p0, double accuracy = 5}) =>
        NavigationFix(at_.latitude, at_.longitude,
            heading: -1, accuracy: accuracy, speed: 0, timestamp: at);

    void startQuietTrip(FakeAsync async,
        {LatLng at = p0, double accuracy = 5}) {
      // Streams created in setUp belong to the real zone, where their
      // microtasks escape flushMicrotasks. Rebuild them inside the fake zone.
      controller.dispose();
      unawaited(positions.close());
      positions = FakePositions(current: p0);
      controller = NavigationController(
          ble: ble,
          directions: routes,
          location: positions,
          sideRoads: sideRoads);
      controller.startNavigation(p2);
      async.flushMicrotasks();
      // The stream's last fix is already a few seconds old: stopped bike.
      positions.emit(still(DateTime.now().subtract(const Duration(seconds: 3)),
          at_: at, accuracy: accuracy));
      async.flushMicrotasks();
    }

    test('a fresh one-shot fix re-sends the current state while stopped', () {
      fakeAsync((async) {
        startQuietTrip(async);
        final before = ble.sent.length;
        final last = ble.sent.last;
        positions.current = still(DateTime.now());
        async.elapse(const Duration(seconds: 2));
        expect(ble.sent.length, before + 1);
        expect(ble.sent.last, last);
      });
    });

    test('stationary jitter never counts towards a reroute', () {
      fakeAsync((async) {
        // 67 m beside the route, outside the start grace radius: one stream
        // sample is a first off-route sample. A second matcher sample from
        // the heartbeat would have triggered a reroute at a red light.
        const parked = LatLng(0.0003, 0.0006);
        startQuietTrip(async, at: parked, accuracy: 20);
        expect(routes.fetchCount, 1);
        final before = ble.sent.length;
        positions.current = still(DateTime.now(), at_: parked, accuracy: 20);
        async.elapse(const Duration(seconds: 6));
        expect(routes.fetchCount, 1);
        expect(controller.current?.rerouting, isNot(true));
        expect(ble.sent.length, greaterThan(before));
      });
    });

    test('a fix that has really moved is left to the stream', () {
      fakeAsync((async) {
        startQuietTrip(async);
        final before = ble.sent.length;
        positions.current = still(DateTime.now(), at_: p1);
        async.elapse(const Duration(seconds: 2));
        expect(ble.sent.length, before);
      });
    });

    test('a result for a replaced route is discarded', () {
      fakeAsync((async) {
        routes = FakeRoutes(mainRoute, alternates: const [
          RouteCandidate(steps: mainRoute, name: 'Main'),
          RouteCandidate(steps: alternateRoute, name: 'Alternate'),
        ]);
        startQuietTrip(async);
        final pending = Completer<LatLng>();
        positions.pendingCurrent = pending;
        async.elapse(const Duration(seconds: 2));
        // The one-shot is in flight when the trip's engine is replaced.
        // (A full stop/start cannot run under fakeAsync: broadcast-stream
        // cancel futures complete in the root zone.)
        controller.selectRoute(1);
        async.flushMicrotasks();
        final before = ble.sent.length;
        final last = ble.sent.last;
        pending.complete(still(DateTime.now()));
        async.flushMicrotasks();
        expect(ble.sent.length, before);
        expect(ble.sent.last, last);
      });
    });

    test('an unusable fix sends nothing, so the display reports stale', () {
      fakeAsync((async) {
        startQuietTrip(async);
        final before = ble.sent.length;
        positions.current = still(DateTime.now(), accuracy: 200);
        async.elapse(const Duration(seconds: 6));
        expect(ble.sent.length, before);
      });
    });
  });

  test('late preview result cannot replace the route after Start', () async {
    controller.dispose();
    final deferred = DeferredRoutes();
    controller = NavigationController(
        ble: ble,
        directions: deferred,
        location: positions,
        sideRoads: sideRoads);

    final preview = controller.previewDestination(p2);
    await pumpEventQueue();
    expect(deferred.requests, hasLength(1));
    final start = controller.startNavigation(p2);
    await pumpEventQueue();
    expect(deferred.requests, hasLength(2));
    deferred.requests[1]
        .complete([const RouteCandidate(steps: mainRoute, name: 'Start')]);
    await start;
    expect(controller.phase, NavPhase.navigating);

    deferred.requests[0]
        .completeError(Exception('late preview failure'), StackTrace.empty);
    await preview;
    expect(controller.selectedRoute?.name, 'Start');
    expect(controller.error, isNull);
    expect(controller.previewingRoute, isFalse);
  });

  test('an older preview response cannot overwrite a newer destination',
      () async {
    controller.dispose();
    final deferred = DeferredRoutes();
    controller = NavigationController(
        ble: ble,
        directions: deferred,
        location: positions,
        sideRoads: sideRoads);

    final first = controller.previewDestination(p1);
    await pumpEventQueue();
    final second = controller.previewDestination(p2);
    await pumpEventQueue();
    expect(deferred.requests, hasLength(2));
    deferred.requests[1]
        .complete([const RouteCandidate(steps: mainRoute, name: 'Newer')]);
    await second;
    deferred.requests[0]
        .complete([const RouteCandidate(steps: mainRoute, name: 'Older')]);
    await first;

    expect(controller.destination, p2);
    expect(controller.selectedRoute?.name, 'Newer');
    expect(controller.previewingRoute, isFalse);
  });

  test('preview route choice survives Start and reaches the display', () async {
    routes = FakeRoutes(mainRoute, alternates: [
      const RouteCandidate(steps: mainRoute, name: 'Route 1'),
      const RouteCandidate(steps: alternateRoute, name: 'Route 2'),
    ]);
    controller.dispose();
    controller = NavigationController(
      ble: ble,
      directions: routes,
      location: positions,
      sideRoads: sideRoads,
    );

    await controller.previewDestination(p2);
    expect(controller.selectedRouteIndex, 0);
    await controller.selectRoute(1);
    expect(controller.selectedRouteIndex, 1);
    expect(ble.sent, isEmpty);

    await controller.startNavigation(p2);
    expect(controller.selectedRouteIndex, 1);
    expect(controller.selectedRoute?.name, 'Route 2');
    positions.emit(p0);
    await pumpEventQueue();
    expect(ble.sent.last.direction, DeviceDirection.right);
  });

  test('switching route during navigation immediately refreshes BLE guidance',
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
      sideRoads: sideRoads,
    );
    await controller.startNavigation(p2);
    positions.emit(p0);
    await pumpEventQueue();
    final before = ble.sent.length;

    await controller.selectRoute(1);

    expect(controller.selectedRouteIndex, 1);
    expect(ble.sent.length, before + 1);
    expect(ble.sent.last.direction, DeviceDirection.right);
    expect(controller.current, ble.sent.last);
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

  test('GPS stream error withdraws guidance then restores it from a fresh fix',
      () async {
    await controller.startNavigation(p2);
    positions.emit(NavigationFix(p0.latitude, p0.longitude,
        heading: 0, accuracy: 5, speed: 0, timestamp: DateTime.now()));
    await pumpEventQueue();
    expect(ble.sent.last.direction, isNot(DeviceDirection.stop));

    positions.current = NavigationFix(p0.latitude, p0.longitude,
        heading: 0,
        accuracy: 5,
        speed: 0,
        timestamp: DateTime.now().add(const Duration(milliseconds: 100)));
    positions.fail();
    await pumpEventQueue();
    expect(ble.sent.last, NavState.stopped);
    expect(controller.error, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 2200));
    await pumpEventQueue();
    expect(ble.sent.last.direction, isNot(DeviceDirection.stop));
    expect(controller.error, isNull);
    expect(controller.diagnostics, contains('gps_stream_recovered'));
  });

  test('ending without disconnect clears trip and ignores later GPS', () async {
    await controller.startNavigation(p2);
    await controller.endNavigation(disconnectDevice: false);
    positions.emit(p0);
    await pumpEventQueue();
    expect(controller.phase, NavPhase.idle);
    expect(controller.destination, isNull);
    expect(controller.origin, isNull);
    expect(controller.current, isNull);
    expect(controller.routeOptions, isEmpty);
    expect(ble.sent, [NavState.stopped]);
    expect(ble.disconnectCount, 0);
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

class FakeRouteSideRoads extends FakeSideRoads
    implements RouteSideRoadProvider {
  int prefetchCount = 0;
  int cacheReads = 0;
  List<LatLng> route = const [];

  @override
  int get cacheVersion => 1;

  @override
  void prefetchRoute(List<LatLng> route, LatLng position,
      void Function(LatLng loadedNear) onProgress) {
    prefetchCount++;
    this.route = route;
  }

  @override
  void advancePrefetch(LatLng position) {}

  @override
  List<RoadSegment> cachedSideRoadsNear(LatLng position) {
    cacheReads++;
    return const [];
  }

  @override
  void cancelPrefetch() {}
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

  LatLng current;
  final _controller = StreamController<LatLng>.broadcast();
  bool permissionGranted = true;

  @override
  Future<bool> ensurePermission() async => permissionGranted;

  /// When set, one-shot requests wait for this instead of returning [current].
  Completer<LatLng>? pendingCurrent;

  @override
  Future<LatLng> currentPosition() async =>
      pendingCurrent == null ? current : await pendingCurrent!.future;

  @override
  Stream<LatLng> positionStream() => _controller.stream;

  void emit(LatLng position) => _controller.add(position);

  void fail() => _controller.addError(Exception('GPS lost'));

  Future<void> close() => _controller.close();
}
