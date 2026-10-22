import 'package:shared_preferences/shared_preferences.dart';

enum VoiceTripAccessChoice { allow, notNow, neverAsk }

/// Only the allow choice is permanent consent. "Not now" is reconsidered
/// before the next trip; "never ask" can be changed in Agent settings.
class VoiceTripAccess {
  static const _enabledKey = 'voice_agent_route_access_v1';
  static const _neverAskKey = 'voice_agent_route_never_ask_v1';

  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  static Future<bool> hasDecision() async =>
      (await SharedPreferences.getInstance()).containsKey(_enabledKey);

  static Future<bool> shouldAskAtTripStart() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) != true &&
        prefs.getBool(_neverAskKey) != true;
  }

  static Future<bool> save(VoiceTripAccessChoice choice) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = choice == VoiceTripAccessChoice.allow;
    final neverAsk = choice == VoiceTripAccessChoice.neverAsk;
    final savedEnabled = await prefs.setBool(_enabledKey, enabled);
    final savedNeverAsk = await prefs.setBool(_neverAskKey, neverAsk);
    return savedEnabled && savedNeverAsk;
  }

  static Future<bool> setFromSettings(bool enabled) => save(
      enabled ? VoiceTripAccessChoice.allow : VoiceTripAccessChoice.neverAsk);
}
