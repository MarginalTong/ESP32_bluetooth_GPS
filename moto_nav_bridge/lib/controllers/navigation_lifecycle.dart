part of 'navigation_controller.dart';

extension _NavigationLifecycle on NavigationController {
  Future<void> _pause() async {
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = null;
    _stopHeartbeat();
    _invalidateReroute();
    await _posSub?.cancel();
    _posSub = null;
    _current = NavState.stopped;
    await ble.send(NavState.stopped);
    _set(NavPhase.paused);
    _checkpoint(force: true);
  }

  Future<void> _stopNavigation() async {
    await _clearNavigationState();
  }

  Future<void> _endNavigation({bool disconnectDevice = true}) async {
    // Clear the phone's trip first. A stalled BLE write must never leave the
    // End navigation button apparently unresponsive.
    await _clearNavigationState();
    bool stopDelivered = false;
    try {
      stopDelivered = await ble
          .send(NavState.ended)
          .timeout(const Duration(seconds: 2));
    } catch (error) {
      _log('stop_write_failed type=${error.runtimeType}');
    }
    // If STOP could not reach the display, drop the link so it cannot keep
    // showing an obsolete live turn as though the phone were still guiding.
    if (disconnectDevice || !stopDelivered) {
      await ble.disconnect();
    }
  }

  Future<void> _clearNavigationState({bool clearSaved = true}) async {
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = null;
    _stopHeartbeat();
    _invalidateReroute();
    _previewRequestId++;
    _previewingRoute = false;
    if (clearSaved) _forgetSavedTrip();
    if (clearSaved) _navigationEnded = true;
    _gpsUnavailable = false;
    _networkUnavailable = false;
    _savedTrip = null;
    _routeStepOffset = 0;
    if (_sideRoads is RouteSideRoadProvider) {
      _sideRoads.cancelPrefetch();
    }
    await _posSub?.cancel();
    _posSub = null;
    _engine = null;
    _current = null;
    _lastReliableNavState = null;
    _origin = null;
    _latestPosition = null;
    _recentFixes.clear();
    _destination = null;
    _waypointPlan = WaypointPlan(const []);
    _routeOptions = const [];
    _selectedRouteIndex = 0;
    _previewRouteExplicitlySelected = false;
    _rerouting = false;
    _offRouteSamples = 0;
    _lastRerouteAt = null;
    _startedNavigationAt = null;
    _lastAcceptedFixAt = null;
    _rerouteNoticeUntil = null;
    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = null;
    _refreshingSideRoads = false;
    _sideRoadRefreshPosition = null;
    _lastSideRoadRefreshAt = null;
    _lastSideRoadCacheVersion = -1;
    _lastAppliedSideRoads = const [];
    _set(NavPhase.idle);
  }
}
