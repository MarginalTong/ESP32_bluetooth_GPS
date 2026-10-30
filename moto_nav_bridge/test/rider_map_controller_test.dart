import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/controllers/rider_map_controller.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/rider_presence.dart';
import 'package:moto_nav_bridge/services/rider_presence_backend.dart';

class RiderNav extends ChangeNotifier implements NavigationController {
  @override
  NavPhase phase = NavPhase.idle;
  @override
  NavigationFix? voiceFix;
  void change(NavPhase p, NavigationFix? fix) {
    phase = p;
    voiceFix = fix;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RidersFake implements RiderPresenceBackend {
  @override
  String? userId = 'user-a';
  @override
  bool get available => true;
  final auth = StreamController<String?>.broadcast();
  @override
  Stream<String?> get userChanges => auth.stream;
  int begins = 0, publishes = 0, fetches = 0;
  final stopped = <String>[];
  Completer<String>? waitingBegin;
  Completer<bool>? waitingPublish;
  Completer<RiderSnapshot>? waitingFetch;
  RiderSnapshot snapshot = const RiderSnapshot([]);
  @override
  Future<String> begin() async {
    begins++;
    return waitingBegin == null ? 'session-$begins' : waitingBegin!.future;
  }

  @override
  Future<void> stop(String session) async {
    stopped.add(session);
  }

  @override
  Future<bool> publish(String session, int sequence, NavigationFix fix) async {
    publishes++;
    return waitingPublish?.future ?? true;
  }

  @override
  Future<RiderSnapshot> fetch() async {
    fetches++;
    return waitingFetch?.future ?? snapshot;
  }
}

void main() {
  late RidersFake backend;
  late RiderNav nav;
  late RiderMapController riders;
  late DateTime now;
  NavigationFix fix({double accuracy = 5, double lat = -33.88}) =>
      NavigationFix(
        lat,
        151.12,
        accuracy: accuracy,
        heading: 0,
        speed: 3,
        timestamp: now,
      );
  setUp(() {
    now = DateTime.now();
    backend = RidersFake();
    nav = RiderNav();
    riders = RiderMapController(backend, now: () => now, tick: false)
      ..bindNavigation(nav);
  });
  tearDown(() async {
    riders.dispose();
    nav.dispose();
    await backend.auth.close();
  });

  test('off by default; viewing never opts into publishing', () async {
    nav.change(NavPhase.navigating, fix());
    riders.pulse();
    await pumpEventQueue();
    expect(backend.begins, 0);
    expect(backend.fetches, 0);
    riders.setViewing(true);
    await pumpEventQueue();
    expect(backend.fetches, 1);
    expect(backend.publishes, 0);
  });
  test(
    'sharing requires navigation and fresh accurate Sydney fix; throttles updates',
    () async {
      riders.setSharing(true);
      await pumpEventQueue();
      expect(backend.begins, 0);
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      expect(backend.publishes, 1);
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      expect(backend.publishes, 1);
      now = now.add(const Duration(seconds: 6));
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      expect(backend.publishes, 2);
      nav.change(NavPhase.navigating, fix(accuracy: 80));
      await pumpEventQueue();
      expect(backend.stopped, contains('session-1'));
      nav.change(NavPhase.navigating, fix(lat: -35));
      await pumpEventQueue();
      expect(backend.begins, 1);
    },
  );
  for (final phase in [NavPhase.arrived, NavPhase.idle, NavPhase.paused]) {
    test('$phase withdraws presence', () async {
      riders.setSharing(true);
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      nav.change(phase, fix());
      await pumpEventQueue();
      expect(backend.stopped, contains('session-1'));
    });
  }
  test(
    'turning off while begin is delayed withdraws token without publishing',
    () async {
      backend.waitingBegin = Completer();
      riders.setSharing(true);
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      riders.setSharing(false);
      backend.waitingBegin!.complete('late');
      await pumpEventQueue();
      expect(backend.publishes, 0);
      expect(backend.stopped, ['late']);
    },
  );
  test(
    'ending while a publish is delayed serializes withdrawal afterward',
    () async {
      backend.waitingPublish = Completer();
      riders.setSharing(true);
      nav.change(NavPhase.navigating, fix());
      await pumpEventQueue();
      nav.change(NavPhase.arrived, fix());
      backend.waitingPublish!.complete(true);
      await pumpEventQueue();
      expect(backend.stopped, ['session-1']);
    },
  );
  test(
    'late fetch after hide cannot reappear; expired markers are removed',
    () async {
      const id = '10000000-0000-4000-8000-000000000001';
      backend.waitingFetch = Completer();
      riders.setViewing(true);
      await pumpEventQueue();
      riders.setViewing(false);
      backend.waitingFetch!.complete(
        RiderSnapshot([
          RiderPresence(
            id,
            const LatLng(-33.88, 151.12),
            now.add(const Duration(seconds: 30)),
          ),
        ]),
      );
      await pumpEventQueue();
      expect(riders.riders, isEmpty);
      backend.waitingFetch = null;
      backend.snapshot = RiderSnapshot([
        RiderPresence(
          id,
          const LatLng(-33.88, 151.12),
          now.add(const Duration(seconds: 2)),
        ),
      ]);
      riders.setViewing(true);
      await pumpEventQueue();
      expect(riders.riders, hasLength(1));
      now = now.add(const Duration(seconds: 3));
      riders.pulse();
      expect(riders.riders, isEmpty);
    },
  );
  test('logout clears both toggles and cached riders', () async {
    riders.setSharing(true);
    riders.setViewing(true);
    nav.change(NavPhase.navigating, fix());
    await pumpEventQueue();
    backend.userId = null;
    backend.auth.add(null);
    await pumpEventQueue();
    expect(riders.sharing, isFalse);
    expect(riders.viewing, isFalse);
    expect(riders.riders, isEmpty);
  });
  test('hidden map and background do not keep polling', () async {
    riders.setViewing(true);
    await pumpEventQueue();
    expect(backend.fetches, 1);
    riders.setVisibility(foreground: false, mapVisible: true);
    now = now.add(const Duration(seconds: 6));
    riders.pulse();
    await pumpEventQueue();
    expect(backend.fetches, 1);
    riders.setVisibility(foreground: true, mapVisible: false);
    await pumpEventQueue();
    expect(backend.fetches, 1);
  });
}
