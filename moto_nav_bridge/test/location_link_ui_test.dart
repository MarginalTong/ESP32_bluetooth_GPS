import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/ui/place_search_page.dart';

void main() {
  testWidgets('pasted coordinates require confirmation and return existing PlaceResult', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('moto_nav_bridge/apple_maps'),
      (call) async => call.method == 'loadSearchHistory' ? <Object>[] : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('moto_nav_bridge/apple_maps'), null));
    PlaceResult? selected;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        selected = await Navigator.push<PlaceResult>(context,
            MaterialPageRoute(builder: (_) => const PlaceSearchPage()));
      }, child: const Text('Open')),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '-33.8,151.2');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(selected, isNull);
    // Last dialog action explicitly confirms showing the destination on the map.
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await tester.pumpAndSettle();
    expect(selected?.location.latitude, -33.8);
    expect(selected?.location.longitude, 151.2);
    expect(find.byType(PlaceSearchPage), findsNothing);
  });
}
