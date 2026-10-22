import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/voice_test_page.dart';
import 'package:moto_nav_bridge/services/voice_trip_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('first voice use asks once and saves trip access choice',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('moto_nav_bridge/voice');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'loadVoiceCredentials') {
        return {
          'endpoint': 'https://nav.williamligallery.uk/v1/voice',
          'token': 'x' * 32,
        };
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: VoiceTestPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talk to Agent'));
    await tester.pumpAndSettle();
    expect(find.text('Let Agent use trip information?'), findsOneWidget);
    await tester.tap(find.text('Allow trip access'));
    await tester.pumpAndSettle();
    expect(find.text('Send this recording to Gemini?'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('voice_agent_route_access_v1'), isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talk to Agent'));
    await tester.pumpAndSettle();
    expect(find.text('Let Agent use trip information?'), findsNothing);
    expect(find.text('Send this recording to Gemini?'), findsOneWidget);
  });

  testWidgets('not now asks next trip, never ask remains off until settings',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('moto_nav_bridge/voice');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'loadVoiceCredentials') {
        return {
          'endpoint': 'https://nav.williamligallery.uk/v1/voice',
          'token': 'x' * 32,
        };
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: VoiceTestPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talk to Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not this trip'));
    await tester.pumpAndSettle();
    expect(await VoiceTripAccess.shouldAskAtTripStart(), isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    await VoiceTripAccess.save(VoiceTripAccessChoice.neverAsk);
    expect(await VoiceTripAccess.shouldAskAtTripStart(), isFalse);
    expect(await VoiceTripAccess.isEnabled(), isFalse);
    await VoiceTripAccess.setFromSettings(true);
    expect(await VoiceTripAccess.isEnabled(), isTrue);
    expect(await VoiceTripAccess.shouldAskAtTripStart(), isFalse);
  });

  testWidgets(
      'first setup stays visible on failure, hides after save and reload',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('moto_nav_bridge/voice');
    Map<String, String> saved = {};
    var fail = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'loadVoiceCredentials') return saved;
      if (call.method == 'saveVoiceCredentials') {
        if (fail) throw PlatformException(code: 'CREDENTIAL_SAVE_FAILED');
        saved = Map<String, String>.from(call.arguments as Map);
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: VoiceTestPage()));
    await tester.pumpAndSettle();
    final token = find.byKey(const ValueKey('gateway-token'));
    final save = find.byKey(const ValueKey('save-gateway'));
    expect(token, findsOneWidget);
    await tester.enterText(token, 'x' * 32);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(token, findsOneWidget);
    fail = false;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(token, findsNothing);
    expect(saved['token'], 'x' * 32);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: VoiceTestPage()));
    await tester.pumpAndSettle();
    expect(token, findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
