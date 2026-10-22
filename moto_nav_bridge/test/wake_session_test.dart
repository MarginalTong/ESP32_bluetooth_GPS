import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/voice_test_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'consented wake session prompts before capture and returns on silence',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'voice_agent_route_access_v1': false});
    const channel = MethodChannel('moto_nav_bridge/voice');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'loadVoiceCredentials') {
        return {
          'endpoint': 'https://nav.williamligallery.uk/v1/voice',
          'token': 'x' * 32
        };
      }
      if (call.method == 'speakAndWait') return true;
      return null; // No command audio: must not make a cloud request.
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              const VoiceTestPage(wakeSession: true))),
                  child: const Text('open'),
                ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(calls.indexOf('speakAndWait'),
        lessThan(calls.indexOf('recordCloudAudio')));
    expect(calls.where((method) => method == 'recordCloudAudio').length, 1);
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(VoiceTestPage), findsNothing);
  });

  testWidgets('wake session waits for a nearby turn before recording',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'voice_agent_route_access_v1': false});
    const channel = MethodChannel('moto_nav_bridge/voice');
    final calls = <String>[];
    var turnPending = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'loadVoiceCredentials') {
        return {
          'endpoint': 'https://nav.williamligallery.uk/v1/voice',
          'token': 'x' * 32,
        };
      }
      if (call.method == 'speakAndWait') return true;
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => VoiceTestPage(
                              wakeSession: true,
                              shouldDeferNonUrgentReply: () => turnPending))),
                  child: const Text('open'),
                ))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, isNot(contains('recordCloudAudio')));
    turnPending = false;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(calls, contains('recordCloudAudio'));
  });
}
