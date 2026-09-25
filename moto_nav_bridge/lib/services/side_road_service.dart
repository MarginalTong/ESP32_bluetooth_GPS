import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/lat_lng.dart';
import '../models/road_segment.dart';
import 'navigation_ports.dart';

class SideRoadService implements SideRoadProvider {
  SideRoadService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // Public Overpass nodes can independently be busy or rate-limit requests.
  // Try more than one instead of silently losing every side road for a trip.
  static const _endpoints = [
    'https://lz4.overpass-api.de/api/interpreter',
    'https://z.overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];
  static const _nearbyRadiusMeters = 140.0;
  static const _maxSegments = 260;
  static const _timeout = Duration(seconds: 7);

  @override
  Future<List<RoadSegment>> fetchSideRoadsNear(LatLng position) =>
      _fetchBox(_BoundingBox.around(position, _nearbyRadiusMeters));

  Future<List<RoadSegment>> _fetchBox(_BoundingBox bbox) async {
    final body = _overpassQuery(bbox);
    for (final endpoint in _endpoints) {
      try {
        // The round-robin endpoint can reject this query as HTTP 406. Direct
        // instances with an explicit JSON GET are accepted consistently.
        final uri = Uri.parse(endpoint).replace(
          queryParameters: {'data': body},
        );
        final response = await _client.get(
          uri,
          headers: const {
            'accept': 'application/json',
            'user-agent': 'MotoNavBridge/0.1',
          },
        ).timeout(_timeout);
        if (response.statusCode != 200) {
          if (kDebugMode) {
            debugPrint(
              '[SIDE_ROADS] $endpoint returned HTTP ${response.statusCode}',
            );
          }
          continue;
        }

        final roads = parseOverpassJson(response.body);
        if (kDebugMode) {
          debugPrint('[SIDE_ROADS] received ${roads.length} road segments');
        }
        if (roads.isNotEmpty) return roads;
      } on Object catch (error) {
        if (kDebugMode) debugPrint('[SIDE_ROADS] $endpoint failed: $error');
      }
    }
    if (kDebugMode) debugPrint('[SIDE_ROADS] no road data from any endpoint');
    return const [];
  }

  static List<RoadSegment> parseOverpassJson(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on Object {
      return const [];
    }

    if (decoded is! Map<String, dynamic>) return const [];
    final elements = decoded['elements'];
    if (elements is! List) return const [];

    final segments = <RoadSegment>[];
    for (final element in elements) {
      if (element is! Map) continue;
      if (element['type'] != 'way') continue;
      final tags = element['tags'];
      if (tags is! Map || !_isUsefulRoad(tags['highway'])) continue;
      final geometry = element['geometry'];
      if (geometry is! List || geometry.length < 2) continue;

      LatLng? previous;
      for (final rawPoint in geometry) {
        if (rawPoint is! Map) continue;
        final lat = rawPoint['lat'];
        final lon = rawPoint['lon'];
        if (lat is! num || lon is! num) continue;
        final point = LatLng(lat.toDouble(), lon.toDouble());
        final start = previous;
        if (start != null && start.distanceTo(point) >= 8) {
          segments.add(RoadSegment(start: start, end: point));
          if (segments.length >= _maxSegments) return segments;
        }
        previous = point;
      }
    }
    return segments;
  }

  static bool _isUsefulRoad(Object? highway) {
    if (highway is! String) return false;
    const ignored = {
      'bridleway',
      'construction',
      'corridor',
      'cycleway',
      'elevator',
      'footway',
      'path',
      'pedestrian',
      'platform',
      'proposed',
      'raceway',
      'steps',
    };
    return !ignored.contains(highway);
  }

  static String _overpassQuery(_BoundingBox bbox) => '''
[out:json][timeout:5];
(
  way[highway](${bbox.south},${bbox.west},${bbox.north},${bbox.east});
);
out tags geom;
''';

  @override
  void dispose() => _client.close();
}

class _BoundingBox {
  const _BoundingBox({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  factory _BoundingBox.around(LatLng center, double radiusMeters) =>
      _BoundingBox(
        south: center.latitude,
        west: center.longitude,
        north: center.latitude,
        east: center.longitude,
      ).padded(radiusMeters);

  _BoundingBox padded(double meters) {
    const latMeters = 111320.0;
    final centerLat = (south + north) / 2;
    final latPad = meters / latMeters;
    final lngPad = meters / (latMeters * math.cos(centerLat * math.pi / 180));
    return _BoundingBox(
      south: south - latPad,
      west: west - lngPad,
      north: north + latPad,
      east: east + lngPad,
    );
  }
}
