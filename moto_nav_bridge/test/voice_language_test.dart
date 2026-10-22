import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/voice_language.dart';

void main() {
  test('Chinese speech overrides an English phone UI', () {
    expect(voiceTurnIsEnglish('带我去最近的加油站', fallbackEnglish: true), isFalse);
  });

  test('English speech overrides a Chinese phone UI', () {
    expect(voiceTurnIsEnglish('Find the nearest BP', fallbackEnglish: false),
        isTrue);
  });

  test('Chinese reply with an English place name uses a Chinese voice', () {
    expect(
        voiceReplyIsEnglish('前往 McDonald\'s Hurlstone Park。',
            fallbackEnglish: true),
        isFalse);
  });

  test('unknown script falls back to UI language', () {
    expect(voiceTurnIsEnglish('123', fallbackEnglish: true), isTrue);
    expect(voiceReplyIsEnglish('...', fallbackEnglish: false), isFalse);
  });
}
