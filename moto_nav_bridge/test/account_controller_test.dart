import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/account_data.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'account_test_fakes.dart';
import 'navigation_controller_test.dart'
    show FakeBle, FakePositions, FakeRoutes, FakeSideRoads, mainRoute, p0, p2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAccountBackend backend;
  late LocalAccountData local;
  late AccountController account;
  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'map_style_v1': 'satellite', 'nav_display_binding_v2': 'local-key'});
    backend = FakeAccountBackend();
    local = LocalAccountData(await SharedPreferences.getInstance());
    account = AccountController(backend, local);
    await account.initialize();
  });
  tearDown(() async {
    account.dispose();
    await backend.events.close();
  });
  test('logging in does not upload guest data and signing out restores it',
      () async {
    expect(await account.signIn('rider@example.test', 'password'), isTrue);
    expect(account.user!.id, 'user-a');
    expect(backend.uploads, 0);
    expect(local.capture().preferences['map_style'], 'standard');
    expect(await account.importGuest(), isTrue);
    expect(local.capture().preferences['map_style'], 'satellite');
    expect(backend.uploads, 0);
    expect(await account.upload(), isTrue);
    expect(backend.uploads, 1);
    expect(local.capture().revision, 1);
    await account.signOut();
    expect(account.user, isNull);
    expect(local.capture().preferences['map_style'], 'satellite');
    expect(local.preferences.getString('nav_display_binding_v2'), 'local-key');
  });
  test('cloud conflicts do not silently overwrite either copy', () async {
    await account.signIn('rider@example.test', 'password');
    backend.cloud = const AccountData(revision: 5, displayName: 'Other device');
    expect(await account.upload(), isFalse);
    expect(account.error, 'conflict');
    expect(local.capture().revision, 0);
    expect(backend.cloud.revision, 5);
    expect(await account.download(), isTrue);
    expect(local.capture().revision, 5);
  });
  test(
      'an upload response never overwrites local edits made while it was pending',
      () async {
    await account.signIn('a@example.test', 'password');
    backend.uploadGate = Completer<void>();
    final pending = account.upload();
    await pumpEventQueue();
    await local.preferences.setString(LocalAccountData.styleKey, 'hybrid');
    backend.uploadGate!.complete();
    expect(await pending, isTrue);
    expect(local.capture().preferences['map_style'], 'hybrid');
    expect(backend.cloud.preferences['map_style'], 'standard');
  });
  test(
      'a download refuses to replace settings edited after restore was requested',
      () async {
    await account.signIn('a@example.test', 'password');
    backend.pendingDownload = Completer<AccountData>();
    final pending = account.download();
    await pumpEventQueue();
    await local.preferences.setString(LocalAccountData.styleKey, 'hybrid');
    backend.pendingDownload!.complete(const AccountData(revision: 2));
    expect(await pending, isFalse);
    expect(account.error, 'local_changed');
    expect(local.capture().preferences['map_style'], 'hybrid');
  });
  test('a late cloud result cannot apply data after the session changes',
      () async {
    await account.signIn('a@example.test', 'password');
    backend.pendingDownload = Completer<AccountData>();
    final pending = account.download();
    await pumpEventQueue();
    backend.emit(null);
    backend.pendingDownload!
        .complete(const AccountData(displayName: 'Private A', revision: 10));
    expect(await pending, isFalse);
    expect(account.user, isNull);
    expect(local.activeId, isNull);
    expect(local.capture().displayName, isNot('Private A'));
  });
  test('failed account deletion leaves local data and BLE binding untouched',
      () async {
    await account.signIn('a@example.test', 'password');
    backend.fail = true;
    expect(await account.deleteAccount(), isFalse);
    expect(account.user, isNotNull);
    expect(local.activeId, 'user-a');
    expect(local.preferences.getString('nav_display_binding_v2'), 'local-key');
  });
  test(
      'successful deletion clears the account cache but not guest data or BLE keys',
      () async {
    await account.signIn('a@example.test', 'password');
    await account.importGuest();
    expect(await account.deleteAccount(), isTrue);
    expect(backend.deletions, 1);
    expect(account.user, isNull);
    expect(local.activeId, isNull);
    expect(local.preferences.containsKey('navio.account.data.user-a'), isFalse);
    expect(local.capture().preferences['map_style'], 'satellite');
  });
  test(
      'session expiry during navigation defers profile switching until the trip ends',
      () async {
    await account.signIn('a@example.test', 'password');
    final positions = FakePositions(current: p0);
    final nav = NavigationController(
        ble: FakeBle(),
        directions: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads());
    account.bindNavigation(nav);
    await nav.startNavigation(p2);
    backend.emit(null);
    await pumpEventQueue();
    expect(local.activeId, 'user-a');
    expect(account.canModify, isFalse);
    expect(await account.signIn('b@example.test', 'password'), isFalse);
    await nav.stopNavigation();
    await pumpEventQueue();
    expect(local.activeId, isNull);
    expect(account.user, isNull);
    nav.dispose();
    await positions.close();
  });
  test('switching accounts cannot reveal or upload the previous account data',
      () async {
    await account.signIn('a@example.test', 'password');
    await local.replace(const AccountData(displayName: 'Private A'));
    await account.signOut();
    backend.nextId = 'user-b';
    await account.signIn('b@example.test', 'password');
    expect(local.capture().displayName, isEmpty);
    expect(await account.upload(), isTrue);
    expect(backend.cloud.displayName, isEmpty);
  });
}
