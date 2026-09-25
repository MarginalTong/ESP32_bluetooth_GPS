import 'package:flutter/services.dart';

import '../l10n/app_text.dart';
import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';

class AppleMapsException implements Exception {
  const AppleMapsException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PlaceSuggestion {
  const PlaceSuggestion({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  String get query => [title, subtitle]
      .where((part) => part.trim().isNotEmpty)
      .join(' ')
      .trim();

  factory PlaceSuggestion.fromMap(Map<Object?, Object?> map) => PlaceSuggestion(
        title: map['title'] as String? ?? '',
        subtitle: map['subtitle'] as String? ?? '',
      );
}

class AppleMapsService {
  static const _channel = MethodChannel('moto_nav_bridge/apple_maps');

  Future<List<PlaceSuggestion>> complete(String query) async {
    final text = AppText.system;
    final queryText = query.trim();
    if (queryText.length < 2) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('completePlaces', {
        'query': queryText,
        'languageCode': text.languageCode,
      });
      return (raw ?? const [])
          .map((item) => PlaceSuggestion.fromMap(
                Map<Object?, Object?>.from(item! as Map),
              ))
          .where((item) => item.title.trim().isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw AppleMapsException(e.message ?? text.placeAutocompleteFailed);
    }
  }

  Future<List<PlaceResult>> search(String query) async {
    final text = AppText.system;
    final queryText = query.trim();
    if (queryText.isEmpty) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('searchPlaces', {
        'query': queryText,
        'languageCode': text.languageCode,
      });
      return (raw ?? const [])
          .map((item) => PlaceResult.fromMap(
                Map<Object?, Object?>.from(item! as Map),
              ))
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw AppleMapsException(e.message ?? text.placeSearchFailed);
    }
  }

  Future<PlaceResult?> resolveSuggestion(PlaceSuggestion suggestion) async {
    final query = suggestion.query;
    if (query.isEmpty) return null;
    final results = await search(query);
    return results.isEmpty ? null : results.first;
  }

  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final routes = await fetchRoutes(origin: origin, destination: destination);
    return routes.first.steps;
  }

  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final text = AppText.system;
    try {
      final raw = await _channel.invokeListMethod<Object?>('drivingRoutes', {
        'originLatitude': origin.latitude,
        'originLongitude': origin.longitude,
        'destinationLatitude': destination.latitude,
        'destinationLongitude': destination.longitude,
        'languageCode': text.languageCode,
      });
      final result = (raw ?? const [])
          .map((item) => _routeCandidateFromMap(
                Map<Object?, Object?>.from(item! as Map),
              ))
          .where((candidate) => candidate.steps.isNotEmpty)
          .toList(growable: false);
      if (result.isEmpty) {
        throw AppleMapsException(text.noDrivingRoute);
      }
      return result;
    } on PlatformException catch (e) {
      throw AppleMapsException(e.message ?? text.routePlanningFailed);
    }
  }

  RouteCandidate _routeCandidateFromMap(Map<Object?, Object?> map) {
    final steps = (map['steps'] as List<Object?>? ?? const [])
        .map((item) =>
            _routeStepFromMap(Map<Object?, Object?>.from(item! as Map)))
        .toList(growable: false);

    return RouteCandidate(
      steps: steps,
      name: map['name'] as String?,
      distanceMeters: (map['distance'] as num?)?.round(),
      expectedTravelTimeSeconds: (map['expectedTravelTime'] as num?)?.round(),
    );
  }

  RouteStep _routeStepFromMap(Map<Object?, Object?> map) {
    final coordinates =
        (map['coordinates'] as List<Object?>? ?? const []).map((item) {
      final point = Map<Object?, Object?>.from(item! as Map);
      return LatLng(
        (point['latitude'] as num).toDouble(),
        (point['longitude'] as num).toDouble(),
      );
    }).toList(growable: false);

    return RouteStep(
      direction: _direction(map['direction'] as String?),
      start: LatLng(
        (map['startLatitude'] as num).toDouble(),
        (map['startLongitude'] as num).toDouble(),
      ),
      end: LatLng(
        (map['endLatitude'] as num).toDouble(),
        (map['endLongitude'] as num).toDouble(),
      ),
      distanceMeters: (map['distance'] as num).round(),
      geometry: coordinates,
      rawManeuver: map['instruction'] as String?,
    );
  }

  DeviceDirection _direction(String? value) => switch (value) {
        'LEFT' => DeviceDirection.left,
        'RIGHT' => DeviceDirection.right,
        'BEAR_LEFT' => DeviceDirection.bearLeft,
        'BEAR_RIGHT' => DeviceDirection.bearRight,
        'UTURN' => DeviceDirection.uturn,
        _ => DeviceDirection.up,
      };
}
