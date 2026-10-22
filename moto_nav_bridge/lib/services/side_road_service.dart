import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:vector_tile/vector_tile.dart';

import '../config/api_config.dart';
import '../models/lat_lng.dart';
import '../models/road_segment.dart';
import 'navigation_engine.dart';
import 'navigation_ports.dart';

/// Reads the same Valhalla road graph that plans the route. This request runs
/// independently of guidance: a tile failure must never hold up navigation.
class SideRoadService implements RouteSideRoadProvider {
  SideRoadService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.valhallaBaseUrl;

  final http.Client _client;
  final String _baseUrl;
  final Map<_TileId, Future<List<RoadSegment>>> _tiles = {};
  final Map<_TileId, List<RoadSegment>> _routeTiles = {};
  List<LatLng> _route = const [];
  void Function(LatLng)? _onProgress;
  LatLng? _windowOrigin;
  int _prefetchGeneration = 0;
  int _cacheVersion = 0;

  @override
  int get cacheVersion => _cacheVersion;

  // The deployed server currently caps /tile at z=14. It includes local
  // streets at this zoom, but tiles cover a broad area, so cache each tile.
  static const _zoom = 14;
  static const _radiusMeters = NavigationEngine.routePreviewDistanceMeters;
  static const _aheadMeters = 1500.0;
  static const _behindMeters = 250.0;
  static const _advanceMeters = 500.0;
  static const _maxSegments = 260;
  static const _maxConcurrentTiles = 3;
  static const _timeout = Duration(seconds: 5);
  static const _motorcycleAccess = 1024; // Valhalla kMotorcycleAccess.

  @override
  void prefetchRoute(List<LatLng> route, LatLng position,
      void Function(LatLng loadedNear) onProgress) {
    cancelPrefetch();
    if (route.length < 2) return;
    _route = List.unmodifiable(route);
    _onProgress = onProgress;
    advancePrefetch(position);
  }

  @override
  void advancePrefetch(LatLng position) {
    if (_route.length < 2 ||
        (_windowOrigin != null &&
            _windowOrigin!.distanceTo(position) < _advanceMeters)) {
      return;
    }
    _windowOrigin = position;
    final generation = ++_prefetchGeneration;
    final route = _route;
    final onProgress = _onProgress;
    if (onProgress == null) return;
    unawaited(() async {
      final corridor = <_TileId, List<_BoundingBox>>{};
      final tileAnchors = <_TileId, LatLng>{};
      void include(LatLng point) {
        final box = _BoundingBox.around(point, _radiusMeters);
        for (final id in _tilesFor(box)) {
          corridor.putIfAbsent(id, () => []).add(box);
          tileAnchors.putIfAbsent(id, () => point);
        }
      }

      // Only index the route window around the nearest point. The rest of a
      // long trip is neither downloaded nor retained in memory.
      await Future<void>.delayed(Duration.zero);
      var nearest = 0;
      var nearestDistance = double.infinity;
      for (var i = 0; i < route.length; i++) {
        final distance = route[i].distanceTo(position);
        if (distance < nearestDistance) {
          nearest = i;
          nearestDistance = distance;
        }
        if (i % 200 == 0) await Future<void>.delayed(Duration.zero);
        if (generation != _prefetchGeneration) return;
      }
      var back = nearest;
      var backPoint = route[nearest];
      var covered = 0.0;
      while (back > 0 && covered < _behindMeters) {
        final length = route[back].distanceTo(route[back - 1]);
        if (covered + length > _behindMeters) {
          backPoint = _lerp(
              route[back], route[back - 1], (_behindMeters - covered) / length);
          break;
        }
        covered += length;
        backPoint = route[--back];
      }
      var front = nearest;
      var frontPoint = route[nearest];
      covered = 0;
      while (front < route.length - 1 && covered < _aheadMeters) {
        final length = route[front].distanceTo(route[front + 1]);
        if (covered + length > _aheadMeters) {
          frontPoint = _lerp(route[front], route[front + 1],
              (_aheadMeters - covered) / length);
          break;
        }
        covered += length;
        frontPoint = route[++front];
      }
      final window = <LatLng>[
        backPoint,
        for (var i = back; i <= front; i++) route[i],
        frontPoint,
      ];
      include(window.first);
      var indexed = 0;
      for (var i = 1; i < window.length; i++) {
        final a = window[i - 1];
        final b = window[i];
        final distance = a.distanceTo(b);
        final samples = (distance / 150).ceil().clamp(1, 10000);
        for (var j = 1; j <= samples; j++) {
          if (generation != _prefetchGeneration) return;
          final t = j / samples;
          include(LatLng(a.latitude + (b.latitude - a.latitude) * t,
              a.longitude + (b.longitude - a.longitude) * t));
          if (++indexed % 100 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
      }

      // Drop tiles behind the rolling window. Already loaded tiles in the
      // overlap remain available while the new section downloads.
      _routeTiles.removeWhere((id, _) => !corridor.containsKey(id));
      _cacheVersion++;

      // The junctions around the rider matter before distant road context.
      // Keep only a few requests in flight; each completed tile publishes
      // independently so a slow tile cannot block the nearest one.
      final immediate =
          _tilesFor(_BoundingBox.around(position, _radiusMeters)).toSet();
      final ordered = corridor.keys.toList()
        ..sort((a, b) {
          final aImmediate = immediate.contains(a);
          final bImmediate = immediate.contains(b);
          if (aImmediate != bImmediate) return aImmediate ? -1 : 1;
          return tileAnchors[a]!
              .distanceTo(position)
              .compareTo(tileAnchors[b]!.distanceTo(position));
        });
      var next = 0;
      Future<void> worker() async {
        while (generation == _prefetchGeneration && next < ordered.length) {
          final id = ordered[next++];
          try {
            final roads = await _loadTile(id);
            if (generation != _prefetchGeneration) return;
            _routeTiles[id] = roads
                .where(
                    (road) => corridor[id]!.any((box) => box.intersects(road)))
                .toList(growable: false);
            _cacheVersion++;
            onProgress(tileAnchors[id]!);
          } on Object catch (error) {
            if (kDebugMode) {
              debugPrint('[SIDE_ROADS] route tile $id failed: $error');
            }
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < math.min(_maxConcurrentTiles, ordered.length); i++)
          worker(),
      ]);
    }());
  }

  @override
  List<RoadSegment> cachedSideRoadsNear(LatLng position) {
    final box = _BoundingBox.around(position, _radiusMeters);
    final nearby = <RoadSegment>[];
    final seen = <String>{};
    for (final id in _tilesFor(box)) {
      for (final road in _routeTiles[id] ?? const <RoadSegment>[]) {
        if (!box.intersects(road)) continue;
        final a = _pointKey(road.start);
        final b = _pointKey(road.end);
        if (seen.add(a.compareTo(b) < 0 ? '$a:$b' : '$b:$a')) {
          nearby.add(road);
        }
      }
    }
    nearby.sort((a, b) => _distanceToSegment(position, a)
        .compareTo(_distanceToSegment(position, b)));
    return nearby.take(_maxSegments).toList(growable: false);
  }

  @override
  void cancelPrefetch() {
    _prefetchGeneration++;
    _route = const [];
    _onProgress = null;
    _windowOrigin = null;
    _routeTiles.clear();
    _cacheVersion++;
  }

  @override
  Future<List<RoadSegment>> fetchSideRoadsNear(LatLng position) async {
    final box = _BoundingBox.around(position, _radiusMeters);
    final ids = _tilesFor(box);
    try {
      final groups = await Future.wait(ids.map((id) async {
        try {
          return await _loadTile(id);
        } on Object catch (error) {
          if (kDebugMode) debugPrint('[SIDE_ROADS] tile $id failed: $error');
          return <RoadSegment>[];
        }
      }));
      final nearby = <RoadSegment>[];
      final seen = <String>{};
      for (final group in groups) {
        for (final road in group) {
          if (!box.intersects(road)) continue;
          // Valhalla contains both directed edges of most two-way roads.
          final a = _pointKey(road.start);
          final b = _pointKey(road.end);
          if (!seen.add(a.compareTo(b) < 0 ? '$a:$b' : '$b:$a')) continue;
          nearby.add(road);
        }
      }
      nearby.sort((a, b) => _distanceToSegment(position, a)
          .compareTo(_distanceToSegment(position, b)));
      if (kDebugMode) {
        debugPrint(
            '[SIDE_ROADS] Valhalla tiles=${ids.length} roads=${nearby.length}');
      }
      return nearby.take(_maxSegments).toList(growable: false);
    } on Object catch (error) {
      if (kDebugMode) debugPrint('[SIDE_ROADS] Valhalla tile failed: $error');
      return const [];
    }
  }

  Future<List<RoadSegment>> _loadTile(_TileId id) =>
      _tiles.putIfAbsent(id, () async {
        // The cache bounds both memory and repeat network traffic while riding.
        if (_tiles.length > 8) _tiles.remove(_tiles.keys.first);
        final request = jsonEncode({
          'tile': {'z': id.z, 'x': id.x, 'y': id.y},
          'tile_options': {
            'exclude_layers': [
              'nodes',
              'shortcuts',
              'access_restrictions',
              'incidents'
            ],
          },
          'filters': {
            'action': 'include',
            'attributes': [
              'edge.access_forward',
              'edge.access_backward',
              'edge.layer',
              'edge.bridge',
              'edge.tunnel',
            ],
          },
          'generalize': 1,
        });
        final uri = Uri.parse('$_baseUrl/tile')
            .replace(queryParameters: {'json': request});
        final response = await _client.get(uri).timeout(_timeout);
        if (response.statusCode != 200) {
          throw StateError('tile HTTP ${response.statusCode}');
        }
        return compute(_decodeRoadTile, _TilePayload(id, response.bodyBytes));
      }).catchError((Object error) {
        _tiles.remove(id); // Let a later location refresh retry.
        throw error;
      });

  static List<_TileId> _tilesFor(_BoundingBox box) {
    final west = _tileX(box.west);
    final east = _tileX(box.east);
    final north = _tileY(box.north);
    final south = _tileY(box.south);
    return [
      for (var x = west; x <= east; x++)
        for (var y = north; y <= south; y++) _TileId(_zoom, x, y),
    ];
  }

  static int _tileX(double longitude) =>
      (((longitude + 180) / 360) * (1 << _zoom)).floor();

  static int _tileY(double latitude) {
    final lat = latitude.clamp(-85.05112878, 85.05112878);
    final radians = lat * math.pi / 180;
    final tangent = math.tan(radians);
    final mercator = math.log(tangent + math.sqrt(tangent * tangent + 1));
    return ((1 - mercator / math.pi) / 2 * (1 << _zoom)).floor();
  }

  static String _pointKey(LatLng p) =>
      '${(p.latitude * 100000).round()},${(p.longitude * 100000).round()}';

  static LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );

  static double _distanceToSegment(LatLng position, RoadSegment road) =>
      math.min(position.distanceTo(road.start), position.distanceTo(road.end));

  @override
  void dispose() {
    cancelPrefetch();
    _client.close();
  }
}

List<RoadSegment> _decodeRoadTile(_TilePayload payload) {
  final tile = VectorTile.fromBytes(bytes: payload.bytes);
  final id = payload.id;
  final result = <RoadSegment>[];
  for (final layer in tile.layers) {
    if (layer.name != 'edges') continue;
    for (final feature in layer.features) {
      if (feature.type != VectorTileGeomType.LINESTRING) continue;
      final properties = feature.decodeProperties();
      final forward = _intValue(properties['access:fwd']);
      final backward = _intValue(properties['access:bwd']);
      if ((forward | backward) & SideRoadService._motorcycleAccess == 0) {
        continue;
      }
      // Do not draw a crossing road that is actually above/below the route.
      if (_intValue(properties['layer']) != 0 ||
          properties['bridge']?.boolValue == true ||
          properties['tunnel']?.boolValue == true) {
        continue;
      }
      final lines = feature.decodeLineString();
      for (final line in lines) {
        LatLng? previous;
        for (final raw in line) {
          final point = _tilePoint(id, layer.extent, raw[0], raw[1]);
          if (previous != null && previous.distanceTo(point) >= 8) {
            result.add(RoadSegment(start: previous, end: point));
          }
          previous = point;
        }
      }
    }
  }
  return result;
}

int _intValue(VectorTileValue? value) => (value?.value is num)
    ? (value!.value as num).toInt()
    : int.tryParse(value?.value.toString() ?? '') ?? 0;

LatLng _tilePoint(_TileId id, int extent, int x, int y) {
  final scale = (1 << id.z).toDouble();
  final longitude = (id.x + x / extent) / scale * 360 - 180;
  final mercatorY = math.pi * (1 - 2 * (id.y + y / extent) / scale);
  final latitude = math.atan((math.exp(mercatorY) - math.exp(-mercatorY)) / 2) *
      180 /
      math.pi;
  return LatLng(latitude, longitude);
}

class _TileId {
  const _TileId(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _TileId && z == other.z && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

class _TilePayload {
  const _TilePayload(this.id, this.bytes);
  final _TileId id;
  final Uint8List bytes;
}

class _BoundingBox {
  const _BoundingBox(this.south, this.west, this.north, this.east);
  final double south;
  final double west;
  final double north;
  final double east;

  factory _BoundingBox.around(LatLng center, double radiusMeters) {
    const latMeters = 111320.0;
    final latPad = radiusMeters / latMeters;
    final lonPad =
        radiusMeters / (latMeters * math.cos(center.latitude * math.pi / 180));
    return _BoundingBox(center.latitude - latPad, center.longitude - lonPad,
        center.latitude + latPad, center.longitude + lonPad);
  }

  bool intersects(RoadSegment road) {
    final a = road.start;
    final b = road.end;
    return math.max(a.latitude, b.latitude) >= south &&
        math.min(a.latitude, b.latitude) <= north &&
        math.max(a.longitude, b.longitude) >= west &&
        math.min(a.longitude, b.longitude) <= east;
  }
}
