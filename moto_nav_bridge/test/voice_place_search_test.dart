import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/place_search_page.dart';

void main() {
  testWidgets('voice query prefills search without auto-selecting a place',
      (tester) async {
    final queries = <String>[];
    const channel = MethodChannel('moto_nav_bridge/apple_maps');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'loadSearchHistory') return <Object>[];
      if (call.method == 'searchPlaces') {
        queries.add(call.arguments['query'] as String);
        return [
          {
            'name': 'Airport domestic',
            'address': 'Terminal 2',
            'latitude': -33.9,
            'longitude': 151.2
          },
          {
            'name': 'Airport international',
            'address': 'Terminal 1',
            'latitude': -33.91,
            'longitude': 151.19
          },
        ];
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(
        home: PlaceSearchPage(initialQuery: 'Sydney Airport')));
    await tester.pumpAndSettle();
    expect(queries, ['Sydney Airport']);
    expect(find.text('Airport domestic'), findsOneWidget);
    expect(find.text('Airport international'), findsOneWidget);
    expect(find.byType(PlaceSearchPage), findsOneWidget);
  });
}
