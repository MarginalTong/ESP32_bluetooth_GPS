part of 'navigation_controller.dart';

extension _NavigationPlanning on NavigationController {
  Future<void> _savePreferences({
    required bool highways,
    required bool tolls,
    required bool ferries,
    bool tunnels = false,
  }) async {
    if (!canEditPreferences) throw StateError('Navigation is active');
    final store = _preferences ?? await SharedPreferences.getInstance();
    await SettingsStore.edit(store, () async {
      if (!canEditPreferences) throw StateError('Navigation is active');
      final saved = await store.setString(
        NavigationController._preferencesKey,
        jsonEncode({
          'highways': highways,
          'tolls': tolls,
          'ferries': ferries,
          'tunnels': tunnels,
        }),
      );
      if (!saved) throw StateError('Preferences could not be saved');
      if (_disposed) return;
      updatePreferences(
        highways: highways,
        tolls: tolls,
        ferries: ferries,
        tunnels: tunnels,
      );
    });
  }

  void _updatePreferences({
    required bool highways,
    required bool tolls,
    required bool ferries,
    bool tunnels = false,
  }) {
    if (!canEditPreferences) return;
    avoidHighways = highways;
    avoidTolls = tolls;
    avoidFerries = ferries;
    avoidTunnels = tunnels;
    // A preview made with old preferences must not remain selectable.
    if (_sideRoads is RouteSideRoadProvider) {
      _sideRoads.cancelPrefetch();
    }
    _routeOptions = const [];
    _selectedRouteIndex = 0;
    _previewRouteExplicitlySelected = false;
    _engine = null;
    _notify();
  }

  void _snapshotPreferences() {
    _tripPreferences = {
      if (avoidHighways) 'use_highways': 0.0,
      if (avoidTolls) 'use_tolls': 0.0,
      if (avoidFerries) 'use_ferry': 0.0,
      if (avoidTunnels) 'exclude_tunnels': true,
    };
  }

  Future<List<RouteCandidate>> _fetchTripRoutes(
    RouteProvider provider, {
    required LatLng origin,
    required LatLng destination,
  }) {
    final remaining = _waypointPlan.remaining;
    if (remaining.isEmpty) {
      return provider.fetchRoutes(origin: origin, destination: destination);
    }
    if (provider is! WaypointRouteProvider) {
      throw DirectionsException('Route provider does not support waypoints');
    }
    return provider.fetchWaypointRoutes(
      origin: origin,
      destination: destination,
      waypoints: remaining,
    );
  }

  Future<void> _previewDestination(
    LatLng destination, {
    List<PlaceResult> waypoints = const [],
  }) async {
    if (_phase != NavPhase.idle && _phase != NavPhase.error) return;
    final plan = WaypointPlan(waypoints);

    if (_sideRoads is RouteSideRoadProvider) {
      _sideRoads.cancelPrefetch();
    }

    // A newer preview, Start or stop supersedes this request. Its late result
    // must never replace the active engine or another destination's routes.
    final requestId = ++_previewRequestId;
    bool current() =>
        !_disposed &&
        requestId == _previewRequestId &&
        (_phase == NavPhase.idle || _phase == NavPhase.error);

    _previewRouteExplicitlySelected = false;
    _destination = destination;
    _waypointPlan = plan;
    _routeOptions = const [];
    _engine = null;
    _current = null;
    _previewingRoute = true;
    _snapshotPreferences();
    _error = null;
    _notify();

    if (!await _location.ensurePermission()) {
      if (!current()) return;
      _previewingRoute = false;
      _set(NavPhase.error, error: 'Location permission/service unavailable');
      return;
    }

    try {
      if (!current()) return;
      final origin = await _location.currentPosition();
      if (!current()) return;
      final routes = await _fetchTripRoutes(
        _directions,
        origin: origin,
        destination: destination,
      );
      if (!current()) return;
      _origin = origin;
      _latestPosition = origin;
      _setRouteOptions(routes, selectedIndex: preferredRouteIndex(routes));
      _warmPreviewSideRoads();
    } catch (e) {
      if (current()) _error = e.toString();
    } finally {
      if (current()) {
        _previewingRoute = false;
        _notify();
      }
    }
  }

  Future<void> _startNavigation(
    LatLng destination, {
    List<PlaceResult>? waypoints,
  }) async {
    final stops =
        waypoints ??
        (((_destination?.distanceTo(destination) ?? double.infinity) < 5)
            ? this.waypoints
            : const <PlaceResult>[]);
    final plan = WaypointPlan(stops);
    // A route picked on the preview map is an explicit user choice. Keep it
    // across the fresh route request made when the trip starts.
    final previewSelection =
        _previewRouteExplicitlySelected &&
            stops.length == this.waypoints.length &&
            stops.asMap().entries.every(
              (e) =>
                  e.value.location.distanceTo(this.waypoints[e.key].location) <
                  1,
            ) &&
            _phase == NavPhase.idle &&
            _destination != null &&
            _destination!.distanceTo(destination) < 5 &&
            _routeOptions.isNotEmpty
        ? _selectedRouteIndex
        : null;
    await stopNavigation();
    _waypointPlan = plan;
    _snapshotPreferences();

    if (!await _location.ensurePermission()) {
      _set(NavPhase.error, error: 'Location permission/service unavailable');
      return;
    }

    _set(NavPhase.routing);
    try {
      final origin = await _location.currentPosition();
      _origin = origin;
      _latestPosition = origin;
      _waypointPlan.completeAtStart(origin);
      _destination = destination;
      _notify();
      final routes = await _fetchTripRoutes(
        _directions,
        origin: origin,
        destination: destination,
      );
      // Route planning must not wait for supplementary map context. Nearby
      // junctions are fetched in the background after navigation starts.
      _setRouteOptions(
        routes,
        selectedIndex:
            previewSelection != null && previewSelection < routes.length
            ? previewSelection
            : preferredRouteIndex(routes),
      );
    } catch (e) {
      _set(NavPhase.error, error: e.toString());
      return;
    }

    _set(NavPhase.navigating);
    _startedNavigationAt = DateTime.now();
    _listenForPositions();
    _startHeartbeat();
    _startRouteSideRoadPrefetch();
  }

  Future<void> _selectRoute(int index) async {
    if (_disposed || _phase == NavPhase.paused) return;
    if (index < 0 || index >= _routeOptions.length) return;
    final preview = _phase == NavPhase.idle && _destination != null;
    if (!preview && _phase != NavPhase.navigating) return;
    // Only a deliberate tap should override the fastest candidate when Start
    // fetches fresh ETAs. An automatically selected preview index is not a
    // user choice. A tap on the already selected route still counts as one.
    if (preview) _previewRouteExplicitlySelected = true;
    if (index == _selectedRouteIndex) return;

    _invalidateReroute();
    _error = null;
    _selectedRouteIndex = index;
    _engine = NavigationEngine(
      _routeOptions[index].steps,
      sideRoads: _routeOptions[index].sideRoads,
    );
    _lastReliableNavState = _engine!.update(
      _routeOptions[index].polyline.first,
    );
    _offRouteSamples = 0;
    _lastSideRoadRefreshAt = null;
    _sideRoadRefreshPosition = null;

    if (preview) {
      // Selecting a preview never starts guidance or writes to the device.
      _current = null;
      _notify();
      _warmPreviewSideRoads();
      return;
    }

    final origin = _latestPosition ?? _origin;
    if (origin != null) {
      final navState = _engine!.update(origin);
      _current = navState;
      _lastReliableNavState = navState;
      _notify();
      await ble.send(navState);
      _startRouteSideRoadPrefetch();
      return;
    }

    _notify();
  }

  void _setRouteOptions(
    List<RouteCandidate> routes, {
    required int selectedIndex,
  }) {
    if (routes.isEmpty) {
      throw DirectionsException('No usable routes returned');
    }
    _routeOptions = List.unmodifiable(routes);
    _previewRouteExplicitlySelected = false;
    _selectedRouteIndex = selectedIndex.clamp(0, routes.length - 1);
    final selected = _routeOptions[_selectedRouteIndex];
    _engine = NavigationEngine(selected.steps, sideRoads: selected.sideRoads);
    _waypointPlan.bindRoute();
    final initialPosition = _waypointPlan.stops.isEmpty
        ? selected.polyline.first
        : (_latestPosition ?? selected.polyline.first);
    _lastReliableNavState = _engine!.update(initialPosition);
    if (_phase == NavPhase.routing || _phase == NavPhase.navigating) {
      _waypointPlan.update(
        selected,
        _engine!.currentStepIndex,
        initialPosition,
      );
    }
  }
}
