import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/controllers/navigation_continuity_controller.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/services/directions_exception.dart';
import 'package:moto_nav_bridge/services/packet_signer.dart';
import 'package:moto_nav_bridge/config/ble_constants.dart';
import 'navigation_controller_test.dart'
    show
        FakeBle,
        FakeRoutes,
        FakePositions,
        FakeSideRoads,
        p0,
        p2,
        offRoute,
        mainRoute,
        rerouteRoute;
import 'offline_navigation_test.dart' show fix, PendingRoutes;

class Link extends ChangeNotifier {
  bool up = false, retrying = false;
  void change(bool value) {
    up = value;
    retrying = !value;
    notifyListeners();
  }
}

class OfflineRoutes extends FakeRoutes {
  OfflineRoutes() : super(mainRoute);
  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) => Future.error(
    DirectionsException('route network unavailable', networkUnavailable: true),
  );
}

void main() {
  for (final gap in [1, 10, 120]) {
    test(
      '$gap second BLE interruption keeps the trip and resynchronizes fresh guidance',
      () {
        fakeAsync((time) {
          final gps = FakePositions(current: p0);
          final ble = FakeBle();
          final link = Link();
          final nav = NavigationController(
            ble: ble,
            directions: FakeRoutes(mainRoute),
            location: gps,
            sideRoads: FakeSideRoads(),
          );
          final continuity = NavigationContinuityController(
            navigation: nav,
            link: link,
            connected: () => link.up,
            reconnecting: () => link.retrying,
          );
          nav.startNavigation(p2);
          time.flushMicrotasks();
          gps.emit(p0);
          time.flushMicrotasks();
          final route = nav.selectedRoute;
          final destination = nav.destination;
          link.change(false);
          time.elapse(Duration(seconds: gap));
          expect(nav.phase, NavPhase.navigating);
          expect(nav.selectedRoute, same(route));
          expect(
            continuity.conditions,
            containsAll([
              NavigationCondition.navigating,
              NavigationCondition.bleDisconnected,
              NavigationCondition.reconnecting,
            ]),
          );
          gps.current = fix(const LatLng(0.0005, 0));
          link.change(true);
          time.flushMicrotasks();
          expect(nav.destination, same(destination));
          expect(nav.selectedRoute, same(route));
          expect(ble.sent.last.direction, DeviceDirection.left);
          expect(ble.sent.last.distanceMeters, lessThan(100));
          expect(ble.sent.last.expiresAtUtcSeconds, isNotNull);
          expect(continuity.conditions, {NavigationCondition.navigating});
          continuity.dispose();
          nav.dispose();
          unawaited(gps.close());
          link.dispose();
        });
      },
    );
  }

  test(
    'network, GPS and BLE faults coexist without deleting route or ending trip',
    () async {
      final gps = FakePositions(current: p0);
      final ble = FakeBle();
      final link = Link();
      final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        rerouteDirections: OfflineRoutes(),
        location: gps,
        sideRoads: FakeSideRoads(),
      );
      final continuity = NavigationContinuityController(
        navigation: nav,
        link: link,
        connected: () => link.up,
        reconnecting: () => link.retrying,
      );
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      final route = nav.selectedRoute;
      gps.emit(offRoute);
      gps.emit(offRoute);
      await pumpEventQueue();
      gps.fail();
      link.change(false);
      await pumpEventQueue();
      expect(
        continuity.conditions,
        containsAll([
          NavigationCondition.navigating,
          NavigationCondition.networkOffline,
          NavigationCondition.gpsUnavailable,
          NavigationCondition.bleDisconnected,
          NavigationCondition.reconnecting,
        ]),
      );
      expect(nav.selectedRoute, same(route));
      expect(ble.sent.last.routePreviewPoints, isNotEmpty);
      expect(ble.sent.last.rerouting, isTrue);
      expect(
        continuity.conditions,
        isNot(contains(NavigationCondition.navigationEnded)),
      );
      await nav.endNavigation(disconnectDevice: false);
      expect(
        continuity.conditions,
        contains(NavigationCondition.navigationEnded),
      );
      continuity.dispose();
      nav.dispose();
      await gps.close();
      link.dispose();
    },
  );

  test(
    'route recovery and BLE reconnection together do not reset the session',
    () async {
      final gps = FakePositions(current: p0);
      final ble = FakeBle();
      final link = Link();
      final recovery = PendingRoutes();
      final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        rerouteDirections: recovery,
        location: gps,
        sideRoads: FakeSideRoads(),
      );
      final continuity = NavigationContinuityController(
        navigation: nav,
        link: link,
        connected: () => link.up,
        reconnecting: () => link.retrying,
      );
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      gps.emit(offRoute);
      gps.emit(offRoute);
      await pumpEventQueue();
      final destination = nav.destination;
      gps.current = fix(offRoute);
      link.change(true);
      recovery.pending.complete([const RouteCandidate(steps: rerouteRoute)]);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.navigating);
      expect(nav.destination, same(destination));
      expect(ble.sent.last.direction, DeviceDirection.right);
      expect(nav.rerouteFailed, isFalse);
      continuity.dispose();
      nav.dispose();
      await gps.close();
      link.dispose();
    },
  );

  test(
    'foreground refresh rejects stale GPS and never revives old live distance',
    () async {
      final gps = FakePositions(current: p0);
      final ble = FakeBle();
      final link = Link();
      final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        location: gps,
        sideRoads: FakeSideRoads(),
      );
      final continuity = NavigationContinuityController(
        navigation: nav,
        link: link,
        connected: () => link.up,
        reconnecting: () => link.retrying,
      );
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      gps.current = fix(
        p0,
        at: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      link.change(true);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.navigating);
      expect(nav.gpsUnavailable, isTrue);
      expect(ble.sent.last.rerouting, isTrue);
      expect(ble.sent.last.distanceMeters, 0);
      expect(ble.sent.last.routePreviewPoints, isNotEmpty);
      gps.current = fix(p0);
      continuity.resumed();
      await pumpEventQueue();
      expect(nav.gpsUnavailable, isFalse);
      expect(ble.sent.last.direction, DeviceDirection.left);
      continuity.dispose();
      nav.dispose();
      await gps.close();
      link.dispose();
    },
  );

  test('expiry remains GPS-based and fits the signed packet budget', () {
    final deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10;
    final state = NavState(
      direction: DeviceDirection.left,
      distanceMeters: 9999,
      expiresAtUtcSeconds: deadline,
      routePreviewPoints: List.filled(20, 1280),
      sideRoadPreviewPoints: List.filled(32, 1280),
    );
    final body = jsonDecode(state.toWire()) as Map<String, dynamic>;
    expect(body['e'], deadline);
    expect(state.copyWith(distanceMeters: 100).expiresAtUtcSeconds, deadline);
    final signer = PacketSigner(
      key: Uint8List.fromList(List.filled(16, 1)),
      sessionNonce: Uint8List.fromList(List.filled(8, 2)),
    );
    expect(
      utf8.encode(signer.sign(state.toWire())).length,
      lessThanOrEqualTo(BleConstants.maxSignedPacketBytes),
    );
  });

  test(
    'stationary GPS recovery resumes through heartbeat without a new movement',
    () {
      fakeAsync((time) {
        final gps = FakePositions(current: p0);
        final ble = FakeBle();
        final nav = NavigationController(
          ble: ble,
          directions: FakeRoutes(mainRoute),
          location: gps,
          sideRoads: FakeSideRoads(),
        );
        nav.startNavigation(p2);
        time.flushMicrotasks();
        gps.emit(
          NavigationFix(
            p0.latitude,
            p0.longitude,
            heading: 0,
            speed: 0,
            accuracy: 100,
            timestamp: DateTime.now().subtract(const Duration(seconds: 3)),
          ),
        );
        time.flushMicrotasks();
        expect(nav.gpsUnavailable, isTrue);
        gps.current = fix(p0);
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(nav.gpsUnavailable, isFalse);
        expect(nav.phase, NavPhase.navigating);
        expect(ble.sent.last.direction, DeviceDirection.left);
        nav.dispose();
        unawaited(gps.close());
      });
    },
  );

  test(
    'a reroute response cannot revive guidance after GPS quality is lost',
    () async {
      final gps = FakePositions(current: p0);
      final ble = FakeBle();
      final recovery = PendingRoutes();
      final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        rerouteDirections: recovery,
        location: gps,
        sideRoads: FakeSideRoads(),
      );
      await nav.startNavigation(p2);
      gps.emit(p0);
      await pumpEventQueue();
      final route = nav.selectedRoute;
      gps.emit(offRoute);
      gps.emit(offRoute);
      await pumpEventQueue();
      gps.emit(
        NavigationFix(
          offRoute.latitude,
          offRoute.longitude,
          heading: 0,
          accuracy: 100,
          speed: 5,
          timestamp: DateTime.now(),
        ),
      );
      await pumpEventQueue();
      recovery.pending.complete([const RouteCandidate(steps: rerouteRoute)]);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.navigating);
      expect(nav.selectedRoute, same(route));
      expect(nav.gpsUnavailable, isTrue);
      expect(nav.current!.rerouting, isTrue);
      expect(ble.sent.last.direction, DeviceDirection.stop);
      nav.dispose();
      await gps.close();
    },
  );
}
