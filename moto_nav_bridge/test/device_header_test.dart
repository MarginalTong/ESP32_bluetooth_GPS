import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/navio_theme.dart';
import 'package:moto_nav_bridge/ui/widgets/device_header.dart';

void main() {
  testWidgets('device header preserves connected, busy and action states', (
    tester,
  ) async {
    var taps = 0;
    Widget page({bool connected = false, bool busy = false}) => MaterialApp(
      theme: NavioTheme.light(),
      home: Scaffold(
        body: DeviceHeader(
          name: 'NAVIO',
          status: 'Status',
          connected: connected,
          busy: busy,
          connectLabel: 'Connect',
          onConnect: busy ? null : () => taps++,
        ),
      ),
    );
    await tester.pumpWidget(page());
    await tester.tap(find.text('Connect'));
    expect(taps, 1);
    await tester.pumpWidget(page(busy: true));
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(
      tester.widget<CupertinoButton>(find.byType(CupertinoButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(page(connected: true));
    expect(find.text('Connect'), findsNothing);
    expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget);
  });
}
