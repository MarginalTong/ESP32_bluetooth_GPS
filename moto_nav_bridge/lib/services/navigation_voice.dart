import 'package:flutter/services.dart';

/// Platform text-to-speech for guidance; what to say is decided by
/// VoiceGuidancePlanner.
class NavigationVoice {
  static const _channel = MethodChannel('moto_nav_bridge/voice');

  static Future<void> speak(String text, {required bool english}) =>
      _channel.invokeMethod<void>('speak', {
        'text': text,
        'language': english ? 'en-AU' : 'zh-CN',
      });

  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}
