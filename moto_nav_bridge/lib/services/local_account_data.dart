import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/account_data.dart';
import '../models/place_result.dart';

/// Existing navigation widgets keep their local keys. Account activation swaps
/// only this explicit allowlist; BLE keys, history and live navigation stay out.
class LocalAccountData {
  LocalAccountData(this.preferences);
  final SharedPreferences preferences;
  static const activeKey = 'navio.account.active';
  static const journalKey = 'navio.account.switch_journal';
  static const routeKey = 'route_preferences_test_v1';
  static const placesKey = 'saved_places_v1';
  static const styleKey = 'map_style_v1';
  static const trafficKey = 'map_traffic_v1';
  static const nameKey = 'navio.account.display_name';
  static const revisionKey = 'navio.account.revision';
  String? get activeId => preferences.getString(activeKey);
  String _cacheKey(String? id) {
    if (id != null && !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('Invalid account ID');
    }
    return 'navio.account.data.${id ?? "guest"}';
  }

  Future<void> _check(Future<bool> operation) async {
    if (!await operation) throw const AccountLocalFailure();
  }

  AccountData capture() {
    Map<String, dynamic> read(String key) {
      try {
        return jsonDecode(preferences.getString(key) ?? '{}')
            as Map<String, dynamic>;
      } catch (_) {
        return {};
      }
    }

    final prefs = read(routeKey), places = read(placesKey);
    final values = <String, PlaceResult>{};
    for (final slot in AccountData.slots) {
      try {
        final p = PlaceResult.fromMap(
            Map<Object?, Object?>.from(places[slot] as Map));
        AccountData.fromCloud({
          'revision': 0,
          'display_name': '',
          'preferences': {},
          'places': [
            {...p.toMap(), 'slot': slot}
          ]
        });
        values[slot] = p;
      } catch (_) {/* Preserve valid slots independently. */}
    }
    return AccountData(
        revision: preferences.getInt(revisionKey) ?? 0,
        displayName: preferences.getString(nameKey) ?? '',
        places: values,
        preferences: {
          'avoid_highways': prefs['highways'] == true,
          'avoid_tolls': prefs['tolls'] == true,
          'avoid_ferries': prefs['ferries'] == true,
          'avoid_tunnels': prefs['tunnels'] == true,
          'map_style': preferences.getString(styleKey) ?? 'standard',
          'show_traffic': preferences.getBool(trafficKey) ?? false,
        });
  }

  AccountData cached(String? id) {
    final raw = preferences.getString(_cacheKey(id));
    if (raw == null) return const AccountData();
    return AccountData.fromCloud(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> _apply(AccountData data) async {
    final p = data.preferences;
    await _check(preferences.setString(
        routeKey,
        jsonEncode({
          'highways': p['avoid_highways'] == true,
          'tolls': p['avoid_tolls'] == true,
          'ferries': p['avoid_ferries'] == true,
          'tunnels': p['avoid_tunnels'] == true,
        })));
    await _check(preferences.setString(placesKey,
        jsonEncode(data.places.map((k, v) => MapEntry(k, v.toMap())))));
    await _check(preferences.setString(
        styleKey, p['map_style'] as String? ?? 'standard'));
    await _check(preferences.setBool(trafficKey, p['show_traffic'] == true));
    await _check(preferences.setString(nameKey, data.displayName));
    await _check(preferences.setInt(revisionKey, data.revision));
  }

  Future<void> recover() async {
    final raw = preferences.getString(journalKey);
    if (raw == null) return;
    final journal = jsonDecode(raw) as Map<String, dynamic>;
    await _apply(
        AccountData.fromCloud(journal['data'] as Map<String, dynamic>));
    final id = journal['id'] as String?;
    await _check(id == null
        ? preferences.remove(activeKey)
        : preferences.setString(activeKey, id));
    await _check(preferences.remove(journalKey));
  }

  Future<void> activate(String? id, {bool erasePrevious = false}) async {
    _cacheKey(id); // Validate before touching storage.
    if (id == activeId && !erasePrevious) return;
    final previous = activeId;
    if (!erasePrevious) {
      await _check(preferences.setString(
          _cacheKey(previous), jsonEncode(capture().toCache())));
    }
    await replace(cached(id), accountId: id, changeAccount: true);
    if (erasePrevious && previous != null) {
      await _check(preferences.remove(_cacheKey(previous)));
    }
  }

  Future<void> replace(AccountData data,
      {String? accountId, bool changeAccount = false}) async {
    // Validate the entire response before changing any local key.
    final validated = AccountData.fromCloud(data.toCache());
    final before = capture();
    final oldId = activeId;
    final target = changeAccount ? accountId : activeId;
    await _check(preferences.setString(
        journalKey, jsonEncode({'id': oldId, 'data': before.toCache()})));
    try {
      await _apply(validated);
      await _check(target == null
          ? preferences.remove(activeKey)
          : preferences.setString(activeKey, target));
      await _check(preferences.setString(
          _cacheKey(target), jsonEncode(validated.toCache())));
      await _check(preferences.remove(journalKey));
    } catch (_) {
      await recover();
      rethrow;
    }
  }
}

class AccountLocalFailure implements Exception {
  const AccountLocalFailure();
}
