import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/widgets/map_selection_pop.dart';

void main() {
  Widget page(int revision, {bool enabled = true, bool reduce = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Scaffold(
            body: Center(
              child: MapSelectionPop(
                selectionRevision: revision,
                enabled: enabled,
                child: const SizedBox(
                  width: 300,
                  height: 140,
                  child: TextField(),
                ),
              ),
            ),
          ),
        ),
      );
  double scale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find
            .descendant(
              of: find.byType(MapSelectionPop),
              matching: find.byType(ScaleTransition),
            )
            .first,
      )
      .scale
      .value;
  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .descendant(
              of: find.byType(MapSelectionPop),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  testWidgets(
    'selection grows, gently overshoots then settles, without replacing content',
    (tester) async {
      await tester.pumpWidget(page(0));
      expect(scale(tester), 1);
      final original = tester.state(find.byType(TextField));
      await tester.pumpWidget(page(1));
      expect(scale(tester), closeTo(.78, .0001));
      expect(opacity(tester), closeTo(.35, .0001));
      await tester.pump(const Duration(milliseconds: 240));
      expect(scale(tester), greaterThan(1));
      expect(scale(tester), lessThan(1.04));
      expect(opacity(tester), 1);
      await tester.pumpAndSettle();
      expect(scale(tester), 1);
      expect(tester.state(find.byType(TextField)), same(original));
    },
  );

  testWidgets(
    'ordinary rebuilds never restart, repeated selections restart one pop',
    (tester) async {
      await tester.pumpWidget(page(5));
      expect(scale(tester), 1); // Mounting a page is not a map selection.
      await tester.pumpWidget(page(6));
      await tester.pump(const Duration(milliseconds: 80));
      final progressed = scale(tester);
      await tester.pumpWidget(page(6));
      expect(scale(tester), closeTo(progressed, .0001));
      await tester.pumpWidget(page(7));
      expect(scale(tester), closeTo(.78, .0001));
      expect(find.byType(MapSelectionPop), findsOneWidget);
      await tester.pumpAndSettle();
      expect(scale(tester), 1);
    },
  );

  testWidgets('reduced motion, navigation mode and disposal cancel cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(page(0));
    await tester.pumpWidget(page(1, reduce: true));
    expect(scale(tester), 1);
    expect(opacity(tester), 1);
    await tester.pumpWidget(page(2, enabled: false));
    expect(scale(tester), 1);
    await tester.pumpWidget(page(3));
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(tester), isNot(1));
    await tester.pumpWidget(page(3, reduce: true));
    expect(scale(tester), 1);
    await tester.pumpWidget(page(4));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
