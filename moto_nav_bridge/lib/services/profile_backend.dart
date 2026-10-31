import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/account_profile.dart';

abstract interface class ProfileBackend {
  Future<AccountProfile> fetch(String expectedUser);
  Future<AccountProfile> rename(
    String expectedUser,
    String name,
    int expectedRevision,
  );
}

class ProfileFailure implements Exception {
  const ProfileFailure(this.code);
  final String code;
}

class SupabaseProfileBackend implements ProfileBackend {
  SupabaseProfileBackend(this.client);
  final SupabaseClient? client;
  SupabaseClient get _client =>
      client ?? (throw const ProfileFailure('unavailable'));
  Future<AccountProfile> _call(String rpc, Map<String, Object> params) async {
    try {
      final result = await _client
          .rpc(rpc, params: params)
          .timeout(const Duration(seconds: 10));
      return AccountProfile.fromJson(Map<String, dynamic>.from(result as Map));
    } on PostgrestException catch (e) {
      throw ProfileFailure(switch (e.code) {
        'PT409' => 'conflict',
        '22023' => 'invalid',
        '42501' || '28000' => 'session',
        _ => 'unavailable',
      });
    }
  }

  @override
  Future<AccountProfile> fetch(String expectedUser) =>
      _call('navio_get_profile', {'p_expected_user': expectedUser});
  @override
  Future<AccountProfile> rename(
    String expectedUser,
    String name,
    int expectedRevision,
  ) => _call('navio_set_display_name', {
    'p_expected_user': expectedUser,
    'p_display_name': name,
    'p_expected_revision': expectedRevision,
  });
}
