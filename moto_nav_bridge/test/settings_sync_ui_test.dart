import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/avatar_controller.dart';
import 'package:moto_nav_bridge/controllers/profile_controller.dart';
import 'package:moto_nav_bridge/controllers/settings_sync_controller.dart';
import 'package:moto_nav_bridge/models/account_data.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/services/settings_store.dart';
import 'package:moto_nav_bridge/ui/account_page.dart';
import 'package:moto_nav_bridge/ui/navio_theme.dart';
import 'account_test_fakes.dart';
import 'avatar_test_fakes.dart';
import 'profile_test_fakes.dart';

void main() {
  late AccountController account;
  late AvatarController avatars;
  late ProfileController profile;
  late SettingsSyncController sync;
  late FakeAccountBackend backend;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    backend = FakeAccountBackend();
    account = AccountController(backend, LocalAccountData(prefs));
    await account.initialize();
    await account.signIn('rider@example.test', 'not-a-real-password');
    avatars = AvatarController(
      account,
      FakeAvatarBackend()..photo = sampleAvatar(),
      source: FakeAvatarSource(),
    );
    profile = ProfileController(account, FakeProfileBackend(), prefs);
    sync = SettingsSyncController(account);
    await sync.flush();
    await pumpEventQueue();
  });
  tearDown(() async {
    sync.dispose();
    profile.dispose();
    avatars.dispose();
    account.dispose();
    await backend.events.close();
  });
  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.view.reset);
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: account),
          ChangeNotifierProvider.value(value: avatars),
          ChangeNotifierProvider.value(value: profile),
          ChangeNotifierProvider.value(value: sync),
        ],
        child: MaterialApp(
          theme: NavioTheme.light(),
          darkTheme: NavioTheme.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const AccountPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'profile keeps photo actions in one sheet, name below the avatar, and no manual sync buttons',
    (tester) async {
      await show(tester);
      expect(find.text('Change photo'), findsNothing);
      expect(find.text('Remove photo'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('profile-photo-button')));
      await tester.pumpAndSettle();
      expect(find.text('Change photo'), findsOneWidget);
      expect(find.text('Remove photo'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final avatar = find.byKey(const ValueKey('profile-photo-image'));
      final name = find.byKey(const ValueKey('profile-nickname-row'));
      expect(
        tester.getTopLeft(name).dy,
        greaterThan(tester.getBottomLeft(avatar).dy),
      );
      expect(
        tester.getTopLeft(name).dy - tester.getBottomLeft(avatar).dy,
        lessThan(130),
      );
      expect(find.text('Name'), findsNothing);
      final language = tester.getCenter(find.text('Language')).dy;
      final accountLabel = tester.getBottomLeft(find.text('ACCOUNT')).dy;
      expect(language, lessThan(accountLabel));
      expect(
        tester.getTopLeft(find.text('Sign out')).dy - accountLabel,
        lessThan(24),
      );
      expect(find.text('rider@example.test'), findsOneWidget);
      expect(find.text('Upload current settings'), findsNothing);
      expect(find.text('Restore from cloud'), findsNothing);
      expect(find.text('Import guest settings'), findsNothing);
      expect(find.text('Up to date'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'only a real conflict opens explicit resolution, keeping other edits',
    (tester) async {
      await SettingsStore.edit(prefs, () async {
        await prefs.setString(LocalAccountData.styleKey, 'hybrid');
        await prefs.setString(LocalAccountData.routeKey, '{"tolls":true}');
      });
      backend.cloud = const AccountData(
        revision: 1,
        preferences: {'map_style': 'satellite'},
      );
      await sync.flush();
      await show(tester);
      await tester.ensureVisible(find.text('Settings need review'));
      await tester.tap(find.text('Settings need review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use cloud values for conflicts'));
      await tester.pumpAndSettle();
      expect(backend.cloud.preferences['map_style'], 'satellite');
      expect(backend.cloud.preferences['avoid_tolls'], true);
      expect(sync.status, SettingsSyncStatus.synced);
      expect(tester.takeException(), isNull);
    },
  );
  for (final dark in [false, true]) {
    testWidgets('compact profile supports large text in dark=$dark', (
      tester,
    ) async {
      await show(tester, dark: dark, scale: 1.6, width: 320);
      await tester.ensureVisible(find.text('Automatic sync'));
      await tester.pumpAndSettle();
      expect(find.text('Automatic sync').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
