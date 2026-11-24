part of 'navigation_controller.dart';

extension _NavigationPositions on NavigationController {
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      NavigationController._heartbeatInterval,
      (_) => unawaited(_heartbeat()),
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _heartbeat() async {
    final last = _lastAcceptedFixAt;
    if (_heartbeatBusy ||
        _disposed ||
        _phase != NavPhase.navigating ||
        _posSub == null ||
        _engine == null ||
        _rerouting ||
        _awaitingValidRoute ||
        (last != null &&
            DateTime.now().difference(last) <
                NavigationController._heartbeatInterval)) {
      return;
    }
    // Identify this trip so a result arriving after stop/start or a route
    // change is discarded instead of being applied to the new trip.
    final engine = _engine;
    final subscription = _posSub;
    _heartbeatBusy = true;
    try {
      final fix = await _location.currentPosition().timeout(
        NavigationController._heartbeatFixTimeout,
      );
      final anchor = _latestPosition;
      final state = _current;
      if (_disposed ||
          _phase != NavPhase.navigating ||
          !identical(_engine, engine) ||
          !identical(_posSub, subscription) ||
          _rerouting ||
          _awaitingValidRoute ||
          fix is! NavigationFix ||
          !_usableVoiceFix(fix) ||
          DateTime.now().difference(fix.timestamp).abs() >
              const Duration(seconds: 10) ||
          anchor == null ||
          state == null ||
          state.rerouting ||
          state.direction == DeviceDirection.stop) {
        return;
      }
      // Beyond jitter the bike has really moved: leave that to the stream,
      // which applies the full matcher. Sending nothing keeps the display
      // honest if the stream has stalled while moving.
      final drift = math.max(
        NavigationController._heartbeatMinDriftMeters,
        fix.accuracy * 2,
      );
      if (fix.distanceTo(anchor) > drift) return;
      await ble.send(state);
    } catch (_) {
      // No fresh fix: send nothing, so the display reports stale guidance.
    } finally {
      _heartbeatBusy = false;
    }
  }

  void _listenForPositions() {
    if (_disposed || _phase != NavPhase.navigating || _posSub != null) return;
    try {
      _posSub = _location.positionStream().listen(
        _onPosition,
        onError: _onPositionError,
        onDone: () => _onPositionError(StateError('GPS stream ended')),
      );
      _log('gps_stream_started');
    } catch (error) {
      _onPositionError(error);
    }
  }

  void _scheduleGpsRestart() {
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = Timer(const Duration(seconds: 2), () async {
      _gpsRestartTimer = null;
      if (_disposed || _phase != NavPhase.navigating) return;
      _listenForPositions();
      if (_posSub == null) return;
      // A fresh one-shot fix can restore guidance even when the bike is still
      // and the restarted stream's distance filter has not emitted yet.
      try {
        final fix = await _location.currentPosition().timeout(
          const Duration(seconds: 8),
        );
        if (!_disposed &&
            _phase == NavPhase.navigating &&
            fix is NavigationFix &&
            _usableVoiceFix(fix)) {
          _log('gps_stream_recovered ${_fixDetails(fix)}');
          await _onPosition(fix);
        }
      } catch (_) {
        _log('gps_recovery_waiting_for_stream');
      }
    });
  }

  Future<void> _onPosition(LatLng pos) async {
    if (_disposed || _phase != NavPhase.navigating) return;
    if (pos is NavigationFix) {
      if (DateTime.now().difference(pos.timestamp).abs() >
              const Duration(seconds: 10) ||
          (_lastAcceptedFixAt != null &&
              !pos.timestamp.isAfter(_lastAcceptedFixAt!))) {
        return;
      }
      _lastAcceptedFixAt = pos.timestamp;
      _recentFixes.add(pos);
      if (_recentFixes.length > NavigationController._recentFixLimit) {
        _recentFixes.removeAt(0);
      }
    }
    _latestPosition = pos;

    final engine = _engine;
    if (engine == null) return;

    if (await _maybeReroute(pos)) return;
    // A newer location callback may have started/replaced the route while
    // this callback was awaiting confirmation. Never send its old instruction.
    if (_disposed ||
        _phase != NavPhase.navigating ||
        _rerouting ||
        _engine != engine) {
      return;
    }

    if (_sideRoads is RouteSideRoadProvider) {
      _sideRoads.advancePrefetch(pos);
      _applyCachedSideRoads(pos);
    } else {
      unawaited(_maybeRefreshSideRoads(pos));
    }

    final navState = engine.update(pos);
    if (_offRouteSamples == 0 &&
        !_awaitingValidRoute &&
        selectedRoute != null) {
      _waypointPlan.update(selectedRoute!, engine.currentStepIndex, pos);
    }
    _current = navState;
    if (_offRouteSamples == 0 && !_awaitingValidRoute) {
      _lastReliableNavState = navState;
    }

    if (engine.isFinished) {
      _set(NavPhase.arrived);
    } else if (_error == AppText.current.gpsSignalLost) {
      _set(NavPhase.navigating);
    } else {
      _notify();
    }

    await ble.send(navState);

    if (engine.isFinished) {
      await _posSub?.cancel();
      _posSub = null;
    }
  }

  void _onPositionError(Object e) {
    if (_disposed || _phase != NavPhase.navigating) return;
    _log('gps_stream_error type=${e.runtimeType}');
    final failedSubscription = _posSub;
    _posSub = null;
    unawaited(failedSubscription?.cancel() ?? Future<void>.value());
    _invalidateReroute();
    // Lost the GPS fix — tell the device to show STOP so the rider isn't given
    // a stale/misleading instruction.
    _current = NavState.stopped;
    _set(NavPhase.navigating, error: AppText.current.gpsSignalLost);
    ble.send(NavState.stopped);
    _scheduleGpsRestart();
  }

  bool _isStationary(NavigationFix pos) {
    if (pos.speed.isFinite &&
        pos.speed >= NavigationController._movingSpeedMetersPerSecond) {
      return false;
    }
    for (final fix in _recentFixes.reversed) {
      if (!fix.timestamp.isBefore(pos.timestamp)) continue;
      final radius = math.max(pos.accuracy + fix.accuracy, 20.0);
      if (pos.distanceTo(fix) > radius) return false;
      if (pos.timestamp.difference(fix.timestamp) >=
          NavigationController._stationaryEvidence) {
        return true;
      }
    }
    return false;
  }
}
