import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/interaction_haptics.dart';
import 'package:moto_nav_bridge/ui/navio_feedback.dart';

void main() {
  var actions = 0;
  var enabled = true;
  var reduceMotion = false;
  var elapsed = Duration.zero;
  late InteractionHaptics haptics;
  final sent = <InteractionFeedback>[];
  setUp(() {
    actions = 0;
    enabled = true;
    reduceMotion = false;
    elapsed = Duration.zero;
    sent.clear();
    haptics = InteractionHaptics(
      clock: () => elapsed,
      driver: (kind) async => sent.add(kind),
    );
  });

  Widget page({bool scroll = false, FocusNode? focus}) => NavioFeedbackScope(
    haptics: haptics,
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Builder(
            builder: (context) {
              final button = Center(
                child: NavioPressEffect(
                  enabled: enabled,
                  child: FilledButton(
                    focusNode: focus,
                    onPressed: NavioFeedback.action(
                      context,
                      enabled ? () => actions++ : null,
                    ),
                    child: const Text('Action'),
                  ),
                ),
              );
              return scroll
                  ? ListView(children: [button, const SizedBox(height: 1500)])
                  : button;
            },
          ),
        ),
      ),
    ),
  );

  testWidgets('press shrinks, release activates once and restores size', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, .97);
    expect(sent, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(sent, [InteractionFeedback.light]);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('scroll and cancelled touches never activate or vibrate', (
    tester,
  ) async {
    await tester.pumpWidget(page(scroll: true));
    await tester.drag(find.text('Action'), const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(actions, 0);
    expect(sent, isEmpty);
    await tester.drag(find.byType(ListView), const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await tester.pumpWidget(page());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(actions, 0);
    expect(sent, isEmpty);
  });

  testWidgets(
    'disabled and reduced-motion controls keep their native behavior',
    (tester) async {
      enabled = false;
      await tester.pumpWidget(page());
      await tester.tap(find.text('Action'));
      await tester.pumpAndSettle();
      expect(actions, 0);
      expect(sent, isEmpty);
      enabled = true;
      reduceMotion = true;
      await tester.pumpWidget(page());
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Action')),
      );
      await tester.pump();
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.scale, 1);
      expect(scale.duration, Duration.zero);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(actions, 1);
    },
  );

  testWidgets('semantics and keyboard activation survive the press wrapper', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(page(focus: focus));
    expect(
      tester
          .getSemantics(find.byType(FilledButton))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(sent, [InteractionFeedback.light]);
    semantics.dispose();
  });
}
