import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/ui/waypoint_editor_page.dart';

const destination = PlaceResult(
  name: 'Finish',
  address: '',
  location: LatLng(.02, 0),
);
PlaceResult stop(int i) => PlaceResult(
  name: 'Stop $i',
  address: 'Address $i',
  location: LatLng(i * .001, 0),
);

void main() {
  testWidgets('Done returns reordered stops without mutating the caller', (
    tester,
  ) async {
    final original = [stop(1), stop(2)];
    List<PlaceResult>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<PlaceResult>>(
                  MaterialPageRoute(
                    builder: (_) => WaypointEditorPage(
                      destination: destination,
                      stops: original,
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(result!.map((s) => s.name), ['Stop 2', 'Stop 1']);
    expect(original.map((s) => s.name), ['Stop 1', 'Stop 2']);
  });

  testWidgets('adding, editing and removing a stop updates only the draft', (
    tester,
  ) async {
    final original = [stop(1)];
    var next = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: WaypointEditorPage(
          destination: destination,
          stops: original,
          choosePlace: (_) async => stop(next++),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(find.text('Stop 2'), findsOneWidget);
    await tester.tap(find.text('Stop 1'));
    await tester.pumpAndSettle();
    expect(find.text('Stop 3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.text('Stop 3'), findsNothing);
    expect(find.text('Stop 2'), findsOneWidget);
    expect(original.single.name, 'Stop 1');
  });

  testWidgets(
    'five-stop limit disables Add; duplicate and final locations are rejected',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WaypointEditorPage(
            destination: destination,
            stops: [for (var i = 1; i <= 5; i++) stop(i)],
          ),
        ),
      );
      await tester.scrollUntilVisible(find.byType(OutlinedButton), 300);
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WaypointEditorPage(
            key: const ValueKey('new'),
            destination: destination,
            stops: [stop(1)],
            choosePlace: (_) async => destination,
          ),
        ),
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('waypoint-1')), findsNothing);
    },
  );

  testWidgets('Back discards changes', (tester) async {
    List<PlaceResult>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<PlaceResult>>(
                  MaterialPageRoute(
                    builder: (_) => WaypointEditorPage(
                      destination: destination,
                      stops: [stop(1)],
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
