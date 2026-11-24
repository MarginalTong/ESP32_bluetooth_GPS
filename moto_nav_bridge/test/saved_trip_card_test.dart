import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/ui/widgets/saved_trip_card.dart';
import 'offline_navigation_test.dart' show MemorySessions, fix;
import 'navigation_controller_test.dart'
    show FakeBle, FakeRoutes, FakeSideRoads, FakePositions, p0, p2, mainRoute;

void main() {
  testWidgets('a saved trip requires a deliberate Resume tap', (tester) async {
    final ble = FakeBle();
    final gps = FakePositions(current: p0);
    final sessions = MemorySessions();
    NavigationController create() => NavigationController(
      ble: ble,
      directions: FakeRoutes(mainRoute, throwAfterInitialRoute: true),
      location: gps,
      sideRoads: FakeSideRoads(),
      sessions: sessions,
    );
    final previous = create();
    await previous.startNavigation(p2);
    previous.dispose();
    final nav = create();
    await nav.restoreSavedNavigation();
    gps.current = fix(p0);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: nav,
        child: const MaterialApp(home: Scaffold(body: SavedTripCard())),
      ),
    );
    final text = AppText.of(tester.element(find.byType(SavedTripCard)));
    expect(nav.phase, NavPhase.idle);
    expect(ble.sent, isEmpty);
    await tester.tap(find.text(text.resumeNavigation));
    await tester.pumpAndSettle();
    expect(nav.phase, NavPhase.navigating);
    expect(nav.hasSavedTrip, isFalse);
    expect(ble.sent, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    await gps.close();
  });
}
