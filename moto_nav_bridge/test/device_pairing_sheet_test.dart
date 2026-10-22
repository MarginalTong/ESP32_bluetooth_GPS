import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/device_pairing.dart';

class BootPairingBle extends ChangeNotifier implements BleService {
  final confirmation = Completer<void>();
  BleConnectionState current = BleConnectionState.idle;

  @override
  BleConnectionState get state => current;

  @override
  Future<void> connect({
    Duration timeout = const Duration(seconds: 15),
    bool resetReconnectAttempts = true,
    Future<BluetoothDevice?> Function(List<ScanResult>)? chooseDevice,
  }) async {
    current = BleConnectionState.awaitingBoot;
    notifyListeners();
    await confirmation.future;
    current = BleConnectionState.connected;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final english in [true, false]) {
    testWidgets('BOOT replaces the code and success closes the sheet: $english',
        (tester) async {
      tester.binding.platformDispatcher.localeTestValue =
          Locale(english ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final ble = BootPairingBle();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return CupertinoButton(
              onPressed: () => connectDisplay(context, ble),
              child: const Text('Open'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
          find.text(english ? 'Press BOOT on the display' : '请按屏幕上的 BOOT 按钮'),
          findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      ble.confirmation.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.xmark_circle_fill), findsNothing);
      ble.dispose();
    });
  }
}
