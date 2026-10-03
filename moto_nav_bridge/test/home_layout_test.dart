import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'navigation_controller_test.dart'
    show FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0, p2;

class LayoutBle extends ChangeNotifier implements BleService {
  @override
  BleConnectionState get state => BleConnectionState.connected;
  @override
  String? get lastError => null;
  @override
  NavState? get lastSent => null;
  @override
  Future<bool> send(NavState state) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(320, 568)
  ]) {
    testWidgets('full-screen map and floating panels at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ble = LayoutBle();
      final positions = FakePositions(current: p0);
      final nav = NavigationController(
          ble: ble,
          directions: FakeRoutes(mainRoute),
          location: positions,
          sideRoads: FakeSideRoads());
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<BleService>.value(value: ble),
        ChangeNotifierProvider.value(value: nav),
      ], child: const MaterialApp(home: HomePage())));
      expect(tester.getSize(find.byType(NavigationMap)), size);
      expect(tester.takeException(), isNull);
      await nav.startNavigation(p2);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(NavigationMap)), size);
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    });
  }
}
