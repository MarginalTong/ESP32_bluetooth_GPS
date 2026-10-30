import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/lat_lng.dart';
import '../models/rider_presence.dart';
import 'rider_presence_backend.dart';
import '../models/profile_avatar.dart';

class SupabaseRiderBackend implements RiderPresenceBackend, RiderAvatarBackend {
  SupabaseRiderBackend(this.client);
  final SupabaseClient? client;
  SupabaseClient get _client => client ?? (throw StateError('Unconfigured'));
  @override
  bool get available => client != null;
  @override
  String? get userId => client?.auth.currentUser?.id;
  @override
  Stream<String?> get userChanges =>
      client?.auth.onAuthStateChange.map((s) => s.session?.user.id) ??
      const Stream.empty();
  @override
  Future<String> begin() async =>
      (await _client
              .rpc('navio_begin_rider_sharing')
              .timeout(const Duration(seconds: 8)))
          as String;
  @override
  Future<void> stop(String session) async {
    await _client
        .rpc('navio_stop_rider_sharing', params: {'p_session': session})
        .timeout(const Duration(seconds: 8));
  }

  @override
  Future<bool> publish(String session, int sequence, NavigationFix fix) async =>
      (await _client
          .rpc(
            'navio_publish_rider_position',
            params: {
              'p_session': session,
              'p_sequence': sequence,
              'p_latitude': double.parse(fix.latitude.toStringAsFixed(3)),
              'p_longitude': double.parse(fix.longitude.toStringAsFixed(3)),
              'p_accuracy': fix.accuracy,
              'p_fix_at': fix.timestamp.toUtc().toIso8601String(),
            },
          )
          .timeout(const Duration(seconds: 8))) ==
      true;
  @override
  Future<RiderSnapshot> fetch() async {
    final data = Map<String, dynamic>.from(
      (await _client
              .rpc('navio_list_riders')
              .timeout(const Duration(seconds: 8)))
          as Map,
    );
    final entries = data['riders'] as List;
    if (entries.length > 500) throw const FormatException('Too many riders');
    return RiderSnapshot(
      List.unmodifiable(
        entries.map(
          (j) => RiderPresence.fromJson(Map<String, dynamic>.from(j as Map)),
        ),
      ),
      truncated: data['truncated'] == true,
    );
  }

  @override
  Future<Uint8List?> fetchAvatar(String publicId, String avatarId) async {
    final data = await _client
        .rpc(
          'navio_get_rider_avatar',
          params: {'p_public_id': publicId, 'p_avatar_id': avatarId},
        )
        .timeout(const Duration(seconds: 8));
    return data == null ? null : ProfileAvatar.decodeJpeg(data as String);
  }
}
