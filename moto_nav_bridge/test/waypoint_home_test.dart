import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/waypoint_editor_page.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'navigation_controller_test.dart' show FakePositions, FakeSideRoads;
import 'waypoint_navigation_test.dart'
    show ItineraryProvider, origin, destination, stops, first, second;

void main() {
  testWidgets(
    'home editor re-previews the reordered itinerary and Start keeps it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final ble = LayoutBle();
      final positions = FakePositions(current: origin);
      final routes = ItineraryProvider();
      final nav = NavigationController(
        ble: ble,
        directions: routes,
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
      final en = AppText.of(tester.element(find.byType(HomePage))).isEnglish;
      tester
          .widget<NavigationMap>(find.byType(NavigationMap))
          .onMapPointSelected!(destination);
      await tester.pumpAndSettle();
      await nav.previewDestination(destination, waypoints: stops);
      await tester.pumpAndSettle();
      final edit = find.text(en ? 'Edit stops (2)' : '编辑途经点（2）');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byType(WaypointEditorPage), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_downward).first);
      await tester.tap(find.text(en ? 'Done' : '完成'));
      await tester.pumpAndSettle();
      expect(routes.requests.last, [second, first]);
      final start = find.text(en ? 'Start navigation' : '开始导航');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(nav.phase, NavPhase.navigating);
      expect(routes.requests.last, [second, first]);
      expect(
        find.textContaining(en ? 'Next stop: Second' : '下一途经点: Second'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    },
  );
}
