import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/secure_auth_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  test(
      'auth sessions use device-only secure storage and a key separate from BLE',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    final memory = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String;
      switch (call.method) {
        case 'write':
          memory[key] = args['value'] as String;
          return null;
        case 'read':
          return memory[key];
        case 'delete':
          memory.remove(key);
          return null;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    const storage = SecureAuthStorage('test.supabase.co');
    await storage.initialize();
    await storage.persistSession('synthetic-session');
    expect(await storage.hasAccessToken(), isTrue);
    expect(await storage.accessToken(), 'synthetic-session');
    await storage.removePersistedSession();
    expect(await storage.hasAccessToken(), isFalse);
    const pkce = SecurePkceStorage(storage);
    await pkce.setItem(key: 'code-verifier', value: 'synthetic-code');
    expect(await pkce.getItem(key: 'code-verifier'), 'synthetic-code');
    await pkce.removeItem(key: 'code-verifier');
    for (final call in calls) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(
          args['key'],
          isIn([
            'navio.auth.session.test.supabase.co',
            'navio.auth.pkce.test.supabase.co.code-verifier'
          ]));
      expect(args['key'], isNot(contains('binding')));
      expect((args['options'] as Map)['accessibility'],
          'first_unlock_this_device');
    }
  });
}
