import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/guidance_voice_controller.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moto_nav_bridge/voice');
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'the saved setting is applied, and switching off stops speech',
    () async {
      SharedPreferences.setMockInitialValues({LocalAccountData.voiceKey: true});
      final voice = GuidanceVoiceController();
      var changes = 0;
      voice.addListener(() => changes++);
      await voice.reload();
      expect(voice.enabled, isTrue);
      expect(changes, 1);

      // An account sync turned it off on another phone.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(LocalAccountData.voiceKey, false);
      await voice.reload();
      expect(voice.enabled, isFalse);
      expect(calls, contains('stop'));
      await voice.reload();
      expect(changes, 2, reason: 'an unchanged setting does not notify');
      voice.dispose();
    },
  );

  test('toggling saves the choice for the account', () async {
    SharedPreferences.setMockInitialValues({});
    final voice = GuidanceVoiceController();
    voice.toggle();
    expect(voice.enabled, isTrue);
    await pumpEventQueue();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(LocalAccountData.voiceKey), isTrue);
    voice.toggle();
    await pumpEventQueue();
    expect(prefs.getBool(LocalAccountData.voiceKey), isFalse);
    voice.dispose();
  });

  test('a disposed controller ignores a late setting load', () async {
    SharedPreferences.setMockInitialValues({LocalAccountData.voiceKey: true});
    final voice = GuidanceVoiceController();
    final load = voice.reload();
    voice.dispose();
    await load;
    expect(voice.enabled, isFalse);
  });

  test('waypoint progress names the next stop and its position', () {
    expect(AppText.en.nextStopProgress('Cafe', 2, 3), 'Next stop: Cafe (2/3)');
    expect(AppText.zh.nextStopProgress('咖啡店', 1, 2), '下一途经点: 咖啡店 (1/2)');
  });
}
