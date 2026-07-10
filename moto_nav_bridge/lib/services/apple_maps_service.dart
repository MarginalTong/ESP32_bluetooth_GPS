import 'package:flutter/services.dart';

import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/route_step.dart';

class AppleMapsException implements Exception {
  const AppleMapsException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AppleMapsService {
  static const _channel = MethodChannel('moto_nav_bridge/apple_maps');

  Future<List<PlaceResult>> search(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    try {
      final raw = await _channel
          .invokeListMethod<Object?>('searchPlaces', {'query': text});
      return (raw ?? const [])
          .map((item) => PlaceResult.fromMap(
                Map<Object?, Object?>.from(item! as Map),
              ))
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw AppleMapsException(e.message ?? '地点搜索失败');
    }
  }

  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('drivingRoute', {
        'originLatitude': origin.latitude,
        'originLongitude': origin.longitude,
        'destinationLatitude': destination.latitude,
        'destinationLongitude': destination.longitude,
      });
      final result = <RouteStep>[];
      for (final item in raw ?? const []) {
        final map = Map<Object?, Object?>.from(item! as Map);
        result.add(RouteStep(
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
          rawManeuver: map['instruction'] as String?,
        ));
      }
      if (result.isEmpty) {
        throw const AppleMapsException('没有找到可驾驶路线');
      }
      return result;
    } on PlatformException catch (e) {
      throw AppleMapsException(e.message ?? '路线规划失败');
    }
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
