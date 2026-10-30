import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/avatar_controller.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'account_test_fakes.dart';
import 'avatar_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAccountBackend auth;
  late AccountController account;
  late FakeAvatarBackend backend;
  late FakeAvatarSource source;
  late AvatarController avatars;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    auth = FakeAccountBackend();
    account = AccountController(
      auth,
      LocalAccountData(await SharedPreferences.getInstance()),
    );
    await account.initialize();
    backend = FakeAvatarBackend();
    source = FakeAvatarSource();
    avatars = AvatarController(account, backend, source: source);
  });
  tearDown(() async {
    avatars.dispose();
    account.dispose();
    await auth.events.close();
  });
  Future<void> login() async {
    await account.signIn('rider@example.test', 'password');
    await pumpEventQueue();
  }

  test(
    'guest cannot upload and a new account automatically loads its avatar',
    () async {
      expect(avatars.canEdit, isFalse);
      await avatars.choose();
      expect(backend.uploads, 0);
      backend.photo = sampleAvatar();
      await login();
      expect(avatars.avatar?.id, backend.photo?.id);
      expect(avatars.canEdit, isTrue);
    },
  );
  test('choose and remove sync independently of settings upload', () async {
    await login();
    await avatars.choose();
    expect(backend.uploads, 1);
    expect(backend.lastActor, 'user-a');
    expect(avatars.avatar, isNotNull);
    expect(auth.uploads, 0);
    await avatars.remove();
    expect(backend.removals, 1);
    expect(avatars.avatar, isNull);
  });
  test('cancelled selection does not upload or produce an error', () async {
    await login();
    source.result = null;
    await avatars.choose();
    expect(backend.uploads, 0);
    expect(avatars.error, isNull);
    expect(avatars.busy, isFalse);
  });
  test('failed replacement or removal keeps the previous image', () async {
    backend.photo = sampleAvatar();
    await login();
    final old = avatars.avatar;
    backend.fail = true;
    await avatars.choose();
    expect(avatars.avatar, same(old));
    expect(avatars.error, 'save_failed');
    await avatars.remove();
    expect(avatars.avatar, same(old));
  });
  test(
    'logout while the picker is open prevents uploading to another account',
    () async {
      await login();
      source.gate = Completer<Uint8List?>();
      final pending = avatars.choose();
      await pumpEventQueue();
      await account.signOut();
      auth.nextId = 'user-b';
      await login();
      source.gate!.complete(avatarJpeg());
      await pending;
      expect(backend.uploads, 0);
      expect(avatars.avatar, isNull);
    },
  );
  test('late avatar reads cannot reveal an image after sign out', () async {
    backend.fetchGate = Completer();
    await login();
    await account.signOut();
    backend.fetchGate!.complete(sampleAvatar());
    await pumpEventQueue();
    expect(avatars.avatar, isNull);
    expect(avatars.busy, isFalse);
  });
  test(
    'permission denial and invalid photos give actionable safe errors',
    () async {
      await login();
      source.failure = PlatformException(code: 'photo_access_denied');
      await avatars.choose();
      expect(avatars.error, 'photo_permission');
      source.failure = const FormatException('private-file-path');
      await avatars.choose();
      expect(avatars.error, 'photo_invalid');
      expect(backend.uploads, 0);
    },
  );
}
