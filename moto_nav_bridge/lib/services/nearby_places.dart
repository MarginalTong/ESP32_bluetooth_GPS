import '../models/lat_lng.dart';
import '../models/place_result.dart';

/// Map search is not exhaustive. Rank only bounded, brand-matching candidates.
List<PlaceResult> nearbyCandidates(
    List<PlaceResult> places, LatLng origin, String brand) {
  final normalized = brand.trim().toLowerCase();
  final pattern = RegExp(
      r'(^|[^a-z0-9])' + RegExp.escape(normalized) + r'($|[^a-z0-9])',
      caseSensitive: false);
  final result = <PlaceResult>[];
  for (final place in places) {
    if (!place.location.latitude.isFinite ||
        !place.location.longitude.isFinite ||
        place.location.latitude.abs() > 90 ||
        place.location.longitude.abs() > 180 ||
        place.name.trim().isEmpty ||
        origin.distanceTo(place.location) > 15000) {
      continue;
    }
    if (normalized.isNotEmpty && !pattern.hasMatch(place.name)) continue;
    if (result.any((p) => p.location.distanceTo(place.location) < 30)) continue;
    result.add(place);
  }
  result.sort((a, b) =>
      origin.distanceTo(a.location).compareTo(origin.distanceTo(b.location)));
  return result.take(5).toList();
}

class NearbyChoice {
  const NearbyChoice(this.place, this.seconds);
  final PlaceResult place;
  final int seconds;
}
