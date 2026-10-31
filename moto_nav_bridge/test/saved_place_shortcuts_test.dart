import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/services/saved_places.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/place_search_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_layout_test.dart' show LayoutBle;
import 'navigation_controller_test.dart' show FakePositions, FakeSideRoads;
import 'waypoint_navigation_test.dart'
    show ItineraryProvider, origin, destination;

class DisconnectedBle extends LayoutBle {
  @override
  BleConnectionState get state => BleConnectionState.disconnected;
}

void main() {
  const home = PlaceResult(
    name: 'My flat',
    address: '1 Test St',
    location: destination,
  );
  const homeButton = ValueKey('saved-place-home');

  Future<NavigationController> open(WidgetTester tester, BleService ble) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    SharedPreferences.setMockInitialValues({
      SavedPlaces.key: jsonEncode({'home': home.toMap()}),
    });
    final nav = NavigationController(
      ble: ble,
      directions: ItineraryProvider(),
      location: FakePositions(current: origin),
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
    await tester.tap(find.text('Search place, address or business'));
    await tester.pumpAndSettle();
    return nav;
  }

  testWidgets('tapping a saved place starts navigation straight away', (
    tester,
  ) async {
    final nav = await open(tester, LayoutBle());
    expect(find.text('My flat'), findsOneWidget);
    await tester.tap(find.byKey(homeButton));
    await tester.pumpAndSettle();
    expect(find.byType(PlaceSearchPage), findsNothing);
    expect(nav.phase, NavPhase.navigating);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
  });

  testWidgets('without a connected display it previews the route instead', (
    tester,
  ) async {
    final nav = await open(tester, DisconnectedBle());
    await tester.tap(find.byKey(homeButton));
    await tester.pumpAndSettle();
    expect(find.byType(PlaceSearchPage), findsNothing);
    expect(nav.phase, isNot(NavPhase.navigating));
    expect(nav.selectedRoute, isNotNull);
  });

  testWidgets('an unset place is set up without starting a trip', (
    tester,
  ) async {
    final nav = await open(tester, LayoutBle());
    await tester.tap(find.byKey(const ValueKey('saved-place-work')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaceSearchPage), findsNWidgets(1));
    expect(find.byKey(homeButton), findsNothing);
    expect(nav.phase, isNot(NavPhase.navigating));
  });

  testWidgets('other uses of search do not offer saved places', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: PlaceSearchPage()));
    await tester.pumpAndSettle();
    expect(find.byKey(homeButton), findsNothing);
  });
}
