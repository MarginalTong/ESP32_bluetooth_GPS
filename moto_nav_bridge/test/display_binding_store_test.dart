import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/display_binding.dart';
import 'package:moto_nav_bridge/services/display_binding_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSecureStore implements SecureStringStore {
  String? value;
  bool failWrites = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String newValue) async {
    if (failWrites) throw PlatformException(code: 'BINDING_SAVE_FAILED');
    value = newValue;
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const legacyKey = DisplayBindingStore.legacyPreferencesKey;
  final signed = jsonEncode({
    'remote': 'phone-device-A',
    'identity': '001122334455',
    'key': '000102030405060708090a0b0c0d0e0f',
  });
  final keyless =
      jsonEncode({'remote': 'phone-device-A', 'identity': '001122334455'});

  late FakeSecureStore secure;
  late DisplayBindingStore store;

  setUp(() {
    secure = FakeSecureStore();
    store = DisplayBindingStore(secure: secure);
  });

  test('a binding left in preferences moves to secure storage', () async {
    SharedPreferences.setMockInitialValues({legacyKey: signed});
    final data = await store.read();
    expect(data?['key'], '000102030405060708090a0b0c0d0e0f');
    expect(secure.value, signed);
    expect(
        (await SharedPreferences.getInstance()).getString(legacyKey), isNull);
  });

  test('a keyless legacy binding is dropped, not migrated', () async {
    SharedPreferences.setMockInitialValues({legacyKey: keyless});
    final data = await store.read();
    expect(data?.containsKey('key'), isFalse);
    expect(secure.value, isNull);
    expect(
        (await SharedPreferences.getInstance()).getString(legacyKey), isNull);
  });

  test('a failed secure write keeps the old copy', () async {
    SharedPreferences.setMockInitialValues({legacyKey: signed});
    secure.failWrites = true;
    await expectLater(store.read(), throwsA(isA<PlatformException>()));
    expect(
        (await SharedPreferences.getInstance()).getString(legacyKey), signed);
  });

  test('secure storage wins over preferences', () async {
    SharedPreferences.setMockInitialValues({legacyKey: keyless});
    secure.value = signed;
    expect((await store.read())?['key'], isNotNull);
  });

  test('write and delete go through secure storage only', () async {
    SharedPreferences.setMockInitialValues({});
    await store.write(DisplayBinding('phone-device-A', '001122334455',
        Uint8List.fromList(List.generate(16, (i) => i))));
    expect(
        jsonDecode(secure.value!)['key'], '000102030405060708090a0b0c0d0e0f');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    await store.delete();
    expect(secure.value, isNull);
    expect(await store.read(), isNull);
  });

  test('the Keychain store speaks the native channel contract', () async {
    const channel = MethodChannel('moto_nav_bridge/display_binding');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'load' ? signed : null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    const keychain = KeychainStringStore();
    expect(await keychain.read(), signed);
    await keychain.write(signed);
    await keychain.delete();
    expect(calls.map((c) => c.method), ['load', 'save', 'clear']);
    expect(calls[1].arguments, signed);
  });
}
