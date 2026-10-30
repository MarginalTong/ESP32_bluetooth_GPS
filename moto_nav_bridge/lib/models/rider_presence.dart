import 'dart:convert';
import 'dart:typed_data';
import 'lat_lng.dart';
import 'profile_avatar.dart';

class RiderPresence {
  const RiderPresence(
    this.id,
    this.location,
    this.expiresAt, {
    this.avatarId,
    this.avatarJpeg,
  });
  final String id; // Rotating public identifier, never auth.users.id.
  final LatLng location;
  final DateTime expiresAt;
  final String? avatarId;
  final Uint8List? avatarJpeg;
  RiderPresence withAvatar(Uint8List jpeg) => RiderPresence(
    id,
    location,
    expiresAt,
    avatarId: avatarId,
    avatarJpeg: jpeg,
  );
  static bool inSydney(LatLng p) =>
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude >= -34.15 &&
      p.latitude <= -33.50 &&
      p.longitude >= 150.50 &&
      p.longitude <= 151.45;
  factory RiderPresence.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final avatarId = json['avatar_id'] as String?;
    if (avatarId != null && !ProfileAvatar.validId(avatarId)) {
      throw const FormatException('Invalid avatar version');
    }
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
      avatarId: avatarId,
    );
  }
  Map<String, Object> toMap({bool includeAvatar = true}) => {
    'id': id,
    'latitude': location.latitude,
    'longitude': location.longitude,
    if (avatarId != null) 'avatar_id': avatarId!,
    if (includeAvatar && avatarJpeg != null)
      'avatar_jpeg': base64Encode(avatarJpeg!),
  };
}

class RiderSnapshot {
  const RiderSnapshot(this.riders, {this.truncated = false});
  final List<RiderPresence> riders;
  final bool truncated;
}
