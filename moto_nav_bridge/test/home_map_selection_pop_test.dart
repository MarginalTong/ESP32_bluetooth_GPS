import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/widgets/destination_panel.dart';
import 'package:moto_nav_bridge/ui/widgets/map_selection_pop.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'navigation_controller_test.dart'
    show FakePositions, FakeRoutes, FakeSideRoads, mainRoute, p0, p2;

void main() {
  testWidgets(
    'native map selections pop the card, not the map; route updates do not replay it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ble = LayoutBle();
      final positions = FakePositions(current: p0);
      final nav = NavigationController(
        ble: ble,
        directions: FakeRoutes(mainRoute),
        location: positions,
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
      await tester.pumpAndSettle();
      final map = tester.state(find.byType(NavigationMap));
      double scale() => tester
          .widget<ScaleTransition>(
            find
                .descendant(
                  of: find.byType(MapSelectionPop),
                  matching: find.byType(ScaleTransition),
                )
                .first,
          )
          .scale
          .value;
      expect(scale(), 1);
      tester
          .widget<NavigationMap>(find.byType(NavigationMap))
          .onMapPointSelected!(p2);
      await tester.pump();
      expect(scale(), closeTo(.78, .0001));
      await tester.pump(const Duration(milliseconds: 80));
      nav.notifyListeners();
      await tester.pump();
      expect(scale(), greaterThan(.78));
      expect(tester.state(find.byType(NavigationMap)), same(map));
      tester
          .widget<NavigationMap>(find.byType(NavigationMap))
          .onMapPointSelected!(p0);
      await tester.pump();
      expect(scale(), closeTo(.78, .0001));
      await tester.pumpAndSettle();
      expect(scale(), 1);
      expect(find.byType(DestinationPanel), findsOneWidget);
      expect(tester.state(find.byType(NavigationMap)), same(map));
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    },
  );
}
