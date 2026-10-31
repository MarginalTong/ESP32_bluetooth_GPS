import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/profile_controller.dart';
import 'package:moto_nav_bridge/models/account_profile.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'account_test_fakes.dart';
import 'profile_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAccountBackend auth;
  late FakeProfileBackend backend;
  late SharedPreferences prefs;
  late AccountController account;
  late ProfileController profile;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    auth = FakeAccountBackend();
    account = AccountController(auth, LocalAccountData(prefs));
    await account.initialize();
    backend = FakeProfileBackend();
    profile = ProfileController(account, backend, prefs);
  });
  tearDown(() async {
    profile.dispose();
    account.dispose();
    await auth.events.close();
  });
  Future<void> login() async {
    await account.signIn('rider@example.test', 'password');
    await pumpEventQueue();
  }

  test(
    'guests cannot rename; login automatically loads the server nickname',
    () async {
      expect(profile.canEdit, false);
      expect(await profile.rename('Guest', expectedRevision: 0), false);
      expect(backend.fetches, 0);
      await login();
      expect(profile.profile!.displayName, 'NAVIO_7C2A9F10');
      expect(profile.canEdit, true);
      expect(auth.uploads, 0);
    },
  );
  test(
    'rename automatically saves without applying settings or rebuilding maps',
    () async {
      await login();
      final generation = account.localGeneration;
      expect(await profile.rename('  悉尼骑友 🏍️  ', expectedRevision: 0), true);
      expect(backend.lastActor, 'user-a');
      expect(profile.profile!.displayName, '悉尼骑友 🏍️');
      expect(profile.profile!.revision, 1);
      expect(auth.uploads, 0);
      expect(account.localGeneration, generation);
      expect(prefs.getString('navio.profile.name.user-a'), contains('悉尼骑友'));
    },
  );
  test(
    'invalid, overlong, control and bidi names never reach the server',
    () async {
      await login();
      for (final name in ['', ' ', 'x' * 33, 'a\nb', 'a\u202eb', 'a\u0001b']) {
        expect(await profile.rename(name, expectedRevision: 0), false);
        expect(profile.error, 'invalid');
      }
      expect(backend.writes, 0);
      expect(await profile.rename('🏍' * 32, expectedRevision: 0), true);
    },
  );
  test('failed rename keeps the previous profile and allows retry', () async {
    await login();
    backend.failWrite = true;
    expect(await profile.rename('New rider', expectedRevision: 0), false);
    expect(profile.profile!.displayName, 'NAVIO_7C2A9F10');
    expect(profile.error, 'unavailable');
    backend.failWrite = false;
    expect(await profile.rename('New rider', expectedRevision: 0), true);
    expect(profile.error, isNull);
  });
  test(
    'a stale rename loads cloud state without silently overwriting it',
    () async {
      await login();
      backend.profiles['user-a'] = const AccountProfile('Changed elsewhere', 1);
      expect(await profile.rename('My draft', expectedRevision: 0), false);
      expect(profile.error, 'conflict');
      expect(profile.profile!.displayName, 'Changed elsewhere');
      expect(backend.profiles['user-a']!.displayName, 'Changed elsewhere');
    },
  );
  test('late reads cannot reveal a previous account nickname', () async {
    backend.fetchGates['user-a'] = Completer();
    await login();
    await account.signOut();
    auth.nextId = 'user-b';
    await login();
    backend.fetchGates['user-a']!.complete(
      const AccountProfile('Private previous name', 7),
    );
    await pumpEventQueue();
    expect(profile.profile!.displayName, 'Second rider');
    expect(profile.busy, false);
  });
  test(
    'late writes do not rename the newly signed-in account or its cache',
    () async {
      await login();
      final epoch = profile.accountGeneration;
      backend.renameGate = Completer();
      final pending = profile.rename('Old account draft', expectedRevision: 0);
      await pumpEventQueue();
      await account.signOut();
      auth.nextId = 'user-b';
      await login();
      backend.renameGate!.complete(
        const AccountProfile('Old account draft', 1),
      );
      expect(await pending, false);
      expect(profile.profile!.displayName, 'Second rider');
      expect(profile.accountGeneration, greaterThan(epoch));
      expect(prefs.getString('navio.profile.name.user-a'), isNull);
      expect(
        prefs.getString('navio.profile.name.user-b'),
        contains('Second rider'),
      );
    },
  );
  test('restart can show the cached name while cloud is unavailable', () async {
    await login();
    backend.failFetch = true;
    final reopened = ProfileController(account, backend, prefs);
    expect(reopened.profile!.displayName, 'NAVIO_7C2A9F10');
    await pumpEventQueue();
    expect(reopened.profile!.displayName, 'NAVIO_7C2A9F10');
    expect(reopened.error, 'unavailable');
    reopened.dispose();
  });
}
