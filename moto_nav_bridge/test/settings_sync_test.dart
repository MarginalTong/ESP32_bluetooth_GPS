import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/settings_sync_controller.dart';
import 'package:moto_nav_bridge/models/account_data.dart';
import 'package:moto_nav_bridge/models/settings_merge.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/services/settings_store.dart';
import 'account_test_fakes.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'navigation_controller_test.dart'
    show FakeBle, FakePositions, FakeRoutes, FakeSideRoads, mainRoute, p0, p2;

AccountData settings({
  int revision = 0,
  String style = 'standard',
  bool tolls = false,
  bool traffic = false,
  Map<String, PlaceResult> places = const {},
}) => AccountData(
  revision: revision,
  preferences: {
    'map_style': style,
    'avoid_tolls': tolls,
    'show_traffic': traffic,
  },
  places: places,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'three-way merge preserves unrelated changes and detects same-field conflicts',
    () {
      final base = settings();
      final result = mergeSettings(
        base,
        settings(tolls: true),
        settings(style: 'hybrid', revision: 2),
      );
      expect(result.conflicts, isEmpty);
      expect(result.data.preferences['avoid_tolls'], true);
      expect(result.data.preferences['map_style'], 'hybrid');
      final conflict = mergeSettings(
        base,
        settings(style: 'hybrid'),
        settings(style: 'satellite'),
      );
      expect(conflict.conflicts, ['map_style']);
      expect(
        mergeSettings(
          base,
          settings(style: 'hybrid', tolls: true),
          settings(style: 'satellite'),
          choice: SettingsChoice.cloud,
        ).data.preferences['avoid_tolls'],
        true,
      );
    },
  );
  test('saved places merge per slot, including deletion', () {
    const home = PlaceResult(
      name: 'Home',
      address: '',
      location: LatLng(-33, 151),
    );
    const work = PlaceResult(
      name: 'Work',
      address: '',
      location: LatLng(-34, 151),
    );
    final result = mergeSettings(
      settings(places: {'home': home}),
      settings(),
      settings(places: {'home': home, 'work': work}),
    );
    expect(result.conflicts, isEmpty);
    expect(result.data.places.keys, ['work']);
  });
  test(
    'unknown legacy copies require review when both contain different custom data',
    () {
      expect(
        mergeSettings(
          null,
          settings(style: 'hybrid'),
          settings(tolls: true),
        ).conflicts,
        isNotEmpty,
      );
      expect(
        mergeSettings(null, settings(), settings(tolls: true)).conflicts,
        isEmpty,
      );
    },
  );
  late FakeAccountBackend backend;
  late SharedPreferences prefs;
  late AccountController account;
  late SettingsSyncController sync;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    backend = FakeAccountBackend();
    account = AccountController(backend, LocalAccountData(prefs));
    await account.initialize();
    sync = SettingsSyncController(account);
  });
  tearDown(() async {
    sync.dispose();
    account.dispose();
    await backend.events.close();
  });
  Future<void> login() async {
    await account.signIn('a@example.test', 'password');
    await sync.flush();
  }

  Future<void> editStyle(String value) => SettingsStore.edit(prefs, () async {
    await prefs.setString(LocalAccountData.styleKey, value);
  });
  test(
    'login automatically restores cloud settings without uploading guest addresses',
    () async {
      const place = PlaceResult(
        name: 'Guest home',
        address: '',
        location: LatLng(-33, 151),
      );
      await account.local.replace(settings(places: {'home': place}));
      backend.cloud = settings(style: 'hybrid', revision: 4);
      await login();
      expect(account.local.capture().preferences['map_style'], 'hybrid');
      expect(account.local.capture().places, isEmpty);
      expect(backend.uploads, 0);
      expect(sync.status, SettingsSyncStatus.synced);
      await account.signOut();
      expect(account.local.capture().places['home']!.name, 'Guest home');
    },
  );
  test(
    'local edits sync automatically and baseline survives a restart',
    () async {
      await login();
      await editStyle('satellite');
      await sync.flush();
      expect(backend.cloud.preferences['map_style'], 'satellite');
      expect(sync.status, SettingsSyncStatus.synced);
      expect(
        account.local.syncBase('user-a')!.preferences['map_style'],
        'satellite',
      );
      sync.dispose();
      sync = SettingsSyncController(account);
      await sync.flush();
      expect(backend.uploads, 1);
    },
  );
  test(
    'offline changes remain local and are retried without data loss',
    () async {
      await login();
      await editStyle('hybrid');
      backend.fail = true;
      await sync.flush();
      expect(sync.status, SettingsSyncStatus.offline);
      expect(account.local.capture().preferences['map_style'], 'hybrid');
      backend.fail = false;
      await sync.flush();
      expect(backend.cloud.preferences['map_style'], 'hybrid');
      expect(sync.status, SettingsSyncStatus.synced);
    },
  );
  test(
    'conflicting fields require a choice, while independent edits survive',
    () async {
      await login();
      await editStyle('hybrid');
      await SettingsStore.edit(prefs, () async {
        await prefs.setBool(LocalAccountData.trafficKey, true);
      });
      backend.cloud = settings(style: 'satellite', revision: 1);
      await sync.flush();
      expect(sync.status, SettingsSyncStatus.conflict);
      expect(backend.uploads, 0);
      await sync.resolve(SettingsChoice.cloud);
      expect(account.local.capture().preferences['map_style'], 'satellite');
      expect(backend.cloud.preferences['show_traffic'], true);
    },
  );
  test(
    'an upload response cannot erase a newer edit made during the request',
    () async {
      await login();
      await editStyle('hybrid');
      backend.uploadGate = Completer();
      final sending = sync.flush();
      await pumpEventQueue();
      await editStyle('satellite');
      backend.uploadGate!.complete();
      await sending;
      expect(account.local.capture().preferences['map_style'], 'satellite');
      expect(sync.status, SettingsSyncStatus.pending);
      backend.uploadGate = null;
      await sync.flush();
      expect(backend.cloud.preferences['map_style'], 'satellite');
    },
  );
  test('late cloud reads cannot apply after sign-out', () async {
    await login();
    backend.pendingDownload = Completer();
    final request = sync.flush();
    await pumpEventQueue();
    await account.signOut();
    backend.pendingDownload!.complete(
      settings(style: 'satellite', revision: 5),
    );
    await request;
    expect(account.local.activeId, isNull);
    expect(account.local.capture().preferences['map_style'], 'standard');
    expect(sync.status, SettingsSyncStatus.guest);
  });
  test('queued stale page edits cannot write into another account', () async {
    await login();
    final gate = Completer<void>();
    final holding = SettingsStore.serial(prefs, () => gate.future);
    final switching = account.local.activate('user-b');
    final staleEdit = editStyle('satellite');
    final checked = expectLater(staleEdit, throwsStateError);
    gate.complete();
    await holding;
    await switching;
    await checked;
    expect(account.local.capture().preferences['map_style'], 'standard');
  });
  test('the debounce sends edits without an upload action', () async {
    await login();
    await editStyle('hybrid');
    await Future<void>.delayed(const Duration(milliseconds: 850));
    await pumpEventQueue();
    expect(backend.cloud.preferences['map_style'], 'hybrid');
    expect(sync.status, SettingsSyncStatus.synced);
  });
  test(
    'offline edits are rediscovered and uploaded after restarting sync',
    () async {
      await login();
      await editStyle('hybrid');
      backend.fail = true;
      await sync.flush();
      sync.dispose();
      backend.fail = false;
      sync = SettingsSyncController(account);
      await sync.flush();
      expect(backend.cloud.preferences['map_style'], 'hybrid');
      expect(sync.status, SettingsSyncStatus.synced);
    },
  );
  test(
    'a late queued write cannot send the previous account settings to the next user',
    () async {
      await login();
      await editStyle('hybrid');
      backend.uploadGate = Completer();
      final sending = sync.flush();
      await pumpEventQueue();
      await account.signOut();
      backend.nextId = 'user-b';
      await account.signIn('b@example.test', 'password');
      backend.uploadGate!.complete();
      await sending;
      expect(backend.uploads, 0);
      expect(account.local.capture().preferences['map_style'], 'standard');
      await sync.flush();
      expect(sync.status, SettingsSyncStatus.synced);
    },
  );
  test('backgrounding and active navigation defer cloud application', () async {
    await login();
    sync.setForeground(false);
    await editStyle('hybrid');
    await sync.flush();
    expect(backend.uploads, 0);
    sync.setForeground(true);
    final positions = FakePositions(current: p0);
    final nav = NavigationController(
      ble: FakeBle(),
      directions: FakeRoutes(mainRoute),
      location: positions,
      sideRoads: FakeSideRoads(),
    );
    account.bindNavigation(nav);
    await nav.startNavigation(p2);
    await sync.flush();
    expect(sync.status, SettingsSyncStatus.deferred);
    expect(backend.uploads, 0);
    final generation = account.localGeneration;
    await nav.stopNavigation();
    await sync.flush();
    expect(backend.cloud.preferences['map_style'], 'hybrid');
    expect(account.localGeneration, generation);
    nav.dispose();
    await positions.close();
  });
}
