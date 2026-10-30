import 'lat_lng.dart';

class RiderPresence {
  const RiderPresence(this.id, this.location, this.expiresAt);
  final String id; // Rotating public identifier, never auth.users.id.
  final LatLng location;
  final DateTime expiresAt;
  static bool inSydney(LatLng p) =>
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude >= -34.15 &&
      p.latitude <= -33.50 &&
      p.longitude >= 150.50 &&
      p.longitude <= 151.45;
  factory RiderPresence.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final p = LatLng(
      (json['latitude'] as num).toDouble(),
      (json['longitude'] as num).toDouble(),
    );
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) || !inSydney(p)) {
      throw const FormatException('Invalid rider marker');
    }
    return RiderPresence(
      id,
      p,
      DateTime.parse(json['expires_at'] as String).toUtc(),
    );
  }
  Map<String, Object> toMap() => {
    'id': id,
    'latitude': location.latitude,
    'longitude': location.longitude,
  };
}

class RiderSnapshot {
  const RiderSnapshot(this.riders, {this.truncated = false});
  final List<RiderPresence> riders;
  final bool truncated;
}
