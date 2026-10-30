import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/ui/account_page.dart';
import 'package:moto_nav_bridge/ui/devices_page.dart';
import 'package:moto_nav_bridge/ui/widgets/account_button.dart';
import 'package:moto_nav_bridge/ui/widgets/profile_avatar_view.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'account_test_fakes.dart';

class DevicePageBle extends LayoutBle {
  @override
  String? get boundIdentity => null;
  @override
  BleConnectionState get state => BleConnectionState.idle;
  @override
  Future<void> refreshBinding() async {}
}

void main() {
  late AccountController account;
  late FakeAccountBackend backend;
  late DevicePageBle ble;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = FakeAccountBackend();
    account = AccountController(
      backend,
      LocalAccountData(await SharedPreferences.getInstance()),
    );
    await account.initialize();
    ble = DevicePageBle();
  });
  tearDown(() async {
    account.dispose();
    ble.dispose();
    await backend.events.close();
  });
  Future<void> show(WidgetTester tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: account),
          ChangeNotifierProvider<BleService>.value(value: ble),
        ],
        child: const MaterialApp(home: Scaffold(body: DevicesPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'account entry is in the upper-right navigation bar, not a body card',
    (tester) async {
      await show(tester);
      final bar = tester.widget<CupertinoSliverNavigationBar>(
        find.byType(CupertinoSliverNavigationBar),
      );
      expect(bar.trailing, isA<AccountButton>());
      final button = find.byKey(const ValueKey('device-account-button'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getCenter(button).dx, greaterThan(330));
      expect(tester.getCenter(button).dy, lessThan(80));
      expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byType(ProfileAvatarView)), const Size(36, 36));
      expect(find.textContaining('guest use still available'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'signed-in avatar entry opens account content without debug typography',
    (tester) async {
      await account.signIn('rider@example.test', 'password');
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('device-account-button')));
      await tester.pumpAndSettle();
      expect(find.text('rider@example.test'), findsOneWidget);
      final body = find.textContaining('Cloud sync is manual');
      final style = DefaultTextStyle.of(tester.element(body)).style;
      expect(style.decoration, TextDecoration.none);
      expect(style.color, isNot(const Color(0xD0FF0000)));
      expect(tester.takeException(), isNull);
    },
  );
}
