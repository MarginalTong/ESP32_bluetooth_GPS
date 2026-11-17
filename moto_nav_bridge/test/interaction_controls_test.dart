import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/services/interaction_haptics.dart';
import 'package:moto_nav_bridge/ui/app_shell.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/map_settings_page.dart';
import 'package:moto_nav_bridge/ui/navio_feedback.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_controls.dart';
import 'package:moto_nav_bridge/ui/widgets/map_control_button.dart';
import 'devices_page_test.dart' show DeviceBle;
import 'navigation_controller_test.dart'
    show FakePositions, FakeRoutes, FakeSideRoads, mainRoute, p0;

void main() {
  var now = Duration.zero;
  final sent = <InteractionFeedback>[];
  late InteractionHaptics haptics;
  setUp(() {
    now = Duration.zero;
    sent.clear();
    haptics = InteractionHaptics(
      clock: () => now,
      driver: (kind) async => sent.add(kind),
    );
    SharedPreferences.setMockInitialValues({});
  });
  Widget page(Widget child) => NavioFeedbackScope(
    haptics: haptics,
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets(
    'map controls use light feedback, disabled trip controls stay quiet',
    (tester) async {
      var maps = 0, stops = 0;
      await tester.pumpWidget(
        page(
          MapControlButton(
            dark: true,
            icon: Icons.settings,
            tooltip: 'Settings',
            minSize: 24,
            onPressed: () => maps++,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(IconButton)).width,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();
      expect(maps, 1);
      expect(sent, [InteractionFeedback.light]);
      now += InteractionHaptics.minimumInterval;
      Widget controls(NavPhase phase) => NavigationControls(
        phase: phase,
        error: null,
        onEnd: () => stops++,
        onEndAndDisconnect: () => stops++,
      );
      await tester.pumpWidget(page(controls(NavPhase.routing)));
      await tester.tap(find.byIcon(Icons.stop_circle_rounded));
      await tester.pumpAndSettle();
      expect(stops, 0);
      expect(sent.length, 1);
      await tester.pumpWidget(page(controls(NavPhase.navigating)));
      await tester.tap(find.byIcon(Icons.stop_circle_rounded));
      await tester.pumpAndSettle();
      expect(stops, 1);
      expect(sent.last, InteractionFeedback.firm);
    },
  );

  testWidgets('tab feedback only happens on a change and keeps the map alive', (
    tester,
  ) async {
    final ble = DeviceBle();
    final positions = FakePositions(current: p0);
    final nav = NavigationController(
      ble: ble,
      directions: FakeRoutes(mainRoute),
      location: positions,
      sideRoads: FakeSideRoads(),
    );
    await tester.pumpWidget(
      NavioFeedbackScope(
        haptics: haptics,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<BleService>.value(value: ble),
            ChangeNotifierProvider.value(value: nav),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final map = tester.state(find.byType(HomePage));
    expect(sent, isEmpty);
    tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar)).onTap!(1);
    await tester.pumpAndSettle();
    tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar)).onTap!(1);
    expect(sent, [InteractionFeedback.selection]);
    now += InteractionHaptics.minimumInterval;
    tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar)).onTap!(0);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(HomePage)), same(map));
    expect(sent, [
      InteractionFeedback.selection,
      InteractionFeedback.selection,
    ]);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  testWidgets(
    'map style selection is quiet on the current style and marks the new choice',
    (tester) async {
      await tester.pumpWidget(page(const MapSettingsPage()));
      await tester.pumpAndSettle();
      final tiles = tester
          .widgetList<CupertinoListTile>(find.byType(CupertinoListTile))
          .toList();
      tiles.first.onTap!();
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      tiles[1].onTap!();
      tiles[2].onTap!(); // The stale callback must not race the first save.
      await tester.pumpAndSettle();
      expect(sent, [InteractionFeedback.selection]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(MapSettingsPage.styleKey), 'standard_dark');
      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget);
    },
  );
}
