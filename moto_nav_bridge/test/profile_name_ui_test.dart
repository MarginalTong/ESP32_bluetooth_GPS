import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/profile_controller.dart';
import 'package:moto_nav_bridge/models/account_profile.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/ui/devices_page.dart';
import 'package:moto_nav_bridge/ui/profile_name_page.dart';
import 'package:moto_nav_bridge/ui/navio_theme.dart';
import 'package:moto_nav_bridge/ui/widgets/profile_avatar_view.dart';
import 'account_test_fakes.dart';
import 'profile_test_fakes.dart';
import 'device_account_entry_test.dart' show DevicePageBle;

void main() {
  late AccountController account;
  late ProfileController profile;
  late FakeAccountBackend auth;
  late FakeProfileBackend backend;
  late DevicePageBle ble;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    auth = FakeAccountBackend();
    account = AccountController(auth, LocalAccountData(prefs));
    await account.initialize();
    backend = FakeProfileBackend();
    profile = ProfileController(account, backend, prefs);
    ble = DevicePageBle();
    await account.signIn('rider@example.test', 'not-a-real-password');
    await pumpEventQueue();
  });
  tearDown(() async {
    profile.dispose();
    account.dispose();
    ble.dispose();
    await auth.events.close();
  });
  Future<void> show(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: account),
          ChangeNotifierProvider.value(value: profile),
          ChangeNotifierProvider<BleService>.value(value: ble),
        ],
        child: MaterialApp(
          theme: NavioTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: DevicesPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byType(ProfileAvatarView));
    await tester.pumpAndSettle();
    expect(find.text('Personal profile'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-nickname-row')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileNamePage), findsOneWidget);
  }

  final field = find.byKey(const ValueKey('profile-nickname-field'));

  testWidgets(
    'nickname is beside the upper-right avatar and changes automatically after editing',
    (tester) async {
      await show(tester);
      final name = find.byKey(const ValueKey('device-account-name'));
      expect(tester.widget<Text>(name).data, 'NAVIO_7C2A9F10');
      expect(
        tester.getCenter(name).dx,
        lessThan(tester.getCenter(find.byType(ProfileAvatarView)).dx),
      );
      expect(
        tester.getCenter(find.byType(ProfileAvatarView)).dx,
        greaterThan(330),
      );
      expect(tester.getCenter(name).dy, lessThan(80));
      await openEditor(tester);
      await tester.enterText(field, 'Harbour rider');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileNamePage), findsNothing);
      expect(profile.profile!.displayName, 'Harbour rider');
      expect(backend.writes, 1);
      expect(auth.uploads, 0);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(name).data, 'Harbour rider');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'invalid names do not save, and a failed save keeps the editable draft',
    (tester) async {
      await show(tester);
      await openEditor(tester);
      await tester.enterText(field, '');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(backend.writes, 0);
      expect(find.textContaining('Use 1–32'), findsOneWidget);
      backend.failWrite = true;
      await tester.enterText(field, 'Keep this draft');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoTextField>(field).controller!.text,
        'Keep this draft',
      );
      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(profile.profile!.displayName, 'NAVIO_7C2A9F10');
      backend.failWrite = false;
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(profile.profile!.displayName, 'Keep this draft');
    },
  );
  testWidgets(
    'a conflict preserves the draft until the user explicitly loads the new name',
    (tester) async {
      await show(tester);
      await openEditor(tester);
      backend.profiles['user-a'] = const AccountProfile('Other device', 1);
      await tester.enterText(field, 'My draft');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoTextField>(field).controller!.text,
        'My draft',
      );
      await tester.tap(find.text('Load latest name'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoTextField>(field).controller!.text,
        'Other device',
      );
      await tester.enterText(field, 'Reviewed name');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(profile.profile!.displayName, 'Reviewed name');
    },
  );
  testWidgets('an account switch invalidates an open profile editor', (
    tester,
  ) async {
    await show(tester);
    await openEditor(tester);
    await tester.enterText(field, 'Old draft');
    await account.signOut();
    auth.nextId = 'user-b';
    await account.signIn('second@example.test', 'not-a-real-password');
    await tester.pumpAndSettle();
    expect(find.textContaining('Your account changed'), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(field).enabled, false);
    expect(backend.writes, 0);
    expect(profile.profile!.displayName, 'Second rider');
  });
  testWidgets('long nicknames stay bounded on small screens with large type', (
    tester,
  ) async {
    backend.profiles['user-a'] = AccountProfile('A' * 32, 1);
    await profile.refresh();
    await show(tester, width: 320, scale: 1.6);
    final label = find.byKey(const ValueKey('device-account-name'));
    expect(tester.getSize(label).width, lessThanOrEqualTo(82));
    expect(tester.widget<Text>(label).overflow, TextOverflow.ellipsis);
    expect(tester.getSize(find.byType(ProfileAvatarView)), const Size(36, 36));
    expect(tester.takeException(), isNull);
  });
}
