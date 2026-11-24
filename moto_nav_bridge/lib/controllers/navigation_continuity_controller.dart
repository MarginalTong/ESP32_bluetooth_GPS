import 'dart:async';
import 'package:flutter/foundation.dart';
import 'navigation_controller.dart';

enum NavigationCondition {
  navigating,
  networkOffline,
  gpsUnavailable,
  bleDisconnected,
  reconnecting,
  navigationEnded,
}

/// Orthogonal health facts, not replacement pages or navigation phases.
/// The link is injectable; tests do not need FlutterBluePlus static methods.
class NavigationContinuityController extends ChangeNotifier {
  NavigationContinuityController({
    required this.navigation,
    required this.link,
    required this.connected,
    required this.reconnecting,
  }) {
    _wasConnected = connected();
    navigation.addListener(_navigationChanged);
    link.addListener(_linkChanged);
    if (_wasConnected) unawaited(_synchronize());
  }
  final NavigationController navigation;
  final Listenable link;
  final bool Function() connected, reconnecting;
  bool _wasConnected = false, _disposed = false;
  int _generation = 0;

  Set<NavigationCondition> get conditions => {
    if (navigation.phase == NavPhase.navigating ||
        navigation.phase == NavPhase.routing ||
        navigation.phase == NavPhase.paused)
      NavigationCondition.navigating,
    // Observed route-network failure, not an assertion that Wi-Fi implies internet.
    if (navigation.networkUnavailable) NavigationCondition.networkOffline,
    if (navigation.gpsUnavailable) NavigationCondition.gpsUnavailable,
    if (!connected()) NavigationCondition.bleDisconnected,
    if (reconnecting()) NavigationCondition.reconnecting,
    if (navigation.navigationEnded) NavigationCondition.navigationEnded,
  };

  void _navigationChanged() {
    if (!_disposed) notifyListeners();
  }

  void _linkChanged() {
    if (_disposed) return;
    final next = connected();
    if (next != _wasConnected) {
      _generation++;
      _wasConnected = next;
      if (next) unawaited(_synchronize());
    }
    notifyListeners();
  }

  Future<void> _synchronize() async {
    if (_disposed || !connected()) return;
    final generation = _generation;
    try {
      await navigation.synchronizeDisplay();
    } catch (_) {
      /* Link owns transport errors. */
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  void resumed() {
    if (!_disposed && connected()) unawaited(_synchronize());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    link.removeListener(_linkChanged);
    navigation.removeListener(_navigationChanged);
    super.dispose();
  }
}
