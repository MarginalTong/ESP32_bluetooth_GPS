import 'dart:math' as math;

/// A minimal geographic coordinate used across the navigation engine, so the
/// core logic does not depend on the geolocator package's `Position` type
/// (keeps it unit-testable without plugins).
class LatLng {
  const LatLng(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// Great-circle distance to [other] in meters, via the Haversine formula.
  double distanceTo(LatLng other) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _toRad(other.latitude - latitude);
    final dLng = _toRad(other.longitude - longitude);
    final lat1 = _toRad(latitude);
    final lat2 = _toRad(other.latitude);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.sin(dLng / 2) * math.sin(dLng / 2) * math.cos(lat1) * math.cos(lat2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  @override
  String toString() =>
      'LatLng(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)})';
}
