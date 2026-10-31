import 'place_result.dart';

class AccountData {
  const AccountData({
    this.revision = 0,
    this.displayName = '',
    this.preferences = const {},
    this.places = const {},
  });
  final int revision;
  final String displayName;
  final Map<String, Object> preferences;
  final Map<String, PlaceResult> places;
  static const slots = ['home', 'work', 'school'];
  static const styles = ['standard', 'standard_dark', 'hybrid', 'satellite'];
  static const languages = ['system', 'en', 'zh'];
  static const boolKeys = [
    'avoid_highways',
    'avoid_tolls',
    'avoid_ferries',
    'avoid_tunnels',
    'voice_guidance',
  ];

  factory AccountData.fromCloud(Map<String, dynamic> value) {
    final revision = value['revision'];
    final name = value['display_name'];
    final prefs = value['preferences'];
    final locations = value['places'];
    if (revision is! int ||
        revision < 0 ||
        name is! String ||
        name.length > 80 ||
        prefs is! Map ||
        locations is! List ||
        locations.length > 3) {
      throw const FormatException('Invalid account data');
    }
    final cleanPrefs = <String, Object>{};
    for (final key in boolKeys) {
      final v = prefs[key];
      if (v != null && v is! bool) {
        throw const FormatException('Invalid preference');
      }
      cleanPrefs[key] = v == true;
    }
    final style = prefs['map_style'] ?? 'standard';
    if (style is! String || !styles.contains(style)) {
      throw const FormatException('Invalid map style');
    }
    cleanPrefs['map_style'] = style;
    final language = prefs['app_language'] ?? 'system';
    if (language is! String || !languages.contains(language)) {
      throw const FormatException('Invalid language');
    }
    cleanPrefs['app_language'] = language;
    final places = <String, PlaceResult>{};
    for (final location in locations) {
      if (location is! Map ||
          !slots.contains(location['slot']) ||
          places.containsKey(location['slot'])) {
        throw const FormatException('Invalid saved place');
      }
      final place = PlaceResult.fromMap(Map<Object?, Object?>.from(location));
      if (place.name.isEmpty ||
          place.name.length > 200 ||
          place.address.length > 500 ||
          !place.location.latitude.isFinite ||
          !place.location.longitude.isFinite ||
          place.location.latitude.abs() > 90 ||
          place.location.longitude.abs() > 180) {
        throw const FormatException('Invalid saved place');
      }
      places[location['slot'] as String] = place;
    }
    return AccountData(
      revision: revision,
      displayName: name,
      preferences: Map.unmodifiable(cleanPrefs),
      places: Map.unmodifiable(places),
    );
  }

  Map<String, Object> toCloud() => {
    'display_name': displayName,
    'preferences': {
      for (final key in boolKeys) key: preferences[key] == true,
      'map_style': styles.contains(preferences['map_style'])
          ? preferences['map_style']!
          : 'standard',
      'app_language': languages.contains(preferences['app_language'])
          ? preferences['app_language']!
          : 'system',
    },
    'places': [
      for (final slot in slots)
        if (places[slot] != null)
          {
            'slot': slot,
            'name': places[slot]!.name,
            'address': places[slot]!.address,
            'latitude': places[slot]!.location.latitude,
            'longitude': places[slot]!.location.longitude,
          },
    ],
  };

  Map<String, Object> toCache() => {...toCloud(), 'revision': revision};
}
