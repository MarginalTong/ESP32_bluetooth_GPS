import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/rider_map_controller.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/rider_presence.dart';
import 'package:moto_nav_bridge/services/rider_presence_backend.dart';
import 'rider_map_controller_test.dart' show RidersFake;
import 'avatar_test_fakes.dart';

class PhotosFake extends RidersFake implements RiderAvatarBackend {
  int photos = 0, simultaneous = 0, maximum = 0;
  bool fail = false;
  Completer<Uint8List?>? photoGate;
  @override
  Future<Uint8List?> fetchAvatar(String publicId, String avatarId) async {
    photos++;
    simultaneous++;
    if (simultaneous > maximum) maximum = simultaneous;
    try {
      if (fail) throw StateError('offline');
      return photoGate != null ? await photoGate!.future : avatarJpeg();
    } finally {
      simultaneous--;
    }
  }
}

void main() {
  late PhotosFake backend;
  late RiderMapController riders;
  late DateTime now;
  const id = '10000000-0000-4000-8000-000000000001';
  const version = '20000000-0000-4000-8000-000000000001';
  RiderPresence marker({String avatar = version, double lat = -33.88}) =>
      RiderPresence(
        id,
        LatLng(lat, 151.12),
        now.add(const Duration(minutes: 1)),
        avatarId: avatar,
      );
  setUp(() {
    now = DateTime.now();
    backend = PhotosFake();
    riders = RiderMapController(backend, now: () => now, tick: false);
  });
  tearDown(() async {
    riders.dispose();
    await backend.auth.close();
  });
  test(
    'slow photos never hold up marker positions and late photos cannot revive hidden riders',
    () async {
      backend.snapshot = RiderSnapshot([marker()]);
      backend.photoGate = Completer();
      riders.setViewing(true);
      await pumpEventQueue();
      expect(riders.riders.length, 1);
      expect(riders.riders.single.avatarJpeg, isNull);
      riders.setViewing(false);
      backend.photoGate!.complete(avatarJpeg());
      await pumpEventQueue();
      expect(riders.riders, isEmpty);
      backend.photoGate = null;
      riders.setViewing(true);
      await pumpEventQueue();
      expect(backend.photos, 2);
      expect(riders.riders.single.avatarJpeg, isNotNull);
    },
  );
  test(
    'moving an unchanged avatar reuses the cache and a new version replaces it',
    () async {
      backend.snapshot = RiderSnapshot([marker()]);
      riders.setViewing(true);
      await pumpEventQueue();
      expect(backend.photos, 1);
      backend.snapshot = RiderSnapshot([marker(lat: -33.89)]);
      now = now.add(const Duration(seconds: 6));
      riders.pulse();
      await pumpEventQueue();
      expect(backend.photos, 1);
      expect(riders.riders.single.location.latitude, -33.89);
      backend.snapshot = RiderSnapshot([
        marker(avatar: '20000000-0000-4000-8000-000000000002'),
      ]);
      now = now.add(const Duration(seconds: 6));
      riders.pulse();
      await pumpEventQueue();
      expect(backend.photos, 2);
      expect(riders.riders.single.avatarJpeg, isNotNull);
    },
  );
  test(
    'photo failure preserves default markers and backs off separately',
    () async {
      backend.fail = true;
      backend.snapshot = RiderSnapshot([marker()]);
      riders.setViewing(true);
      await pumpEventQueue();
      expect(riders.riders.length, 1);
      expect(riders.error, isNull);
      expect(backend.photos, 1);
      now = now.add(const Duration(seconds: 6));
      riders.pulse();
      await pumpEventQueue();
      expect(backend.photos, 1);
      backend.fail = false;
      now = now.add(const Duration(seconds: 30));
      riders.pulse();
      await pumpEventQueue();
      expect(backend.photos, 2);
      expect(riders.riders.single.avatarJpeg, isNotNull);
    },
  );
  test('photo downloads are concurrency and memory bounded', () async {
    backend.snapshot = RiderSnapshot(
      List.generate(
        100,
        (i) => RiderPresence(
          '10000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          const LatLng(-33.88, 151.12),
          now.add(const Duration(minutes: 1)),
          avatarId: version,
        ),
      ),
    );
    riders.setViewing(true);
    await pumpEventQueue();
    expect(backend.photos, 64);
    expect(backend.maximum, lessThanOrEqualTo(2));
    expect(riders.riders.where((r) => r.avatarJpeg != null).length, 64);
  });
}
