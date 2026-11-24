part of 'navigation_controller.dart';

extension _NavigationDisplaySync on NavigationController {
  NavState _stamp(NavState state, LatLng? fix) => fix is NavigationFix
      ? state.copyWith(
          expiresAtUtcSeconds:
              fix.timestamp.millisecondsSinceEpoch ~/ 1000 +
              BleConstants.guidanceValiditySeconds,
        )
      : state;

  void _holdForGps() {
    if (_rerouting || _awaitingValidRoute) _invalidateReroute();
    _gpsUnavailable = true;
    _current = _temporaryRouteState();
    _set(NavPhase.navigating, error: AppText.current.gpsSignalLost);
    _sendTemporaryState();
  }

  Future<void> _synchronizeDisplay() async {
    if (_disposed) return;
    if (_phase == NavPhase.idle) {
      await restoreSavedNavigation();
      if (!_disposed && _phase == NavPhase.idle && !hasSavedTrip) {
        await ble.send(NavState.ended);
      }
      return;
    }
    if (_phase == NavPhase.arrived) {
      await ble.send(NavState.ended);
      return;
    }
    if (_phase != NavPhase.navigating || _engine == null) return;
    final engine = _engine;
    final measured = await _reconnectFix();
    if (_disposed || _phase != NavPhase.navigating || _engine != engine) return;
    final candidates =
        [
            measured,
            _latestPosition,
          ].whereType<NavigationFix>().where(_freshResumeFix).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (candidates.isEmpty) {
      _holdForGps();
      return;
    }
    final fix = candidates.first;
    if (_lastAcceptedFixAt == fix.timestamp) {
      final state = _current;
      if (state != null) await ble.send(_stamp(state, fix));
    } else {
      await _onPosition(fix);
    }
  }

  Future<LatLng?> _reconnectFix() async {
    try {
      return await _location.currentPosition().timeout(
        const Duration(seconds: 4),
      );
    } catch (_) {
      return null;
    }
  }
}
