part of 'navigation_controller.dart';

extension _NavigationDestination on NavigationController {
  Future<bool> _changeDestination(
    LatLng destination, {
    required LatLng expectedDestination,
    required bool Function() stillConfirmed,
  }) async {
    final previousEngine = _engine;
    bool valid() =>
        !_disposed &&
        stillConfirmed() &&
        _phase == NavPhase.navigating &&
        _current != null &&
        _current!.direction != DeviceDirection.stop &&
        !_rerouting &&
        !_awaitingValidRoute &&
        identical(_engine, previousEngine) &&
        identical(_destination, expectedDestination);
    bool fresh(LatLng? fix) =>
        fix is NavigationFix &&
        fix.accuracy.isFinite &&
        fix.accuracy >= 0 &&
        fix.accuracy <= 50 &&
        DateTime.now().difference(fix.timestamp).abs() <
            const Duration(seconds: 10);
    Future<LatLng?> currentFreshFix() async {
      if (fresh(_latestPosition)) return _latestPosition;
      try {
        final measured = await _location.currentPosition().timeout(
          const Duration(seconds: 8),
        );
        if (!valid() || !fresh(measured)) return null;
        final latest = _latestPosition;
        if (latest is NavigationFix &&
            latest.timestamp.isAfter((measured as NavigationFix).timestamp)) {
          return fresh(latest) ? latest : null;
        }
        _latestPosition = measured;
        return measured;
      } catch (_) {
        return null;
      }
    }

    if (_changingDestination ||
        previousEngine == null ||
        !valid() ||
        !destination.latitude.isFinite ||
        !destination.longitude.isFinite ||
        destination.latitude.abs() > 90 ||
        destination.longitude.abs() > 180) {
      return false;
    }
    _changingDestination = true;
    try {
      final start = await currentFreshFix();
      if (start == null) return false;
      final routes = await _fetchTripRoutes(
        _directions,
        origin: start,
        destination: destination,
      ).timeout(const Duration(seconds: 25));
      if (!valid()) return false;
      final latest = await currentFreshFix();
      if (latest == null) return false;
      final aligned = routes
          .where((route) => route.steps.isNotEmpty)
          .map((route) => RouteAlignment.trim(route, start, latest))
          .toList();
      final selected = preferredRouteIndex(
        aligned,
        avoidEarlyUTurns: true,
        eligible: (route) {
          if (route.steps.isEmpty ||
              route.steps.last.end.distanceTo(destination) > 200) {
            return false;
          }
          return !RouteAlignment.conflictsWithCourse(route, latest) &&
              !NavigationEngine(route.steps).isOffRoute(latest);
        },
      );
      if (selected < 0 || !valid()) return false;
      // Build everything before touching the active trip.
      final nextEngine = NavigationEngine(
        aligned[selected].steps,
        sideRoads: aligned[selected].sideRoads,
      );
      final nextState = _stamp(nextEngine.update(latest), latest);
      _invalidateReroute();
      _origin = latest;
      _destination = destination;
      _routeOptions = List.unmodifiable(aligned);
      _selectedRouteIndex = selected;
      _engine = nextEngine;
      _routeStepOffset = 0;
      _waypointPlan.bindRoute();
      _waypointPlan.update(
        aligned[selected],
        nextEngine.currentStepIndex,
        latest,
      );
      _current = nextState;
      _error = null;
      _offRouteSamples = 0;
      _lastRerouteAt = null;
      _lastSideRoadRefreshAt = null;
      _sideRoadRefreshPosition = null;
      _log('voice_destination_changed');
      _cacheRoute();
      _notify();
      _startRouteSideRoadPrefetch();
      // Routing success is separate from BLE availability. Send the new state,
      // but do not claim the route failed after it has already been committed.
      unawaited(
        Future<bool>.sync(() => ble.send(nextState)).catchError((_) => false),
      );
      return true;
    } catch (_) {
      if (!_disposed) _log('voice_destination_change_failed');
      return false;
    } finally {
      _changingDestination = false;
    }
  }
}
