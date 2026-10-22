import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/app_shell.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'navigation_controller_test.dart'
    show FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0;

class DeviceBle extends LayoutBle {
  String? identity = '001122334455';
  bool connected = true;
  int scans = 0;
  @override
  String? get boundIdentity => identity;
  @override
  BleConnectionState get state =>
      connected ? BleConnectionState.connected : BleConnectionState.idle;
  @override
  Future<void> refreshBinding() async {}
  @override
  Future<void> disconnect() async {
    connected = false;
    notifyListeners();
  }

  @override
  Future<void> forgetDevice() async {
    connected = false;
    identity = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #connect) {
      scans++;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  testWidgets('satellite-family map styles use a dark bottom tab bar',
      (tester) async {
    SharedPreferences.setMockInitialValues({'map_style_v1': 'hybrid'});
    final ble = DeviceBle();
    final positions = FakePositions(current: p0);
    final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads());
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<BleService>.value(value: ble),
      ChangeNotifierProvider.value(value: nav),
    ], child: const MaterialApp(home: AppShell())));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
            .backgroundColor,
        const Color(0xff121820));
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  for (final english in [true, false]) {
    testWidgets('device menus, confirmation and map retention: $english',
        (tester) async {
      tester.binding.platformDispatcher.localeTestValue =
          Locale(english ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ble = DeviceBle();
      final positions = FakePositions(current: p0);
      final nav = NavigationController(
          ble: ble,
          directions: FakeRoutes(mainRoute),
          location: positions,
          sideRoads: FakeSideRoads());
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<BleService>.value(value: ble),
        ChangeNotifierProvider.value(value: nav),
      ], child: const MaterialApp(home: AppShell())));
      await tester.pumpAndSettle();
      final original = tester.state(find.byType(HomePage));
      await tester.tap(find.text(english ? 'My devices' : '我的设备').last);
      await tester.pumpAndSettle();
      expect(find.text('NAV-001122334455'), findsOneWidget);
      await tester.tap(find.text(english ? 'Disconnect' : '断开连接'));
      await tester.pumpAndSettle();
      expect(ble.identity, isNotNull);
      expect(ble.connected, false);
      await tester.tap(find.text(english ? 'Forget device' : '忘记设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(english ? 'Cancel' : '取消'));
      await tester.pumpAndSettle();
      expect(ble.identity, isNotNull);
      await tester.tap(find.text(english ? 'Forget device' : '忘记设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(english ? 'Confirm' : '确认'));
      await tester.pumpAndSettle();
      expect(ble.identity, isNull);
      expect(ble.scans, 0);
      await tester.tap(find.text(english ? 'Change display' : '更换屏幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(english ? 'Confirm' : '确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(ble.scans, 1);
      // The new pairing sheet has a deliberate repeating halo animation.
      await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
      await tester.pumpAndSettle();
      await tester.tap(find.text(english ? 'Map' : '地图').last);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomePage)), same(original));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    });
  }
}
