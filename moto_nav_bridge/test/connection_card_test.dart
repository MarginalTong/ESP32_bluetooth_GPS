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

class IdleBle extends LayoutBle {
  @override
  BleConnectionState get state => BleConnectionState.idle;
}

class WriteFailedBle extends LayoutBle {
  WriteFailedBle({this.at, this.status = BleConnectionState.disconnected});
  final DateTime? at;
  final BleConnectionState status;

  @override
  BleConnectionState get state => status;

  @override
  String? get lastError =>
      'Write failed: FlutterBluePlusException: internal details';

  @override
  DateTime? get lastErrorAt => at;
}

void main() {
  testWidgets('home card explains a write failure without showing raw BLE error',
      (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final ble = WriteFailedBle();
    await tester.pumpWidget(ChangeNotifierProvider<BleService>.value(
        value: ble,
        child: const MaterialApp(home: Scaffold(body: ConnectionCard()))));
    expect(find.text('Display update interrupted'), findsOneWidget);
    expect(find.text('Reconnect the display'), findsOneWidget);
    expect(find.textContaining('FlutterBluePlusException'), findsNothing);
    expect(find.text('Ready to go'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  testWidgets('an old write failure no longer reads as a broken link',
      (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final ble = WriteFailedBle(
        at: DateTime.now().subtract(const Duration(minutes: 2)),
        status: BleConnectionState.connected);
    await tester.pumpWidget(ChangeNotifierProvider<BleService>.value(
        value: ble,
        child: const MaterialApp(home: Scaffold(body: ConnectionCard()))));
    expect(find.text('Display update interrupted'), findsNothing);
    expect(find.text('Ready to go'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ble.dispose();
  });

  for (final en in [true, false]) {
    testWidgets('an unconnected display asks to be tapped, not ready: $en',
        (tester) async {
      tester.binding.platformDispatcher.localeTestValue =
          Locale(en ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final ble = IdleBle();
      await tester.pumpWidget(ChangeNotifierProvider<BleService>.value(
          value: ble,
          child: const MaterialApp(home: Scaffold(body: ConnectionCard()))));
      expect(find.text(en ? 'Tap to connect' : '点按连接导航屏'), findsOneWidget);
      expect(find.text(en ? 'Display not connected' : '导航屏未连接'),
          findsOneWidget);
      expect(find.text(en ? 'Ready to go' : '准备出发'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      ble.dispose();
    });
  }

  test('a write failure is recent for 30 s; an unknown time counts as recent',
      () {
    final now = DateTime.now();
    const error = 'Write failed: timeout';
    expect(BleService.isRecentWriteFailure(error, null, now), isTrue);
    expect(
        BleService.isRecentWriteFailure(
            error, now.subtract(const Duration(seconds: 29)), now),
        isTrue);
    expect(
        BleService.isRecentWriteFailure(
            error, now.subtract(const Duration(seconds: 30)), now),
        isFalse);
    expect(BleService.isRecentWriteFailure('Connect failed: x', null, now),
        isFalse);
  });

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
      expect(find.text(en ? 'Connecting display' : '正在连接导航屏'), findsOneWidget);
      expect(find.text(en ? 'Ready to go' : '准备出发'), findsNothing);
      expect(find.textContaining('BLE disconnected'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      ble.status = BleConnectionState.connected;
      ble.notifyListeners();
      await tester.pump();
      expect(find.text(en ? 'Connecting…' : '正在连接…'), findsNothing);
      expect(find.text(en ? 'Ready to go' : '准备出发'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      ble.dispose();
    });
  }
}
