import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'navigation_controller_test.dart'
    show FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0, p2;

class ChangingLink extends LayoutBle {
  BleConnectionState value = BleConnectionState.connected;
  @override
  BleConnectionState get state => value;
  void change(BleConnectionState next) {
    value = next;
    notifyListeners();
  }
}

void main() {
  testWidgets('BLE loss and GPS faults preserve the same home map instance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final ble = ChangingLink();
    final gps = FakePositions(current: p0);
    final nav = NavigationController(
      ble: ble,
      directions: FakeRoutes(mainRoute),
      location: gps,
      sideRoads: FakeSideRoads(),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BleService>.value(value: ble),
          ChangeNotifierProvider.value(value: nav),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await nav.startNavigation(p2);
    gps.emit(p0);
    await tester.pump();
    final map = tester.state(find.byType(NavigationMap));
    final route = nav.selectedRoute;
    for (final state in [
      BleConnectionState.disconnected,
      BleConnectionState.connecting,
      BleConnectionState.connected,
    ]) {
      ble.change(state);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.state(find.byType(NavigationMap)), same(map));
      expect(nav.selectedRoute, same(route));
      expect(nav.phase, NavPhase.navigating);
    }
    gps.fail();
    await tester.pump();
    expect(tester.state(find.byType(NavigationMap)), same(map));
    expect(nav.selectedRoute, same(route));
    expect(nav.phase, NavPhase.navigating);
    expect(find.byIcon(Icons.gps_off_rounded), findsOneWidget);
    final text = AppText.of(tester.element(find.byType(HomePage)));
    expect(find.text(text.gpsSignalLost), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await gps.close();
  });
}
