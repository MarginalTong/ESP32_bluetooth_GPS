import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/ui/home_page.dart';
import 'package:moto_nav_bridge/ui/widgets/glass_panel.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'navigation_controller_test.dart'
    show FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0, p2;

class LayoutBle extends ChangeNotifier implements BleService {
  @override
  BleConnectionState get state => BleConnectionState.connected;
  @override
  String? get lastError => null;
  @override
  DateTime? get lastErrorAt => null;
  @override
  bool get confirmsByPower => false;
  @override
  String get diagnostics => '';
  @override
  void clearDiagnostics() {}
  @override
  NavState? get lastSent => null;
  @override
  Future<bool> send(NavState state) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final style in ['standard', 'standard_dark', 'hybrid', 'satellite']) {
    testWidgets('map settings button matches $style map', (tester) async {
      SharedPreferences.setMockInitialValues({'map_style_v1': style});
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
      final dark = style != 'standard';
      final background = tester.widget<Material>(
        find.byKey(const ValueKey('map-settings-button-background')),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.settings_outlined));
      expect(
        background.color,
        dark ? const Color(0xff121820) : isNot(const Color(0xff121820)),
      );
      expect(icon.color, dark ? Colors.white : isNull);
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    });
  }

  testWidgets('small map settings entry updates the visible map style', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
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
    final en = AppText.of(tester.element(find.byType(HomePage))).isEnglish;
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en ? 'Hybrid' : '混合'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationMap>(find.byType(NavigationMap)).mapStyle,
      'hybrid',
    );
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  testWidgets(
    'starting a trip asks nothing; the button only toggles guidance',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('moto_nav_bridge/voice');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
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
      tester
          .widget<NavigationMap>(find.byType(NavigationMap))
          .onMapPointSelected!(p2);
      await tester.pumpAndSettle();
      final text = AppText.of(tester.element(find.byType(HomePage)));
      await tester.ensureVisible(find.text(text.startNavigation));
      await tester.tap(find.text(text.startNavigation));
      await tester.pumpAndSettle();
      expect(nav.phase, NavPhase.navigating);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isNot(contains('startWake')));
      expect(calls, isNot(contains('loadVoiceCredentials')));
      expect(find.byIcon(Icons.auto_awesome_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.volume_off_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(LocalAccountData.voiceKey), isTrue);
      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(calls, contains('stop'));
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    },
  );

  testWidgets('route preview and active trip leave central map touchable', (
    tester,
  ) async {
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
    final mapRenderObject = tester.renderObject(find.byType(NavigationMap));
    void expectMapExposed() {
      final hit = tester.hitTestOnBinding(const Offset(195, 420));
      expect(hit.path.map((entry) => entry.target), contains(mapRenderObject));
    }

    expectMapExposed();
    await nav.previewDestination(p2);
    await tester.pump();
    expectMapExposed();
    await nav.startNavigation(p2);
    await tester.pump();
    expect(find.byType(GlassPanel), findsNWidgets(3));
    expect(find.byType(BackdropFilter), findsNWidgets(3));
    expectMapExposed();
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(320, 568),
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
      expect(tester.getSize(find.byType(NavigationMap)), size);
      final initialText = AppText.of(tester.element(find.byType(HomePage)));
      expect(find.text(initialText.destination), findsNothing);
      expect(tester.takeException(), isNull);
      await nav.startNavigation(p2);
      await tester.pump();
      final text = AppText.of(tester.element(find.byType(HomePage)));
      expect(find.text(text.endNavigation), findsOneWidget);
      expect(find.text(text.endAndDisconnect), findsOneWidget);
      expect(find.text(text.pauseNavigation), findsNothing);
      expect(find.text(text.resumeNavigation), findsNothing);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(NavigationMap)), size);
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      ble.dispose();
      await positions.close();
    });
  }
}
