import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/widgets/connection_card.dart';
import 'package:moto_nav_bridge/ui/widgets/glass_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connection_card_test.dart' show ConnectingBle, WriteFailedBle;
import 'navigation_controller_test.dart'
    show FakePositions, FakeRoutes, FakeSideRoads, mainRoute, p0;

void main() {
  final compactChanges = <bool>[];

  Future<void> show(
    WidgetTester tester,
    BleService ble, {
    bool reduceMotion = false,
  }) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    compactChanges.clear();
    await tester.pumpWidget(
      ChangeNotifierProvider<BleService>.value(
        value: ble,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: ConnectionCard(
                fullWidth: 340,
                onCompactChanged: compactChanges.add,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void connect(ConnectingBle ble) {
    ble.status = BleConnectionState.connected;
    ble.notifyListeners();
  }

  // The settle timer starts on the frame that sees the connection.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(ConnectionCard.settleDelay);
    await tester.pump(ConnectionCard.resizeDuration * 2);
  }

  testWidgets('a connected display shrinks to a pill after Ready to go', (
    tester,
  ) async {
    final ble = ConnectingBle();
    await show(tester, ble);
    expect(find.text('Connecting display'), findsOneWidget);
    connect(ble);
    await tester.pump();
    expect(find.text('Ready to go'), findsOneWidget);
    expect(find.text('NAVIO'), findsNothing);
    await tester.pump(ConnectionCard.settleDelay);
    await tester.pumpAndSettle();
    expect(find.text('NAVIO'), findsOneWidget);
    expect(find.text('Ready to go'), findsNothing);
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byType(ConnectionCard),
              matching: find.byType(GlassPanel),
            ),
          )
          .width,
      lessThan(200),
    );
    expect(compactChanges.last, isTrue);
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('tapping the pill expands it for a while', (tester) async {
    final ble = ConnectingBle();
    await show(tester, ble);
    connect(ble);
    await settle(tester);
    await tester.tap(find.text('NAVIO'));
    await tester.pumpAndSettle();
    expect(find.text('Ready to go'), findsOneWidget);
    expect(compactChanges.last, isFalse);
    await tester.pump(ConnectionCard.expandedDuration);
    await tester.pumpAndSettle();
    expect(find.text('NAVIO'), findsOneWidget);
    expect(ble.status, BleConnectionState.connected, reason: 'no disconnect');
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('a disconnect brings the full card back at once', (tester) async {
    final ble = ConnectingBle();
    await show(tester, ble);
    connect(ble);
    await settle(tester);
    ble.status = BleConnectionState.disconnected;
    ble.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('NAVIO'), findsNothing);
    expect(find.text('Display disconnected'), findsOneWidget);
    // Reconnecting shows Ready to go again before shrinking.
    connect(ble);
    await tester.pump();
    expect(find.text('Ready to go'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('a problem keeps the full card even when connected', (
    tester,
  ) async {
    final ble = WriteFailedBle(status: BleConnectionState.connected);
    await show(tester, ble);
    await tester.pump(ConnectionCard.settleDelay);
    await tester.pumpAndSettle();
    expect(find.text('Display update interrupted'), findsOneWidget);
    expect(find.text('NAVIO'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('reduced motion resizes without animation', (tester) async {
    final ble = ConnectingBle();
    await show(tester, ble, reduceMotion: true);
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
      Duration.zero,
    );
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('map buttons move up beside the pill', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ble = ConnectingBle();
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
    await tester.pump(const Duration(milliseconds: 500));
    final settings = find.byKey(
      const ValueKey('map-settings-button-background'),
    );
    final before = tester.getTopLeft(settings).dy;
    connect(ble);
    await settle(tester);
    // The page moves its buttons on the frame after the card reports.
    await tester.pump(ConnectionCard.resizeDuration * 2);
    expect(tester.getTopLeft(settings).dy, closeTo(before - 80, 0.5));
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });
}
