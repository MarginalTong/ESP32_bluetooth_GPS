import '../models/place_result.dart';

/// Short, speakable label. Full addresses remain on the map and in saved data.
/// Australian map results usually end in "Suburb NSW 2000, Australia".
String spokenPlaceLabel(PlaceResult place, {bool includeStreet = false}) {
  final address = place.address.trim();
  final suburb = _suburb(address);
  final rawName = place.name.trim();
  final name = RegExp(r'\b(?:NSW|VIC|QLD|SA|WA|TAS|ACT|NT)\s+\d{4}\b',
              caseSensitive: false)
          .hasMatch(rawName)
      ? rawName.split(',').first.trim()
      : (rawName.isNotEmpty ? rawName : _street(address));
  final parts = <String>[name];
  if (includeStreet) {
    final street = _street(address);
    if (street.isNotEmpty && !_containsIgnoreCase(name, street)) {
      parts.add(street);
    }
  }
  if (suburb.isNotEmpty && !_containsIgnoreCase(parts.join(' '), suburb)) {
    parts.add(suburb);
  }
  return parts.where((part) => part.isNotEmpty).join(', ');
}

/// Only add a street when two candidates would otherwise sound identical.
List<String> spokenPlaceOptions(List<PlaceResult> places) {
  final short = places.map(spokenPlaceLabel).toList();
  return [
    for (var i = 0; i < places.length; i++)
      short
                  .where(
                      (label) => label.toLowerCase() == short[i].toLowerCase())
                  .length >
              1
          ? spokenPlaceLabel(places[i], includeStreet: true)
          : short[i],
  ];
}

String _suburb(String address) {
  final match = RegExp(
    r'(?:^|,\s*)([^,]+?)\s+(?:NSW|VIC|QLD|SA|WA|TAS|ACT|NT)\s+\d{4}\b',
    caseSensitive: false,
  ).firstMatch(address);
  return match?.group(1)?.trim() ?? '';
}

String _street(String address) {
  final first = address.split(',').first.trim();
  if (first.isEmpty ||
      RegExp(r'\b(?:NSW|VIC|QLD|SA|WA|TAS|ACT|NT)\s+\d{4}\b',
              caseSensitive: false)
          .hasMatch(first)) {
    return '';
  }
  return first;
}

bool _containsIgnoreCase(String text, String part) =>
    text.toLowerCase().contains(part.toLowerCase());
