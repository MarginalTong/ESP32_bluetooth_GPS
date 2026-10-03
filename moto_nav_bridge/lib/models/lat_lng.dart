import 'dart:math' as math;

/// A measured position; heading is GPS travel course, never compass heading.
class NavigationFix extends LatLng {
  const NavigationFix(
    super.latitude,
    super.longitude, {
    required this.heading,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
  });
  final double heading;
  final double accuracy;
  final double speed;
  final DateTime timestamp;
  bool get reliableCourse =>
      heading.isFinite &&
      heading >= 0 &&
      heading < 360 &&
      speed >= 0.5 &&
      accuracy >= 0 &&
      accuracy <= 25;
}

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
        math.sin(dLng / 2) *
            math.sin(dLng / 2) *
            math.cos(lat1) *
            math.cos(lat2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  @override
  String toString() =>
      'LatLng(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)})';
}
