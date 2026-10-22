import 'package:flutter/services.dart';

import '../models/device_direction.dart';
import '../models/nav_state.dart';

/// One announcement per distance band per maneuver; GPS jitter cannot re-arm it.
class NavigationVoice {
  static const _channel = MethodChannel('moto_nav_bridge/voice');
  Object? _route;
  int? _step;
  int _lowestBand = 5;

  void reset() {
    _route = null;
    _step = null;
    _lowestBand = 5;
  }

  String? next(NavState state, Object? route, int step,
      {required bool english}) {
    if (state.rerouting || state.direction == DeviceDirection.stop) return null;
    if (!identical(route, _route) || step != _step) {
      _route = route;
      _step = step;
      _lowestBand = 5;
    }
    final d = state.distanceMeters;
    final band = state.direction == DeviceDirection.arrived
        ? -1
        : d <= 50
            ? 0
            : d <= 200
                ? 1
                : d <= 500
                    ? 2
                    : 3;
    if (band >= _lowestBand) return null;
    _lowestBand = band;
    return instruction(state, english: english);
  }

  static String? instruction(NavState state, {required bool english}) {
    if (state.rerouting || state.direction == DeviceDirection.stop) return null;
    if (state.direction == DeviceDirection.arrived) {
      return english ? 'You have arrived.' : '已到达目的地。';
    }
    final action = switch (state.direction) {
      DeviceDirection.left => english ? 'turn left' : '左转',
      DeviceDirection.right => english ? 'turn right' : '右转',
      DeviceDirection.bearLeft => english ? 'bear left' : '向左前方行驶',
      DeviceDirection.bearRight => english ? 'bear right' : '向右前方行驶',
      DeviceDirection.uturn =>
        english ? 'make a U-turn only where permitted and safe' : '在允许且安全的位置掉头',
      _ => english ? 'continue straight' : '继续直行',
    };
    final distance = state.distanceMeters;
    return english ? 'In $distance metres, $action.' : '前方$distance米，$action。';
  }

  static Future<void> speak(String text, {required bool english}) =>
      _channel.invokeMethod<void>('speak', {
        'text': text,
        'language': english ? 'en-AU' : 'zh-CN',
      });

  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}
