import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lane_guidance.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/road_segment.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/offline_trip.dart';
import 'package:moto_nav_bridge/services/navigation_session_store.dart';

OfflineTrip sampleTrip({String id = 'route-1'}) => OfflineTrip(
  id: id,
  destination: const LatLng(-33.8, 151.2),
  routes: [
    RouteCandidate(
      name: 'Mountain road',
      distanceMeters: 1000,
      expectedTravelTimeSeconds: 90,
      attribution: 'OSM',
      attributionUrl: 'https://openstreetmap.org/copyright',
      sideRoads: const [
        RoadSegment(start: LatLng(-33.9, 151.1), end: LatLng(-33.89, 151.11)),
      ],
      steps: [
        RouteStep(
          direction: DeviceDirection.right,
          start: const LatLng(-33.9, 151.1),
          end: const LatLng(-33.8, 151.2),
          distanceMeters: 1000,
          geometry: const [
            LatLng(-33.9, 151.1),
            LatLng(-33.85, 151.15),
            LatLng(-33.8, 151.2),
          ],
          rawManeuver: 'valhalla:10',
          roundaboutExitCount: 2,
          streetName: 'Forest Road',
          waypointIndex: 0,
          arrivalSide: RoadSide.left,
          lanes: LaneGuidance.fromFlags([false, true]),
          speedLimitsKph: const [60, 80],
        ),
      ],
    ),
  ],
  stops: const [
    PlaceResult(
      name: 'Stop',
      address: 'Roadside',
      location: LatLng(-33.8, 151.2),
    ),
  ],
  preferences: const {'use_tolls': 0.0},
  progress: TripProgress(
    id: id,
    active: true,
    selected: 0,
    step: 0,
    completed: 0,
    routeBase: 0,
    savedAt: DateTime.utc(2026, 11, 24),
  ),
);

void main() {
  late Directory directory;
  late FileNavigationSessionStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navio-offline-test-');
    store = FileNavigationSessionStore(directory: () async => directory);
  });
  tearDown(() async {
    await store.flush();
    await directory.delete(recursive: true);
  });

  test(
    'complete route round-trip retains geometry, maneuvers and metadata',
    () async {
      final trip = sampleTrip();
      await store.save(trip);
      final restarted = FileNavigationSessionStore(
        directory: () async => directory,
      );
      final loaded = await restarted.load();
      expect(jsonEncode(loaded!.toMap()), jsonEncode(trip.toMap()));
      expect(
        loaded.routes.single.steps.single.lanes,
        LaneGuidance.fromFlags([false, true]),
      );
      expect(loaded.routes.single.polyline.length, 3);
      final route = loaded.routes.single;
      final step = route.steps.single;
      expect(route.name, 'Mountain road');
      expect(route.distanceMeters, 1000);
      expect(route.expectedTravelTimeSeconds, 90);
      expect(route.attribution, 'OSM');
      expect(route.attributionUrl, 'https://openstreetmap.org/copyright');
      expect(route.sideRoads.length, 1);
      expect(step.direction, DeviceDirection.right);
      expect(step.rawManeuver, 'valhalla:10');
      expect(step.distanceMeters, 1000);
      expect(step.roundaboutExitCount, 2);
      expect(step.streetName, 'Forest Road');
      expect(step.waypointIndex, 0);
      expect(step.arrivalSide, RoadSide.left);
      expect(step.speedLimitsKph, [60, 80]);
      expect(loaded.stops.single.name, 'Stop');
      expect(loaded.preferences, {'use_tolls': 0.0});
    },
  );

  test(
    'checkpoint updates progress without rewriting route geometry',
    () async {
      await store.save(sampleTrip());
      final before = await File('${directory.path}/route.json').readAsBytes();
      await store.checkpoint(
        TripProgress(
          id: 'route-1',
          active: true,
          selected: 0,
          step: 0,
          completed: 1,
          routeBase: 0,
          savedAt: DateTime.now(),
          position: const LatLng(-33.81, 151.19),
        ),
      );
      expect((await store.load())!.progress.completed, 1);
      expect(await File('${directory.path}/route.json').readAsBytes(), before);
    },
  );

  test('checkpoint from an older route cannot replace a new route', () async {
    await store.save(sampleTrip());
    await store.checkpoint(sampleTrip().progress);
    await store.save(sampleTrip(id: 'new-route'));
    expect((await store.load())!.id, 'new-route');
  });

  test('queued writes cannot resurrect a trip after End', () async {
    final saving = store.save(sampleTrip());
    final checkpoint = store.checkpoint(sampleTrip().progress);
    final ending = store.clear();
    await Future.wait([saving, checkpoint, ending]);
    expect(await store.load(), isNull);
  });

  test(
    'interrupted temporary write leaves the last complete route readable',
    () async {
      await store.save(sampleTrip());
      await File('${directory.path}/route.json.tmp').writeAsString('{partial');
      expect((await store.load())!.id, 'route-1');
    },
  );

  test(
    'corrupt checkpoint falls back to route; corrupt geometry is rejected',
    () async {
      await store.save(sampleTrip());
      await File('${directory.path}/progress.json').writeAsString('invalid');
      expect((await store.load())!.id, 'route-1');
      final file = File('${directory.path}/route.json');
      final envelope =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      envelope['sha256'] = 'modified';
      await file.writeAsString(jsonEncode(envelope));
      await expectLater(store.load(), throwsFormatException);
    },
  );

  test('unsupported versions and invalid progress are rejected', () {
    final map = sampleTrip().toMap();
    map['version'] = 2;
    expect(() => OfflineTrip.fromMap(map), throwsFormatException);
    final wrong = sampleTrip().toMap();
    final progress = wrong['progress']! as Map<String, Object?>;
    progress['step'] = 20;
    expect(() => OfflineTrip.fromMap(wrong), throwsFormatException);
  });
}
