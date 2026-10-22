import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/ui/route_preferences_page.dart';
import 'navigation_controller_test.dart'
    show FakeBle, FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0;

void main() {
  for (final en in [true, false]) {
    testWidgets('preferences are free and autosave in both languages: $en',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localeTestValue =
          Locale(en ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final positions = FakePositions(current: p0);
      final nav = NavigationController(
          ble: FakeBle(),
          directions: FakeRoutes(mainRoute),
          location: positions,
          sideRoads: FakeSideRoads());
      await tester
          .pumpWidget(MaterialApp(home: RoutePreferencesPage(nav: nav)));
      Finder toggle(String label) => find.descendant(
          of: find.ancestor(
              of: find.text(label), matching: find.byType(CupertinoListTile)),
          matching: find.byType(CupertinoSwitch));
      expect(find.text('Moto Nav Plus'), findsNothing);
      expect(find.byType(CupertinoSwitch), findsNWidgets(4));
      expect(
          tester
              .widget<CupertinoNavigationBar>(
                  find.byType(CupertinoNavigationBar))
              .transitionBetweenRoutes,
          isFalse);
      final highwayLabel = en ? 'Prefer avoiding highways' : '尽量避开高速';
      await tester.scrollUntilVisible(find.text(highwayLabel), 120);
      expect(tester.widget<CupertinoSwitch>(toggle(highwayLabel)).onChanged,
          isNotNull);
      await tester.tap(toggle(highwayLabel));
      await tester.pumpAndSettle();
      expect(
          tester.widget<CupertinoSwitch>(toggle(highwayLabel)).value, isTrue);
      final tunnelLabel = en ? 'Avoid tunnels' : '避开隧道';
      await tester.scrollUntilVisible(find.text(tunnelLabel), 120);
      expect(tester.widget<CupertinoSwitch>(toggle(tunnelLabel)).onChanged,
          isNotNull);
      await tester.tap(toggle(tunnelLabel));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoSwitch>(toggle(tunnelLabel)).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      await positions.close();
    });
  }
}
