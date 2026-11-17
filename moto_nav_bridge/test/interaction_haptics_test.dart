import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/interaction_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'haptics are graded and throttled, but actions are never dropped',
    () async {
      var now = Duration.zero;
      final sent = <InteractionFeedback>[];
      final haptics = InteractionHaptics(
        clock: () => now,
        driver: (kind) async => sent.add(kind),
      );
      var calls = 0;
      expect(haptics.action(null), isNull);
      final tap = haptics.action(() => calls++)!;
      tap();
      tap();
      expect(calls, 2);
      expect(sent, [InteractionFeedback.light]);
      now += InteractionHaptics.minimumInterval;
      haptics.emit(InteractionFeedback.selection);
      now += InteractionHaptics.minimumInterval;
      haptics.emit(InteractionFeedback.firm);
      expect(sent, [
        InteractionFeedback.light,
        InteractionFeedback.selection,
        InteractionFeedback.firm,
      ]);
    },
  );

  test('unsupported and failing haptics never block the operation', () async {
    for (final asyncFailure in [false, true]) {
      var acted = false;
      final haptics = InteractionHaptics(
        driver: (_) {
          if (asyncFailure) {
            return Future<void>.error(StateError('unsupported'));
          }
          throw StateError('unsupported');
        },
      );
      haptics.action(() => acted = true)!();
      await Future<void>.delayed(Duration.zero);
      expect(acted, isTrue);
    }
  });

  test('default feedback uses standard platform haptic types', () async {
    final calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    var now = Duration.zero;
    final haptics = InteractionHaptics(clock: () => now);
    for (final kind in InteractionFeedback.values) {
      haptics.emit(kind);
      now += InteractionHaptics.minimumInterval;
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
    ]);
  });
}
