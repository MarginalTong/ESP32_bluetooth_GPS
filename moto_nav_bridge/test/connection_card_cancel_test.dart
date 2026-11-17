import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/navio_feedback.dart';
import 'package:moto_nav_bridge/ui/widgets/connection_card.dart';
import 'home_layout_test.dart' show LayoutBle;

class CancellableBle extends LayoutBle {
  CancellableBle(this.status);
  BleConnectionState status;
  int stops = 0, starts = 0;
  Completer<void>? stopGate;
  @override
  BleConnectionState get state => status;
  @override
  Future<void> disconnect() async {
    stops++;
    await stopGate?.future;
    status = BleConnectionState.disconnected;
    notifyListeners();
  }

  @override
  Future<void> connect({
    Duration timeout = const Duration(seconds: 15),
    bool resetReconnectAttempts = true,
    Future<BluetoothDevice?> Function(List<ScanResult>)? chooseDevice,
  }) async {
    starts++;
  }
}

void main() {
  Future<void> show(WidgetTester tester, CancellableBle ble) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      ChangeNotifierProvider<BleService>.value(
        value: ble,
        child: const MaterialApp(
          home: Scaffold(body: ConnectionCard(fullWidth: 340)),
        ),
      ),
    );
  }

  for (final status in [
    BleConnectionState.scanning,
    BleConnectionState.connecting,
    BleConnectionState.awaitingBoot,
  ]) {
    testWidgets(
      'home card cancels $status without starting another connection',
      (tester) async {
        final ble = CancellableBle(status);
        await show(tester, ble);
        expect(find.byTooltip('Cancel'), findsOneWidget);
        await tester.tap(find.text('Connecting display'));
        expect(ble.stops, 1);
        await tester.pumpAndSettle();
        expect(ble.stops, 1);
        expect(ble.starts, 0);
        expect(find.text('Tap to connect'), findsOneWidget);
        await tester.pump(const Duration(minutes: 1));
        expect(ble.starts, 0);
        expect(ble.state, BleConnectionState.disconnected);
        await tester.pumpWidget(const SizedBox());
        ble.dispose();
      },
    );
  }

  testWidgets(
    'Connect has stronger compression and stop cannot be double-fired',
    (tester) async {
      final ble = CancellableBle(BleConnectionState.scanning)
        ..stopGate = Completer<void>();
      await show(tester, ble);
      final press = tester.widget<NavioPressEffect>(
        find.byType(NavioPressEffect),
      );
      expect(press.pressedScale, .94);
      expect(press.releaseCurve, Curves.easeOutBack);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Connecting display')),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        .94,
      );
      await gesture.up();
      await tester.pump();
      expect(ble.stops, 1);
      await tester.tap(find.text('Connecting display'));
      await tester.pump();
      expect(ble.stops, 1);
      ble.stopGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Tap to connect'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      ble.dispose();
    },
  );
}
