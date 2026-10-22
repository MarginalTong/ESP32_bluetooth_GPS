import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'display_binding.dart';

/// Where the binding JSON lives. On iOS it is the Keychain, because the
/// binding holds the key that signs every navigation write.
abstract interface class SecureStringStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class KeychainStringStore implements SecureStringStore {
  const KeychainStringStore();
  static const _channel = MethodChannel('moto_nav_bridge/display_binding');

  @override
  Future<String?> read() => _channel.invokeMethod<String>('load');

  @override
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('save', value);

  @override
  Future<void> delete() => _channel.invokeMethod<void>('clear');
}

/// Android: encrypted with a key held in the Android Keystore. If a restored
/// backup can no longer be decrypted the value is reset, which simply asks
/// for a new BOOT pairing.
class AndroidSecureStringStore implements SecureStringStore {
  const AndroidSecureStringStore();
  static const _key = 'nav_display_binding';
  static const _storage =
      FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: true));

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// Fallback for platforms with neither (desktop, tests).
class PreferencesStringStore implements SecureStringStore {
  const PreferencesStringStore();
  static const _key = 'nav_display_binding_v2';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(_key, value)) {
      throw StateError('Could not save display binding');
    }
  }

  @override
  Future<void> delete() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}

/// Loads and saves the paired display, moving any binding left in
/// SharedPreferences (where it would reach device backups) into [secure].
class DisplayBindingStore {
  DisplayBindingStore({SecureStringStore? secure})
      : _secure = secure ??
            (Platform.isIOS
                ? const KeychainStringStore()
                : Platform.isAndroid
                    ? const AndroidSecureStringStore()
                    : const PreferencesStringStore());

  final SecureStringStore _secure;

  /// Where earlier versions kept the binding.
  static const legacyPreferencesKey = 'nav_display_binding_v1';

  /// The stored binding as decoded JSON, or null when none is saved. A
  /// binding without a `key` (saved before signed packets) is returned as is
  /// so the caller can ask for a new BOOT pairing; it is never migrated.
  Future<Map<String, dynamic>?> read() async {
    final stored = await _secure.read();
    if (stored != null) return jsonDecode(stored) as Map<String, dynamic>;

    final preferences = await SharedPreferences.getInstance();
    final legacy = preferences.getString(legacyPreferencesKey);
    if (legacy == null) return null;
    final data = jsonDecode(legacy) as Map<String, dynamic>;
    // Secure copy first: if this throws, the old copy is still there.
    if (data.containsKey('key')) await _secure.write(legacy);
    if (!await preferences.remove(legacyPreferencesKey)) {
      throw StateError('Could not remove the old display binding');
    }
    return data;
  }

  Future<void> write(DisplayBinding binding) =>
      _secure.write(jsonEncode(binding.toJson()));

  Future<void> delete() async {
    await _secure.delete();
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.remove(legacyPreferencesKey)) {
      throw StateError('Could not remove the old display binding');
    }
  }
}
