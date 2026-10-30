import 'dart:convert';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/profile_avatar.dart';

abstract interface class AvatarBackend {
  Future<ProfileAvatar?> fetchOwn();
  Future<ProfileAvatar> upload(String expectedUser, Uint8List jpeg);
  Future<void> remove(String expectedUser);
}

class SupabaseAvatarBackend implements AvatarBackend {
  SupabaseAvatarBackend(this.client);
  final SupabaseClient? client;
  SupabaseClient get _client => client ?? (throw StateError('Unconfigured'));
  @override
  Future<ProfileAvatar?> fetchOwn() async {
    final data = await _client
        .rpc('navio_get_profile_avatar')
        .timeout(const Duration(seconds: 10));
    return data == null
        ? null
        : ProfileAvatar.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<ProfileAvatar> upload(String expectedUser, Uint8List jpeg) async {
    ProfileAvatar.validateJpeg(jpeg);
    final version = await _client
        .rpc(
          'navio_set_profile_avatar',
          params: {
            'p_expected_user': expectedUser,
            'p_jpeg_base64': base64Encode(jpeg),
          },
        )
        .timeout(const Duration(seconds: 10));
    return ProfileAvatar(version as String, jpeg);
  }

  @override
  Future<void> remove(String expectedUser) async {
    await _client
        .rpc(
          'navio_remove_profile_avatar',
          params: {'p_expected_user': expectedUser},
        )
        .timeout(const Duration(seconds: 10));
  }
}
