import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/place_search_page.dart';

void main() {
  testWidgets('search focuses only after entrance and can close mid-transition',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: const Scaffold(),
    ));
    void open() => navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const PlaceSearchPage(),
        ));
    open();
    await tester.pump();
    final focus = tester
        .widget<TextField>(find.byType(TextField, skipOffstage: false))
        .focusNode!;
    expect(focus.hasFocus, false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(focus.hasFocus, false);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, true);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    open();
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PlaceSearchPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
