import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/lat_lng.dart';
import '../models/route_step.dart';
import 'apple_maps_service.dart';
import 'maneuver_mapper.dart';

/// Thrown when a Directions request fails or returns no usable route.
class DirectionsException implements Exception {
  DirectionsException(this.message);
  final String message;
  @override
  String toString() => 'DirectionsException: $message';
}

/// Calls the Google Directions API and converts the response into a list of
/// [RouteStep]s already mapped to the device protocol.
class DirectionsService {
  DirectionsService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = apiKey ?? ApiConfig.googleDirectionsApiKey;

  final http.Client _client;
  final String _apiKey;
  final AppleMapsService _appleMaps = AppleMapsService();

  static const _host = 'maps.googleapis.com';
  static const _path = '/maps/api/directions/json';

  /// Fetches a driving route from [origin] to [destination].
  ///
  /// Returns the steps of the first route/leg. Throws [DirectionsException] on
  /// network errors, a missing key, or a non-OK API status.
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return _appleMaps.fetchRoute(origin: origin, destination: destination);
    }

    if (_apiKey.isEmpty) {
      throw DirectionsException(
        'Missing Google Directions API key. Pass '
        '--dart-define=GOOGLE_DIRECTIONS_API_KEY=... or set ApiConfig.',
      );
    }

    final uri = Uri.https(_host, _path, {
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'mode': 'driving',
      'key': _apiKey,
    });

    final http.Response resp;
    try {
      resp = await _client.get(uri);
    } catch (e) {
      throw DirectionsException('Network error: $e');
    }

    if (resp.statusCode != 200) {
      throw DirectionsException('HTTP ${resp.statusCode}');
    }

    return parseRouteJson(resp.body);
  }

  /// Parses a raw Directions JSON body into [RouteStep]s.
  ///
  /// Exposed (and static) so it can be unit-tested against captured fixtures
  /// without any network access.
  static List<RouteStep> parseRouteJson(String body) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      throw DirectionsException('Invalid JSON: $e');
    }

    final status = json['status'] as String? ?? 'UNKNOWN';
    if (status != 'OK') {
      final msg = json['error_message'] as String?;
      throw DirectionsException(
          'API status $status${msg == null ? '' : ': $msg'}');
    }

    final routes = json['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw DirectionsException('No routes returned');
    }

    final legs =
        (routes.first as Map<String, dynamic>)['legs'] as List<dynamic>?;
    if (legs == null || legs.isEmpty) {
      throw DirectionsException('Route has no legs');
    }

    final steps =
        (legs.first as Map<String, dynamic>)['steps'] as List<dynamic>?;
    if (steps == null || steps.isEmpty) {
      throw DirectionsException('Leg has no steps');
    }

    final result = <RouteStep>[];
    for (final raw in steps) {
      final step = raw as Map<String, dynamic>;
      final startLoc = step['start_location'] as Map<String, dynamic>;
      final endLoc = step['end_location'] as Map<String, dynamic>;
      final distance = step['distance'] as Map<String, dynamic>?;
      final maneuver = step['maneuver'] as String?;
      final polyline = step['polyline'] as Map<String, dynamic>?;
      final encodedPolyline = polyline?['points'] as String?;

      result.add(RouteStep(
        direction: ManeuverMapper.fromGoogle(maneuver),
        start: LatLng(
          (startLoc['lat'] as num).toDouble(),
          (startLoc['lng'] as num).toDouble(),
        ),
        end: LatLng(
          (endLoc['lat'] as num).toDouble(),
          (endLoc['lng'] as num).toDouble(),
        ),
        distanceMeters: (distance?['value'] as num?)?.round() ?? 0,
        geometry:
            encodedPolyline == null ? null : _decodePolyline(encodedPolyline),
        rawManeuver: maneuver,
      ));
    }
    return result;
  }

  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;

    while (index < encoded.length) {
      final latResult = _decodePolylineValue(encoded, index);
      index = latResult.nextIndex;
      latitude += latResult.delta;

      final lngResult = _decodePolylineValue(encoded, index);
      index = lngResult.nextIndex;
      longitude += lngResult.delta;

      points.add(LatLng(latitude / 1E5, longitude / 1E5));
    }

    return points;
  }

  static _PolylineValue _decodePolylineValue(String encoded, int startIndex) {
    var index = startIndex;
    var shift = 0;
    var result = 0;
    int byte;

    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < encoded.length);

    final delta = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
    return _PolylineValue(delta, index);
  }

  void dispose() => _client.close();
}

class _PolylineValue {
  const _PolylineValue(this.delta, this.nextIndex);

  final int delta;
  final int nextIndex;
}
