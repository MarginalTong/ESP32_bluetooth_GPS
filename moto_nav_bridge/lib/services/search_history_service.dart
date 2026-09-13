import 'package:flutter/services.dart';

import '../models/place_result.dart';

class SearchHistoryService {
  SearchHistoryService({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  static const int maxItems = 10;
  static const _defaultChannel = MethodChannel('moto_nav_bridge/apple_maps');

  final MethodChannel _channel;

  Future<List<PlaceResult>> load() async {
    final raw = await _channel.invokeListMethod<Object?>(
          'loadSearchHistory',
          const <String, Object>{},
        ) ??
        const [];

    return raw
        .map((item) => PlaceResult.fromMap(Map<Object?, Object?>.from(
              item! as Map,
            )))
        .toList(growable: false);
  }

  Future<void> save(PlaceResult place) async {
    await _channel.invokeMethod<void>('saveSearchHistory', {
      'place': place.toMap(),
      'limit': maxItems,
    });
  }

  Future<void> clear() async {
    await _channel.invokeMethod<void>(
      'clearSearchHistory',
      const <String, Object>{},
    );
  }
}
