import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/place_result.dart';

class SavedPlaces {
  static const slots = ['home', 'work', 'school'];
  static const key = 'saved_places_v1';
  Future<Map<String, PlaceResult>> load() async {
    final store = await SharedPreferences.getInstance();
    final result = <String, PlaceResult>{};
    try {
      final data = jsonDecode(store.getString(key) ?? '{}') as Map;
      for (final slot in slots) {
        try {
          final place = PlaceResult.fromMap(
              Map<Object?, Object?>.from(data[slot] as Map));
          if (place.name.isNotEmpty &&
              place.location.latitude.isFinite &&
              place.location.longitude.isFinite &&
              place.location.latitude.abs() <= 90 &&
              place.location.longitude.abs() <= 180) {
            result[slot] = place;
          }
        } catch (_) {/* Ignore only the invalid slot. */}
      }
    } catch (_) {/* No usable saved addresses. */}
    return result;
  }

  Future<void> save(String slot, PlaceResult? place) async {
    if (!slots.contains(slot)) throw ArgumentError.value(slot);
    final values = await load();
    if (place == null) {
      values.remove(slot);
    } else {
      values[slot] = place;
    }
    final store = await SharedPreferences.getInstance();
    if (!await store.setString(
        key, jsonEncode(values.map((k, v) => MapEntry(k, v.toMap()))))) {
      throw StateError('Could not save address');
    }
  }
}
