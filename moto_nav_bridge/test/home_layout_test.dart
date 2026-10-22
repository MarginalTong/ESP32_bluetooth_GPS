import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
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
  NavState? get lastSent => null;
  @override
  Future<bool> send(NavState state) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('small map settings entry updates the visible map style',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
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
    final en = AppText.of(tester.element(find.byType(HomePage))).isEnglish;
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en ? 'Hybrid' : '混合'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationMap>(find.byType(NavigationMap)).mapStyle,
        'hybrid');
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  testWidgets('starting a trip arms wake automatically and hides manual items',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_agent_route_access_v1': true,
      'voice_wake_auto_consent_v1': true,
    });
    const channel = MethodChannel('moto_nav_bridge/voice');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'loadVoiceCredentials') {
        return {
          'endpoint': 'https://nav.williamligallery.uk/v1/voice',
          'token': 'x' * 32,
        };
      }
      if (call.method == 'startWake') return true;
      return null;
    });
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
    tester
        .widget<NavigationMap>(find.byType(NavigationMap))
        .onMapPointSelected!(p2);
    await tester.pumpAndSettle();
    final text = AppText.of(tester.element(find.byType(HomePage)));
    await tester.ensureVisible(find.text(text.startNavigation));
    await tester.tap(find.text(text.startNavigation));
    await tester.pumpAndSettle();
    expect(calls, contains('startWake'));
    expect(nav.phase, NavPhase.navigating);
    await tester.tap(find.byIcon(Icons.auto_awesome_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enable voice wake'), findsNothing);
    expect(find.textContaining('开启语音唤醒'), findsNothing);
    expect(find.textContaining('Repeat instruction'), findsNothing);
    expect(find.textContaining('重复播报指令'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    ble.dispose();
    await positions.close();
  });

  testWidgets('route preview and active trip leave central map touchable',
      (tester) async {
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
        sideRoads: FakeSideRoads());
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<BleService>.value(value: ble),
      ChangeNotifierProvider.value(value: nav),
    ], child: const MaterialApp(home: HomePage())));
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
