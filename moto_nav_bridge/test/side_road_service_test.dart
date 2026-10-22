import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/side_road_service.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as mvt;

void main() {
  test('loads motorcyclable Valhalla edges and caches the tile', () async {
    var calls = 0;
    final bytes = _tileBytes();
    final client = MockClient((request) async {
      calls++;
      expect(request.url.path, '/tile');
      final options = request.url.queryParameters['json']!;
      expect(options, contains('edge.access_forward'));
      expect(options, contains('"z":14'));
      return http.Response.bytes(bytes, 200);
    });
    final service =
        SideRoadService(client: client, baseUrl: 'https://example.test');
    // Middle of one z14 tile, far enough from its boundary to need one tile.
    final center = _tilePoint(15072.5, 9832.5);

    final first = await service.fetchSideRoadsNear(center);
    final second = await service.fetchSideRoadsNear(center);

    expect(calls, 1);
    expect(first, hasLength(1)); // reverse edge is deduplicated
    expect(second, hasLength(1));
    expect(first.single.start.distanceTo(center), lessThan(5));
    service.dispose();
  });

  test('tile failure leaves guidance independent and allows a retry', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('unavailable', 503);
    });
    final service =
        SideRoadService(client: client, baseUrl: 'https://example.test');
    final center = _tilePoint(15072.5, 9832.5);

    expect(await service.fetchSideRoadsNear(center), isEmpty);
    expect(await service.fetchSideRoadsNear(center), isEmpty);
    expect(calls, 2);
    service.dispose();
  });

  test('route prefetch fills the display cache without GPS network fetches',
      () async {
    final response = Completer<http.Response>();
    final loaded = Completer<void>();
    var calls = 0;
    final service = SideRoadService(
        client: MockClient((_) {
          calls++;
          return response.future;
        }),
        baseUrl: 'https://example.test');
    final center = _tilePoint(15072.5, 9832.5);
    service.prefetchRoute(
        [center, LatLng(center.latitude + .0001, center.longitude)], center,
        (_) {
      if (!loaded.isCompleted) loaded.complete();
    });
    expect(service.cachedSideRoadsNear(center), isEmpty);
    response.complete(http.Response.bytes(_tileBytes(), 200));
    await loaded.future.timeout(const Duration(seconds: 5));
    expect(service.cachedSideRoadsNear(center), hasLength(1));
    final callsAfterPrefetch = calls;
    service.cachedSideRoadsNear(center);
    expect(calls, callsAfterPrefetch);
    service.dispose();
  });

  test('cancelled route cannot publish a late tile', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var published = false;
    final service = SideRoadService(
        client: MockClient((_) {
          if (!started.isCompleted) started.complete();
          return response.future;
        }),
        baseUrl: 'https://example.test');
    final center = _tilePoint(15072.5, 9832.5);
    service.prefetchRoute(
        [center, LatLng(center.latitude + .0001, center.longitude)],
        center,
        (_) => published = true);
    await started.future;
    service.cancelPrefetch();
    response.complete(http.Response.bytes(_tileBytes(), 200));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(published, isFalse);
    expect(service.cachedSideRoadsNear(center), isEmpty);
    service.dispose();
  });

  test('rolling route cache loads ahead, then advances and evicts behind',
      () async {
    final firstResponse = Completer<http.Response>();
    final secondResponse = Completer<http.Response>();
    final firstLoaded = Completer<void>();
    final secondLoaded = Completer<void>();
    var advanced = false;
    final service = SideRoadService(
        client: MockClient((request) {
          final tile = (jsonDecode(request.url.queryParameters['json']!)
              as Map<String, dynamic>)['tile'] as Map<String, dynamic>;
          if (tile['x'] == 15072) return firstResponse.future;
          if (tile['x'] == 15075) return secondResponse.future;
          return Future.value(http.Response.bytes(_tileBytes(), 200));
        }),
        baseUrl: 'https://example.test');
    final start = _tilePoint(15072.5, 9832.5);
    final end = _tilePoint(15075.5, 9832.5);
    service.prefetchRoute([start, end], start, (loadedNear) {
      if (!advanced &&
          !firstLoaded.isCompleted &&
          loadedNear.distanceTo(start) < 500) {
        firstLoaded.complete();
      } else if (advanced &&
          !secondLoaded.isCompleted &&
          service.cachedSideRoadsNear(end).isNotEmpty) {
        secondLoaded.complete();
      }
    });
    firstResponse.complete(http.Response.bytes(_tileBytes(), 200));
    await firstLoaded.future.timeout(const Duration(seconds: 5));
    expect(service.cachedSideRoadsNear(start), hasLength(1));
    expect(service.cachedSideRoadsNear(end), isEmpty);
    advanced = true;
    service.advancePrefetch(end);
    secondResponse.complete(http.Response.bytes(_tileBytes(), 200));
    await secondLoaded.future.timeout(const Duration(seconds: 5));
    expect(service.cachedSideRoadsNear(end), hasLength(1));
    expect(service.cachedSideRoadsNear(start), isEmpty);
    service.dispose();
  });
}

LatLng _tilePoint(double x, double y) {
  const scale = 1 << 14;
  final longitude = x / scale * 360 - 180;
  final mercator = math.pi * (1 - 2 * y / scale);
  final latitude =
      math.atan((math.exp(mercator) - math.exp(-mercator)) / 2) * 180 / math.pi;
  return LatLng(latitude, longitude);
}

List<int> _tileBytes() {
  final road = mvt.createVectorTileFeature(
    tags: [0, 0, 1, 1],
    type: mvt.VectorTile_GeomType.LINESTRING,
    // Move to tile centre, then ~100 m east.
    geometry: [9, 4096, 4096, 10, 400, 0],
  );
  final reverse = mvt.createVectorTileFeature(
    tags: [0, 0, 1, 1],
    type: mvt.VectorTile_GeomType.LINESTRING,
    geometry: [9, 4496, 4096, 10, 399, 0],
  );
  final footpath = mvt.createVectorTileFeature(
    tags: [0, 1, 1, 1],
    type: mvt.VectorTile_GeomType.LINESTRING,
    geometry: [9, 4096, 4096, 10, 0, 400],
  );
  final tile = mvt.createVectorTile(layers: [
    mvt.createVectorTileLayer(
      name: 'edges',
      extent: 4096,
      version: 2,
      keys: ['access:fwd', 'access:bwd'],
      values: [
        mvt.createVectorTileValue(stringValue: '1024'),
        mvt.createVectorTileValue(stringValue: '0'),
      ],
      features: [road, reverse, footpath],
    ),
  ]);
  return tile.writeToBuffer();
}
