import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/widgets/tap_ripple.dart';

Finder get ripple => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is TapRipplePainter,
);

void main() {
  test('ripple has exact diameter, opacity and duration specification', () {
    TapRipplePainter frame(double t) => TapRipplePainter(
      origin: const Offset(22, 17),
      progress: AlwaysStoppedAnimation(t),
      color: Colors.blue,
      borderRadius: BorderRadius.circular(18),
    );
    expect(TapRippleStyle.duration, const Duration(milliseconds: 450));
    expect(frame(0).radiusFor(300), 0);
    expect(frame(0).opacity, .28);
    expect(frame(.5).opacity, closeTo(.14, .00001));
    expect(frame(1).radiusFor(300) * 2, closeTo(300 * 2.4, .00001));
    expect(frame(1).opacity, 0);
  });

  Widget page({bool enabled = true, bool reduce = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: TapRipple(
              enabled: enabled,
              child: const SizedBox(
                width: 300,
                height: 80,
                child: ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'wave starts at local touch coordinates, fades and disappears at 450ms',
    (tester) async {
      await tester.pumpWidget(page());
      final topLeft = tester.getTopLeft(find.byType(TapRipple));
      final gesture = await tester.startGesture(topLeft + const Offset(44, 24));
      await tester.pump();
      final painter =
          tester.widget<CustomPaint>(ripple).painter! as TapRipplePainter;
      expect(painter.origin, const Offset(44, 24));
      expect(painter.opacity, closeTo(.28, .001));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 225));
      expect(painter.opacity, closeTo(.14, .001));
      expect(painter.radiusFor(300), greaterThan(0));
      await tester.pump(const Duration(milliseconds: 225));
      expect(painter.opacity, closeTo(0, .00001));
      expect(painter.radiusFor(300) * 2, closeTo(720, .00001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(ripple, findsNothing);
    },
  );

  testWidgets('scroll movement and cancelled touches clear the wave', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    var gesture = await tester.startGesture(const Offset(70, 55));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(ripple, findsNothing);
    await gesture.cancel();
    gesture = await tester.startGesture(const Offset(70, 55));
    await tester.pump();
    expect(ripple, findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    expect(ripple, findsNothing);
  });

  testWidgets('disabled controls and reduced motion do not start waves', (
    tester,
  ) async {
    for (final (enabled, reduce) in [(false, false), (true, true)]) {
      await tester.pumpWidget(page(enabled: enabled, reduce: reduce));
      await tester.tapAt(const Offset(70, 55));
      await tester.pump();
      expect(ripple, findsNothing);
    }
  });
}
