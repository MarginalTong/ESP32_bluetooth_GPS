import 'dart:convert';
import 'account_data.dart';
import 'place_result.dart';

enum SettingsChoice { local, cloud }

Map<String, Object?> settingsFields(AccountData data) => {
  for (final key in AccountData.boolKeys) key: data.preferences[key] == true,
  'map_style': data.preferences['map_style'] ?? 'standard',
  for (final slot in AccountData.slots)
    'place:$slot': data.places[slot] == null
        ? null
        : {
            'name': data.places[slot]!.name,
            'address': data.places[slot]!.address,
            'latitude': data.places[slot]!.location.latitude,
            'longitude': data.places[slot]!.location.longitude,
          },
};
bool _equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
bool sameSettings(AccountData a, AccountData b) =>
    _equal(settingsFields(a), settingsFields(b));

class SettingsMerge {
  const SettingsMerge(this.data, this.conflicts);
  final AccountData data;
  final List<String> conflicts;
}

/// Three-way merge each preference and each saved-place slot. An unknown legacy
/// baseline is handled conservatively when both copies contain custom data.
SettingsMerge mergeSettings(
  AccountData? base,
  AccountData local,
  AccountData cloud, {
  SettingsChoice? choice,
}) {
  final a = settingsFields(local), b = settingsFields(cloud);
  var baseline = base == null ? null : settingsFields(base);
  if (baseline == null &&
      (sameSettings(local, const AccountData()) ||
          sameSettings(cloud, const AccountData()))) {
    baseline = settingsFields(const AccountData());
  }
  final merged = <String, Object?>{}, conflicts = <String>[];
  for (final key in a.keys) {
    final localChanged = baseline == null || !_equal(a[key], baseline[key]);
    final cloudChanged = baseline == null || !_equal(b[key], baseline[key]);
    final conflict = localChanged && cloudChanged && !_equal(a[key], b[key]);
    if (conflict) conflicts.add(key);
    merged[key] = conflict
        ? (choice == SettingsChoice.cloud ? b[key] : a[key])
        : localChanged
        ? a[key]
        : b[key];
  }
  return SettingsMerge(
    AccountData(
      revision: cloud.revision,
      displayName: cloud.displayName,
      preferences: {
        for (final key in [...AccountData.boolKeys, 'map_style'])
          key: merged[key]!,
      },
      places: {
        for (final slot in AccountData.slots)
          if (merged['place:$slot'] != null)
            slot: PlaceResult.fromMap(
              Map<Object?, Object?>.from(merged['place:$slot'] as Map),
            ),
      },
    ),
    List.unmodifiable(conflicts),
  );
}
