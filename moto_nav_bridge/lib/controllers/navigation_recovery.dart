part of 'navigation_controller.dart';

extension _NavigationRecovery on NavigationController {
  void _scheduleRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(NavigationController._minRerouteInterval, () async {
      if (_disposed || !_awaitingValidRoute || _phase != NavPhase.navigating) {
        return;
      }
      final pos = _latestPosition;
      // A timer must never turn an old fix into a new navigation decision.
      if (pos is NavigationFix &&
          DateTime.now().difference(pos.timestamp).abs() <
              const Duration(seconds: 10) &&
          pos.accuracy.isFinite &&
          pos.accuracy >= 0 &&
          pos.accuracy <= 50) {
        _offRouteSamples = NavigationController._offRouteSamplesBeforeReroute;
        _log('automatic_retry ${_fixDetails(pos)}');
        await _onPositionRecovery(pos);
      } else {
        _log('retry_waiting_for_fresh_fix');
      }
      if (!_disposed && _awaitingValidRoute && !_rerouting) _scheduleRecovery();
    });
  }

  Future<void> _onPositionRecovery(LatLng pos) async {
    if (!await _maybeReroute(pos) &&
        !_disposed &&
        _phase == NavPhase.navigating) {
      _current = _engine == null ? null : _stamp(_engine!.update(pos), pos);
      _notify();
      if (_current != null) {
        _lastReliableNavState = _current;
        await ble.send(_current!);
      }
    }
  }

  NavState _temporaryRouteState() {
    final snapshot = _lastReliableNavState;
    return NavState(
      direction: DeviceDirection.stop,
      distanceMeters: 0,
      rerouting: true,
      routePreviewPoints: snapshot?.routePreviewPoints ?? const [],
      sideRoadPreviewPoints: snapshot?.sideRoadPreviewPoints ?? const [],
    );
  }

  Future<bool> _maybeReroute(LatLng pos) async {
    final engine = _engine;
    final destination = _destination;
    final text = AppText.current;
    if (engine == null || destination == null) return false;
    if (pos is NavigationFix &&
        (!pos.accuracy.isFinite || pos.accuracy < 0 || pos.accuracy > 50)) {
      _offRouteSamples = 0;
      return _awaitingValidRoute;
    }

    if (!engine.isOffRoute(pos)) {
      _offRouteSamples = 0;
      if (_awaitingValidRoute) {
        // Recover locally even if the server is unreachable or still waiting.
        // Its eventual response is now obsolete, including any errors.
        if (_rerouting) {
          _rerouteRequestId++;
          _rerouting = false;
        }
        // Recovery onto the old route is allowed only after a fresh position
        // matches it again, never merely because the HTTP request failed.
        _awaitingValidRoute = false;
        _recoveryTimer?.cancel();
        _log('recovered_on_previous_route');
        _rerouteFailure = null;
        _clearRerouteNotice();
        _error = null;
      }
      return false;
    }

    if (_rerouting) {
      _current = _temporaryRouteState();
      _notify();
      _sendTemporaryState();
      return true;
    }

    if (pos is NavigationFix && _isStationary(pos)) {
      if (_offRouteSamples > 0 || !_awaitingValidRoute) {
        _log('off_route_ignored_while_stationary ${_fixDetails(pos)}');
      }
      _offRouteSamples = 0;
      return _awaitingValidRoute;
    }

    // The first stream fix can differ from the fix used to request the route.
    // Near the origin at low speed, give GPS and road snapping time to settle.
    final started = _startedNavigationAt;
    final start = _origin;
    if (!_awaitingValidRoute &&
        started != null &&
        start != null &&
        DateTime.now().difference(started) <
            NavigationController._startMatchGrace &&
        pos is NavigationFix &&
        pos.speed.isFinite &&
        pos.speed >= 0 &&
        pos.speed < 3 &&
        pos.distanceTo(start) <= (pos.accuracy * 3).clamp(40.0, 100.0)) {
      _offRouteSamples = 0;
      return false;
    }

    _offRouteSamples++;
    if (_offRouteSamples < NavigationController._offRouteSamplesBeforeReroute) {
      if (_awaitingValidRoute) return true;
      // Treat the first couple of off-route samples as confirmation only.
      // GPS drift and simplified route geometry can briefly look off-route; if
      // we block normal updates here, the ESP32 freezes on an old instruction
      // exactly when the rider may be approaching a real turn.
      return false;
    }

    final now = DateTime.now();
    final last = _lastRerouteAt;
    if (last != null &&
        now.difference(last) < NavigationController._minRerouteInterval) {
      if (_rerouteFailure == null) _showRerouteNotice(text.rerouting);
      _current = _temporaryRouteState();
      _sendTemporaryState();
      return true;
    }

    unawaited(
      _requestReroute(pos, engine, destination).catchError((Object e) {
        if (!_disposed) _log('reroute_delivery_failed type=${e.runtimeType}');
        return true;
      }),
    );
    return true;
  }

  void _sendTemporaryState() {
    final state = _current;
    if (state == null) return;
    unawaited(
      Future<bool>.sync(() => ble.send(state)).catchError((Object e) {
        if (!_disposed) _log('temporary_write_failed type=${e.runtimeType}');
        return false;
      }),
    );
    _checkpoint();
  }

  Future<bool> _requestReroute(
    LatLng pos,
    NavigationEngine engine,
    LatLng destination,
  ) async {
    final now = DateTime.now();
    final text = AppText.current;
    _rerouting = true;
    _recoveryTimer?.cancel();
    final requestStarted = DateTime.now();
    _log('reroute_start ${_fixDetails(pos)}');
    _awaitingValidRoute = true;
    _rerouteFailure = null;
    final requestId = ++_rerouteRequestId;
    _lastRerouteAt = now;
    _offRouteSamples = 0;
    _showRerouteNotice(text.offRouteRerouting);
    _current = _temporaryRouteState();
    _notify();

    try {
      _sendTemporaryState();
      final routes = await _fetchTripRoutes(
        _rerouteDirections,
        origin: pos,
        destination: destination,
      ).timeout(const Duration(seconds: 12));
      if (!_isCurrentReroute(requestId, engine, destination)) {
        return true;
      }
      final latest = _latestPosition ?? pos;
      if (latest is NavigationFix &&
          (!latest.accuracy.isFinite ||
              latest.accuracy < 0 ||
              latest.accuracy > 50 ||
              DateTime.now().difference(latest.timestamp).abs() >
                  const Duration(seconds: 10))) {
        throw DirectionsException('No fresh accurate position for reroute');
      }
      final alignedRoutes = routes
          .map((r) => RouteAlignment.trim(r, pos, latest))
          .toList();
      _log(
        'reroute_response elapsedMs=${DateTime.now().difference(requestStarted).inMilliseconds} candidates=${routes.length} movedM=${pos.distanceTo(latest).round()} ${_fixDetails(latest)}',
      );
      final selected = _selectAlignedReroute(alignedRoutes, latest);
      _origin = latest;
      _setRouteOptions(alignedRoutes, selectedIndex: selected);
      _awaitingValidRoute = false;
      _log('reroute_success selected=$selected');
      _clearRerouteNotice();
      _lastSideRoadRefreshAt = null;
      _sideRoadRefreshPosition = null;
      _set(NavPhase.navigating);
      _startRouteSideRoadPrefetch();

      final navState = _stamp(
        _engine!.update(_latestPosition ?? pos),
        _latestPosition ?? pos,
      );
      _current = navState;
      _lastReliableNavState = navState;
      _networkUnavailable = false;
      _checkpoint(force: true);
      _notify();
      await ble.send(navState);
      return true;
    } catch (e) {
      return _handleRerouteFailure(
        e,
        requestId,
        engine,
        destination,
        requestStarted,
      );
    } finally {
      if (_rerouteRequestId == requestId) _rerouting = false;
    }
  }

  int _selectAlignedReroute(List<RouteCandidate> alignedRoutes, LatLng latest) {
    var anyDistanceRejected = false;
    var anyDirectionRejected = false;
    final selected = preferredRouteIndex(
      alignedRoutes,
      avoidEarlyUTurns: true,
      eligible: (route) {
        // Heading on the API request is a preference, not a guarantee. Reject
        // stale/distant or reverse-going starts rather than silently falling
        // back to a route which points back at the missed junction.
        final reverse = RouteAlignment.conflictsWithCourse(route, latest);
        final matcher = NavigationEngine(route.steps);
        matcher.isOffRoute(latest);
        final distanceRejected =
            (matcher.lastRouteDistanceMeters ?? double.infinity) >
            (matcher.lastOffRouteThresholdMeters ?? 0);
        final directionRejected = reverse || matcher.reverseTravel;
        anyDistanceRejected |= distanceRejected;
        anyDirectionRejected |= directionRejected;
        _log(
          'candidate startReverse=$reverse matchedReverse=${matcher.reverseTravel} distanceM=${matcher.lastRouteDistanceMeters?.toStringAsFixed(1)} thresholdM=${matcher.lastOffRouteThresholdMeters?.toStringAsFixed(1)} courseDeltaDeg=${matcher.lastCourseDeltaDegrees?.toStringAsFixed(1) ?? "ignored"} courseReliable=${latest is NavigationFix && latest.reliableCourse} distanceRejected=$distanceRejected directionRejected=$directionRejected rejected=${distanceRejected || directionRejected}',
        );
        return !distanceRejected && !directionRejected;
      },
    );
    if (selected < 0) {
      final reason = anyDistanceRejected && !anyDirectionRejected
          ? 'No reroute is close enough to the current position'
          : anyDirectionRejected && !anyDistanceRejected
          ? 'No reroute matches the current travel direction'
          : 'No reroute matches the current position and travel direction';
      throw DirectionsException(reason);
    }
    return selected;
  }

  Future<bool> _handleRerouteFailure(
    Object e,
    int requestId,
    NavigationEngine engine,
    LatLng destination,
    DateTime requestStarted,
  ) async {
    if (!_isCurrentReroute(requestId, engine, destination)) return true;
    // Route geometry and maneuvers are already cached in the active engine.
    // A failed network request must not blank guidance when the newest GPS
    // fix has meanwhile matched that same route again. Never revive the old
    // maneuver while the rider is still off-route or the fix is stale.
    final latest = _latestPosition;
    if (latest is NavigationFix &&
        latest.accuracy.isFinite &&
        latest.accuracy >= 0 &&
        latest.accuracy <= 50 &&
        DateTime.now().difference(latest.timestamp).abs() <
            const Duration(seconds: 10) &&
        !engine.isOffRoute(latest)) {
      _awaitingValidRoute = false;
      _recoveryTimer?.cancel();
      _rerouteFailure = null;
      _clearRerouteNotice();
      _offRouteSamples = 0;
      _log('reroute_failed_recovered_on_cached_route');
      final navState = _stamp(engine.update(latest), latest);
      _current = navState;
      _lastReliableNavState = navState;
      _set(NavPhase.navigating);
      await ble.send(navState);
      return true;
    }
    // Keep the last known route shape visible while a replacement is sought,
    // but do not revive a known-bad maneuver or distance.
    _rerouteFailure = AppText.current.rerouteFailed(e);
    _networkUnavailable =
        e is TimeoutException ||
        e is DirectionsException && e.networkUnavailable;
    // Avoid retaining exception URLs or coordinates in diagnostic logs.
    _log(
      'reroute_failed type=${e.runtimeType} elapsedMs=${DateTime.now().difference(requestStarted).inMilliseconds}',
    );
    _scheduleRecovery();
    _clearRerouteNotice();
    _current = _temporaryRouteState();
    _set(
      NavPhase.navigating,
      error: '${AppText.current.waitingForRouteConnection}\n$_rerouteFailure',
    );
    await ble.send(_current!);
    return true;
  }

  bool _isCurrentReroute(
    int requestId,
    NavigationEngine engine,
    LatLng destination,
  ) =>
      !_disposed &&
      _rerouteRequestId == requestId &&
      _engine == engine &&
      _phase == NavPhase.navigating &&
      _destination == destination;

  void _clearRerouteNotice() {
    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = null;
    _rerouteNoticeUntil = null;
  }

  void _invalidateReroute() {
    _recoveryTimer?.cancel();
    _rerouteRequestId++;
    _rerouting = false;
    _awaitingValidRoute = false;
    _rerouteFailure = null;
    _clearRerouteNotice();
  }

  void _showRerouteNotice(String message) {
    final now = DateTime.now();
    final until = _rerouteNoticeUntil;
    if (until != null && now.isBefore(until)) return;

    _rerouteNoticeUntil = now.add(NavigationController._rerouteNoticeDuration);
    _set(NavPhase.navigating, error: message);

    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = Timer(
      NavigationController._rerouteNoticeDuration,
      () {
        _rerouteNoticeUntil = null;
        if (_phase == NavPhase.navigating && _error == message) {
          _set(NavPhase.navigating);
        }
      },
    );
  }
}
