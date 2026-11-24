part of 'navigation_controller.dart';

extension _NavigationPersistence on NavigationController {
  TripProgress _tripProgress(String id, {bool? active}) => TripProgress(
    id: id,
    active:
        active ??
        (_phase == NavPhase.routing ||
            _phase == NavPhase.navigating ||
            _phase == NavPhase.paused),
    selected: _selectedRouteIndex,
    step: voiceStepIndex,
    completed: _waypointPlan.completed,
    routeBase: _waypointPlan.routeBase,
    savedAt: DateTime.now(),
    position: _latestPosition,
  );

  void _cacheRoute() {
    final destination = _destination;
    if (destination == null || _routeOptions.isEmpty) return;
    final id = '${DateTime.now().microsecondsSinceEpoch}-${++_cacheRevision}';
    _cachedRouteId = id;
    final trip = OfflineTrip(
      id: id,
      destination: destination,
      routes: _routeOptions,
      stops: waypoints,
      preferences: Map.of(_tripPreferences),
      progress: _tripProgress(id),
    );
    _routeSave = (_sessions?.save(trip) ?? Future<void>.value()).catchError((
      Object e,
    ) {
      if (_disposed || _cachedRouteId != id) return;
      _log('route_cache_write_failed type=${e.runtimeType}');
      _error = AppText.current.offlineSaveFailed;
      _notify();
    });
  }

  void _checkpoint({bool force = false}) {
    final id = _cachedRouteId;
    final last = _lastCheckpointAt;
    if (id == null ||
        _engine == null ||
        _disposed ||
        _phase == NavPhase.arrived) {
      return;
    }
    // Only a small progress file is rewritten: every five seconds, or at an
    // explicit maneuver/selection/lifecycle boundary.
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastCheckpointAt = DateTime.now();
    unawaited(
      (_sessions?.checkpoint(_tripProgress(id)) ?? Future<void>.value())
          .catchError((Object e) {
            if (!_disposed) {
              _log('route_checkpoint_failed type=${e.runtimeType}');
            }
          }),
    );
  }

  void _forgetSavedTrip() {
    _cachedRouteId = null;
    _savedTrip = null;
    _lastCheckpointAt = null;
    unawaited(
      (_sessions?.clear() ?? Future<void>.value()).catchError((Object e) {
        if (!_disposed) _log('route_cache_clear_failed type=${e.runtimeType}');
      }),
    );
  }

  Future<bool> _restoreSavedNavigation() async {
    if (_disposed ||
        _phase != NavPhase.idle ||
        _restoringTrip ||
        _destination != null) {
      return false;
    }
    final request = _previewRequestId;
    _restoringTrip = true;
    try {
      final trip = await _sessions?.load();
      if (_disposed ||
          _phase != NavPhase.idle ||
          request != _previewRequestId ||
          _destination != null) {
        return false;
      }
      _savedTrip = trip;
      _notify();
      return trip != null;
    } catch (e) {
      if (!_disposed) _log('route_cache_read_failed type=${e.runtimeType}');
      return false;
    } finally {
      _restoringTrip = false;
    }
  }

  Future<bool> _resumeSavedNavigation() async {
    final trip = _savedTrip;
    if (trip == null ||
        _restoringTrip ||
        _disposed ||
        _phase != NavPhase.idle) {
      return false;
    }
    final request = _previewRequestId;
    _restoringTrip = true;
    try {
      if (!await _location.ensurePermission()) {
        throw StateError('GPS unavailable');
      }
      final fix = await _location.currentPosition().timeout(
        const Duration(seconds: 8),
      );
      if (_disposed ||
          request != _previewRequestId ||
          _phase != NavPhase.idle) {
        return false;
      }
      if (!_freshResumeFix(fix)) throw StateError('No fresh GPS fix');
      _installSavedTrip(trip, fix);
      _set(NavPhase.navigating);
      _navigationEnded = false;
      _checkpoint(force: true);
      _startedNavigationAt = DateTime.now();
      _listenForPositions();
      _startHeartbeat();
      _startRouteSideRoadPrefetch();
      await _onPosition(fix);
      return true;
    } catch (e) {
      if (!_disposed && request == _previewRequestId) {
        _error = AppText.current.gpsSignalLost;
        _notify();
      }
      return false;
    } finally {
      _restoringTrip = false;
    }
  }

  bool _freshResumeFix(LatLng fix) =>
      fix is NavigationFix &&
      fix.accuracy.isFinite &&
      fix.accuracy >= 0 &&
      fix.accuracy <= 50 &&
      DateTime.now().difference(fix.timestamp).abs() <
          const Duration(seconds: 10);

  void _installSavedTrip(OfflineTrip trip, LatLng fix) {
    final progress = trip.progress;
    _routeOptions = List.unmodifiable(trip.routes);
    _selectedRouteIndex = progress.selected;
    _destination = trip.destination;
    _origin = fix;
    _latestPosition = fix;
    _tripPreferences = Map.of(trip.preferences);
    _waypointPlan = WaypointPlan(
      trip.stops,
      completed: progress.completed,
      routeBase: progress.routeBase,
    );
    _routeStepOffset = progress.step;
    _engine = NavigationEngine(
      selectedRoute!.steps.sublist(progress.step),
      sideRoads: selectedRoute!.sideRoads,
    );
    _cachedRouteId = trip.id;
    _savedTrip = null;
    _current = _temporaryRouteState();
    // Confirm matching before publishing any turn; an off-route restart must
    // not walk the matcher forward along a route the rider is not following.
    if (_engine!.isOffRoute(fix)) {
      _awaitingValidRoute = true;
      _offRouteSamples = NavigationController._offRouteSamplesBeforeReroute;
    }
  }
}

int _cacheRevision = 0;
