import 'dart:async';
import 'package:flutter/services.dart';

enum InteractionFeedback { selection, light, firm }

/// Feedback follows accepted user actions, never pointer-down, GPS or BLE ticks.
/// A failed/unsupported haptic channel must never prevent the actual action.
class InteractionHaptics {
  InteractionHaptics({
    Future<void> Function(InteractionFeedback)? driver,
    Duration Function()? clock,
  }) : _driver = driver ?? _platform,
       _clock = clock ?? (() => _watch.elapsed);

  static final shared = InteractionHaptics();
  static final _watch = Stopwatch()..start();
  static const minimumInterval = Duration(milliseconds: 80);
  final Future<void> Function(InteractionFeedback) _driver;
  final Duration Function() _clock;
  Duration? _last;

  void emit(InteractionFeedback feedback) {
    final now = _clock();
    if (_last != null && now - _last! < minimumInterval) return;
    _last = now;
    try {
      unawaited(_driver(feedback).catchError((Object _) {}));
    } catch (_) {
      // Some platform adapters throw before returning their Future.
    }
  }

  VoidCallback? action(
    VoidCallback? callback, {
    InteractionFeedback feedback = InteractionFeedback.light,
  }) {
    if (callback == null) return null;
    return () {
      emit(feedback);
      callback();
    };
  }

  static Future<void> _platform(InteractionFeedback feedback) =>
      switch (feedback) {
        InteractionFeedback.selection => HapticFeedback.selectionClick(),
        InteractionFeedback.light => HapticFeedback.lightImpact(),
        InteractionFeedback.firm => HapticFeedback.mediumImpact(),
      };
}
