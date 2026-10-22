import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:moto_nav_bridge/services/ble_service.dart';
import 'package:moto_nav_bridge/ui/widgets/connection_card.dart';
import 'home_layout_test.dart' show LayoutBle;

class ConnectingBle extends LayoutBle {
  BleConnectionState status = BleConnectionState.connecting;
  @override
  BleConnectionState get state => status;
  @override
  String? get lastError => status == BleConnectionState.connected
      ? null
      : 'BLE disconnected (old error)';
}

void main() {
  for (final en in [true, false]) {
    testWidgets('connecting replaces stale error, then connected: $en',
        (tester) async {
      tester.binding.platformDispatcher.localeTestValue =
          Locale(en ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final ble = ConnectingBle();
      await tester.pumpWidget(ChangeNotifierProvider<BleService>.value(
          value: ble,
          child: const MaterialApp(home: Scaffold(body: ConnectionCard()))));
      expect(find.text(en ? 'Connecting…' : '正在连接…'), findsOneWidget);
      expect(find.textContaining('BLE disconnected'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      ble.status = BleConnectionState.connected;
      ble.notifyListeners();
      await tester.pump();
      expect(find.text(en ? 'Connecting…' : '正在连接…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      ble.dispose();
    });
  }
}
