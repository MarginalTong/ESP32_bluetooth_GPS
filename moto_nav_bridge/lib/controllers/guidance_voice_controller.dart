import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_text.dart';
import '../models/device_direction.dart';
import '../services/guidance/voice_guidance_planner.dart';
import '../services/local_account_data.dart';
import '../services/navigation_voice.dart';
import '../services/settings_store.dart';
import 'navigation_controller.dart';

/// Spoken turn guidance: whether it is on (an account-synced setting), and
/// when to speak. Listens to navigation updates; what to say is decided by
/// [VoiceGuidancePlanner].
class GuidanceVoiceController extends ChangeNotifier {
  GuidanceVoiceController() {
    _events.setMethodCallHandler((call) async {
      if (call.method != 'speechState') return;
      final state = call.arguments as String;
      if (state == 'navigationSpeechStarted') _speaking = true;
      if (state == 'navigationSpeechEnded') _speaking = false;
    });
  }

  // Native speech reports when a navigation announcement starts and ends.
  static const _events = MethodChannel('moto_nav_bridge/voice');

  final _planner = VoiceGuidancePlanner();
  NavigationController? _nav;
  bool _speaking = false;
  bool _disposed = false;

  bool get enabled => _enabled;
  bool _enabled = false;

  /// Called when the device cannot speak; guidance is then switched off for
  /// this session without changing the saved setting.
  VoidCallback? onUnavailable;

  void bind(NavigationController nav) {
    if (identical(nav, _nav)) return;
    _nav?.removeListener(_announce);
    _nav = nav;
    nav.addListener(_announce);
  }

  /// Applies the saved setting, e.g. after an account sync changed it.
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(LocalAccountData.voiceKey) ?? false;
    if (_disposed || saved == _enabled) return;
    _planner.reset();
    if (!saved) unawaited(silence());
    _enabled = saved;
    notifyListeners();
  }

  void toggle() {
    _enabled = !_enabled;
    notifyListeners();
    unawaited(_save(_enabled));
    _planner.reset();
    if (_enabled) {
      _announce();
    } else {
      unawaited(silence());
    }
  }

  Future<void> _save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await SettingsStore.edit(prefs, () async {
        await prefs.setBool(LocalAccountData.voiceKey, enabled);
      });
    } catch (_) {
      // The account changed meanwhile: this session keeps its own choice.
    }
  }

  Future<void> silence() async {
    try {
      await NavigationVoice.stop();
    } catch (_) {
      /* Optional native audio. */
    }
  }

  void _announce() {
    final nav = _nav;
    if (_disposed || !_enabled || nav == null) return;
    final state = nav.current;
    final route = nav.selectedRoute;
    // Rerouting keeps speaking: the planner announces it once.
    if (state == null ||
        route == null ||
        (state.direction == DeviceDirection.stop && !state.rerouting) ||
        (nav.phase != NavPhase.navigating && nav.phase != NavPhase.arrived)) {
      unawaited(silence());
      return;
    }
    final fix = nav.voiceFix;
    final english = AppText.current.isEnglish;
    final utterance = _planner.next(
      GuidanceInput(
        route: route,
        steps: route.steps,
        stepIndex: nav.voiceStepIndex,
        state: state,
        now: DateTime.now(),
        reliable: nav.voiceGuidanceReliable,
        speedMps: fix?.speed,
        accuracyMeters: fix?.accuracy,
        rerouteFailed: nav.rerouteFailed,
        speaking: _speaking,
      ),
      english: english,
    );
    if (utterance != null) unawaited(_speak(utterance.text, english));
  }

  Future<void> _speak(String message, bool english) async {
    try {
      await NavigationVoice.speak(message, english: english);
    } catch (_) {
      if (_disposed) return;
      _enabled = false;
      notifyListeners();
      onUnavailable?.call();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _events.setMethodCallHandler(null);
    _nav?.removeListener(_announce);
    unawaited(silence());
    super.dispose();
  }
}
