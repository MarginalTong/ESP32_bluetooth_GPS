import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Deliberately replaces the SDK's SharedPreferences default. Distinct from
/// the BLE signing key; signing out must never delete the device binding.
class SecureAuthStorage extends LocalStorage {
  const SecureAuthStorage(
    this.project, {
    this.storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      aOptions: AndroidOptions(resetOnError: true),
    ),
  });
  final String project;
  final FlutterSecureStorage storage;
  String get key => 'navio.auth.session.$project';
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> accessToken() => storage.read(key: key);
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => storage.delete(key: key);
}

/// Recovery/PKCE verifiers are credentials too; never leave them in the SDK's
/// default preferences adapter when sessions use custom secure storage.
class SecurePkceStorage extends GotrueAsyncStorage {
  const SecurePkceStorage(this.sessions);
  final SecureAuthStorage sessions;
  String _key(String key) => 'navio.auth.pkce.${sessions.project}.$key';
  @override
  Future<String?> getItem({required String key}) =>
      sessions.storage.read(key: _key(key));
  @override
  Future<void> setItem({required String key, required String value}) =>
      sessions.storage.write(key: _key(key), value: value);
  @override
  Future<void> removeItem({required String key}) =>
      sessions.storage.delete(key: _key(key));
}
