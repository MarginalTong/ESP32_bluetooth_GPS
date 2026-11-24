import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/offline_trip.dart';
import 'package:moto_nav_bridge/services/navigation_session_store.dart';
import 'navigation_controller_test.dart'
    show
        FakeBle,
        FakeRoutes,
        FakeSideRoads,
        FakePositions,
        mainRoute,
        rerouteRoute,
        p0,
        p1,
        p2,
        offRoute;

class MemorySessions implements NavigationSessionStore {
  OfflineTrip? trip;
  Completer<void>? gate;
  @override
  Future<void> save(OfflineTrip value) async {
    if (gate != null) await gate!.future;
    trip = OfflineTrip.fromMap(
      jsonDecode(jsonEncode(value.toMap())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> checkpoint(TripProgress progress) async {
    if (trip?.id == progress.id) trip = trip!.withProgress(progress);
  }

  @override
  Future<OfflineTrip?> load() async => trip;
  @override
  Future<void> clear() async {
    trip = null;
  }

  @override
  Future<void> flush() async {}
}

class PendingRoutes extends FakeRoutes {
  PendingRoutes() : super(mainRoute);
  final pending = Completer<List<RouteCandidate>>();
  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) {
    fetchCount++;
    return pending.future;
  }
}

class ReconnectingRoutes extends FakeRoutes {
  ReconnectingRoutes() : super(rerouteRoute);
  bool online = false;
  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) {
    if (!online) {
      fetchCount++;
      return Future.error(StateError('offline'));
    }
    return super.fetchRoutes(origin: origin, destination: destination);
  }
}

class LivePositions extends FakePositions {
  LivePositions() : super(current: p0);
  @override
  Future<LatLng> currentPosition() async => fix(current);
}

class FailedSessions extends MemorySessions {
  @override
  Future<void> save(OfflineTrip value) =>
      Future.error(StateError('disk unavailable'));
}

NavigationFix fix(LatLng point, {DateTime? at}) => NavigationFix(
  point.latitude,
  point.longitude,
  heading: 0,
  accuracy: 5,
  speed: 5,
  timestamp: at ?? DateTime.now(),
);

void main() {
  late FakeBle ble;
  late FakePositions gps;
  late FakeRoutes routes;
  late MemorySessions sessions;
  late NavigationController nav;
  NavigationController create({FakeRoutes? recovery}) => NavigationController(
    ble: ble,
    directions: routes,
    rerouteDirections: recovery,
    location: gps,
    sideRoads: FakeSideRoads(),
    sessions: sessions,
  );
  setUp(() {
    ble = FakeBle();
    gps = FakePositions(current: p0);
    routes = FakeRoutes(mainRoute, throwAfterInitialRoute: true);
    sessions = MemorySessions();
    nav = create();
  });
  tearDown(() async {
    nav.dispose();
    await gps.close();
  });

  test('preview can start without any second server request', () async {
    await nav.previewDestination(p2);
    await nav.startNavigation(p2);
    gps.emit(p0);
    await pumpEventQueue();
    expect(routes.fetchCount, 1);
    expect(nav.phase, NavPhase.navigating);
    expect(ble.sent.last.direction, DeviceDirection.left);
    expect(sessions.trip!.routes.single.steps.length, mainRoute.length);
  });

  test(
    'ten minutes offline retain route and continue distance and BLE updates',
    () {
      fakeAsync((time) {
        nav.startNavigation(p2);
        time.flushMicrotasks();
        gps.emit(p0);
        time.flushMicrotasks();
        final before = ble.sent.last.distanceMeters;
        for (var second = 1; second <= 600; second++) {
          time.elapse(const Duration(seconds: 1));
          gps.emit(LatLng(0.0005 * second / 600, 0));
          time.flushMicrotasks();
        }
        expect(routes.fetchCount, 1);
        expect(nav.phase, NavPhase.navigating);
        expect(ble.sent.last.direction, DeviceDirection.left);
        expect(ble.sent.last.distanceMeters, lessThan(before));
        expect(ble.sent.length, greaterThanOrEqualTo(601));
        expect(sessions.trip!.routes, isNotEmpty);
        nav.dispose();
      });
      // The controller disposed inside fakeAsync owns those periodic timers.
      nav = create();
    },
  );

  test(
    'local GPS and BLE recover before a pending HTTP request completes',
    () async {
      nav.dispose();
      final pending = PendingRoutes();
      nav = create(recovery: pending);
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      gps.emit(offRoute);
      gps.emit(offRoute);
      await pumpEventQueue();
      expect(pending.fetchCount, 1);
      expect(nav.current!.rerouting, isTrue);
      final sent = ble.sent.length;
      gps.emit(offRoute);
      await pumpEventQueue();
      expect(ble.sent.length, greaterThan(sent));
      expect(ble.sent.last.direction, DeviceDirection.stop);
      gps.emit(p0);
      await pumpEventQueue();
      expect(ble.sent.last.direction, DeviceDirection.left);
      expect(pending.pending.isCompleted, isFalse);
      pending.pending.complete([const RouteCandidate(steps: rerouteRoute)]);
      await pumpEventQueue();
      expect(nav.selectedRoute!.steps, mainRoute);
      expect(nav.error, isNull);
    },
  );

  test(
    'restart restores cursor but requires new GPS and explicit resume',
    () async {
      await nav.startNavigation(p2);
      gps.emit(p1);
      await pumpEventQueue();
      expect(sessions.trip!.progress.step, 1);
      nav.dispose();
      nav = create();
      final sent = ble.sent.length;
      expect(await nav.restoreSavedNavigation(), isTrue);
      expect(nav.phase, NavPhase.idle);
      expect(ble.sent.length, sent);
      gps.current = fix(
        p1,
        at: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(await nav.resumeSavedNavigation(), isFalse);
      expect(ble.sent.length, sent);
      gps.current = fix(p1);
      expect(await nav.resumeSavedNavigation(), isTrue);
      expect(nav.voiceStepIndex, 1);
      expect(nav.phase, NavPhase.navigating);
      expect(routes.fetchCount, 1);
    },
  );

  test(
    'End removes the saved trip, arrival does not leave a recovery prompt',
    () async {
      await nav.startNavigation(p2);
      await nav.endNavigation(disconnectDevice: false);
      expect(sessions.trip, isNull);
      routes = FakeRoutes(mainRoute);
      nav.dispose();
      nav = create();
      await nav.startNavigation(p2);
      gps.emit(p1);
      await pumpEventQueue();
      gps.emit(p2);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.arrived);
      expect(sessions.trip, isNull);
    },
  );

  test('slow persistence never blocks local tracking or BLE', () async {
    sessions.gate = Completer<void>();
    final start = nav.startNavigation(p2);
    await pumpEventQueue();
    gps.emit(p0);
    await pumpEventQueue();
    expect(nav.phase, NavPhase.navigating);
    expect(ble.sent.last.direction, DeviceDirection.left);
    sessions.gate!.complete();
    await start;
  });

  test(
    'online recovery retries from fresh GPS without resetting the session',
    () async {
      nav.dispose();
      await gps.close();
      gps = LivePositions();
      final recovery = ReconnectingRoutes();
      nav = create(recovery: recovery);
      await nav.startNavigation(p2);
      gps.current = offRoute;
      gps.emit(offRoute);
      gps.emit(offRoute);
      await pumpEventQueue();
      final destination = nav.destination;
      expect(nav.rerouteFailed, isTrue);
      expect(nav.current!.direction, DeviceDirection.stop);
      expect(nav.selectedRoute!.steps, mainRoute);
      recovery.online = true;
      // The existing ten-second retry budget remains; no connectivity ping is
      // needed, and the stationary GPS heartbeat supplies fresh evidence.
      await Future<void>.delayed(const Duration(seconds: 11));
      expect(nav.phase, NavPhase.navigating);
      expect(nav.destination, same(destination));
      expect(nav.rerouteFailed, isFalse);
      expect(nav.current!.direction, DeviceDirection.right);
      expect(recovery.fetchCount, greaterThanOrEqualTo(2));
      expect(routes.fetchCount, 1);
    },
  );

  test(
    'a cache write failure is visible but does not end local navigation',
    () async {
      nav.dispose();
      sessions = FailedSessions();
      nav = create();
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.navigating);
      expect(nav.diagnostics, contains('route_cache_write_failed'));
      expect(ble.sent.last.direction, DeviceDirection.left);
    },
  );

  test('End invalidates a late initial route response', () async {
    nav.dispose();
    final pending = PendingRoutes();
    routes = pending;
    nav = create();
    final starting = nav.startNavigation(p2);
    await pumpEventQueue();
    await nav.endNavigation(disconnectDevice: false);
    pending.pending.complete([const RouteCandidate(steps: mainRoute)]);
    await starting;
    await pumpEventQueue();
    expect(nav.phase, NavPhase.idle);
    expect(nav.routeOptions, isEmpty);
    expect(sessions.trip, isNull);
  });

  test(
    'restart retains completed stops and route-relative waypoint numbering',
    () async {
      sessions.trip = OfflineTrip(
        id: 'after-first-stop',
        destination: p2,
        routes: const [
          RouteCandidate(
            steps: [
              RouteStep(
                direction: DeviceDirection.up,
                start: p1,
                end: p2,
                distanceMeters: 111,
                waypointIndex: 0,
              ),
            ],
          ),
        ],
        stops: const [
          PlaceResult(name: 'Visited', address: '', location: p0),
          PlaceResult(name: 'Remaining', address: '', location: p2),
        ],
        preferences: const {'use_tolls': 0.0},
        progress: TripProgress(
          id: 'after-first-stop',
          active: true,
          selected: 0,
          step: 0,
          completed: 1,
          routeBase: 1,
          savedAt: DateTime.now(),
        ),
      );
      await nav.restoreSavedNavigation();
      gps.current = fix(p1);
      expect(await nav.resumeSavedNavigation(), isTrue);
      expect(nav.completedWaypoints, 1);
      gps.emit(fix(p2));
      await pumpEventQueue();
      expect(nav.completedWaypoints, 2);
      expect(nav.phase, NavPhase.arrived);
      expect(routes.fetchCount, 0);
    },
  );
}
