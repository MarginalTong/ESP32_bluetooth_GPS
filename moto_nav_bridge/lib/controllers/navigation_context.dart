part of 'navigation_controller.dart';

extension _NavigationContext on NavigationController {
  void _startRouteSideRoadPrefetch() {
    final provider = _sideRoads;
    final engine = _engine;
    final route = selectedRoute;
    if (provider is! RouteSideRoadProvider ||
        engine == null ||
        route == null ||
        _phase != NavPhase.navigating) {
      return;
    }
    _lastSideRoadCacheVersion = -1;
    _lastAppliedSideRoads = const [];
    provider.prefetchRoute(
      route.polyline,
      _latestPosition ?? route.polyline.first,
      (loadedNear) {
        final position = _latestPosition;
        if (_disposed ||
            _phase != NavPhase.navigating ||
            _engine != engine ||
            _rerouting ||
            _awaitingValidRoute ||
            position is! NavigationFix ||
            !position.accuracy.isFinite ||
            position.accuracy > 50 ||
            DateTime.now().difference(position.timestamp).abs() >=
                const Duration(seconds: 10) ||
            position.distanceTo(loadedNear) > 600) {
          return;
        }
        if (_applyCachedSideRoads(position)) {
          final refreshed = engine.update(position);
          _current = refreshed;
          _notify();
          unawaited(ble.send(refreshed));
        }
      },
    );
    if (_latestPosition != null) _applyCachedSideRoads(_latestPosition!);
  }

  void _warmPreviewSideRoads() {
    final provider = _sideRoads;
    final route = selectedRoute;
    if (provider is! RouteSideRoadProvider ||
        route == null ||
        route.polyline.length < 2 ||
        _phase != NavPhase.idle) {
      return;
    }
    // Preview uses the same route tiles but never sends guidance to BLE.
    // The tile futures survive cancelPrefetch, so starting navigation can
    // reuse completed or in-flight downloads without waiting for them.
    provider.prefetchRoute(
      route.polyline,
      _latestPosition ?? route.polyline.first,
      (_) {},
    );
  }

  bool _applyCachedSideRoads(LatLng position) {
    final provider = _sideRoads;
    final engine = _engine;
    if (provider is! RouteSideRoadProvider || engine == null) return false;
    final moved =
        _sideRoadRefreshPosition == null ||
        _sideRoadRefreshPosition!.distanceTo(position) >= 80;
    if (!moved && provider.cacheVersion == _lastSideRoadCacheVersion) {
      return false;
    }
    _lastSideRoadCacheVersion = provider.cacheVersion;
    _sideRoadRefreshPosition = position;
    final roads = provider.cachedSideRoadsNear(position);
    if (listEquals(roads, _lastAppliedSideRoads)) return false;
    _lastAppliedSideRoads = roads;
    engine.replaceSideRoads(roads);
    return true;
  }

  Future<void> _maybeRefreshSideRoads(LatLng position) async {
    if (_disposed || _refreshingSideRoads) return;
    final now = DateTime.now();
    final lastAt = _lastSideRoadRefreshAt;
    final lastPosition = _sideRoadRefreshPosition;
    final isRecent =
        lastAt != null &&
        now.difference(lastAt) < NavigationController._sideRoadRefreshInterval;
    final hasNotMovedFar =
        lastPosition != null &&
        lastPosition.distanceTo(position) <
            NavigationController._sideRoadRefreshDistanceMeters;
    if (isRecent && hasNotMovedFar) return;

    _refreshingSideRoads = true;
    _lastSideRoadRefreshAt = now;
    _sideRoadRefreshPosition = position;
    try {
      final roads = await _sideRoads.fetchSideRoadsNear(position);
      if (_disposed) return;
      // Keep the previous road context during a temporary network/API failure.
      if (roads.isNotEmpty) {
        final engine = _engine;
        engine?.replaceSideRoads(roads);
        if (kDebugMode) {
          debugPrint('[SIDE_ROADS] navigation engine loaded ${roads.length}');
        }
        final latest = _latestPosition;
        if (engine != null &&
            latest != null &&
            !_rerouting &&
            !_awaitingValidRoute &&
            _current?.rerouting != true &&
            _phase == NavPhase.navigating) {
          final refreshed = engine.update(latest);
          _current = refreshed;
          _notify();
          await ble.send(refreshed);
        }
      }
    } catch (error) {
      // Side roads are supplementary; navigation must continue uninterrupted.
      if (kDebugMode) debugPrint('[SIDE_ROADS] refresh failed: $error');
    } finally {
      _refreshingSideRoads = false;
    }
  }

  void _recordMapDiagnostic(String event) {
    if (event == 'tap_received' ||
        event == 'region_changed' ||
        const {'fit_skipped_active_gesture', 'fit_requested'}.contains(event) ||
        RegExp(r'^update_ms=\d{1,9}$').hasMatch(event) ||
        // The map reset gesture recognizers UIKit left stuck.
        RegExp(
          r'^recognizers_reset reason=(sequence_end|missed_touch) '
          r'count=\d{1,3} states=[0-9/,]{1,300}$',
        ).hasMatch(event) ||
        event == 'view_recreate' ||
        RegExp(r'^gate_reattach count=\d{1,3}$').hasMatch(event) ||
        // Which touch-gate recognizer holds a touch the map never received.
        RegExp(
          r'^touch_gate observer=\d/\d{1,2} '
          r'ancestors=[0-9A-Za-z_:/,|]{1,600}$',
        ).hasMatch(event)) {
      _log('map $event');
    }
  }

  void _log(String event) {
    _diagnostics.add('${DateTime.now().toUtc().toIso8601String()} $event');
    if (_diagnostics.length > 200) _diagnostics.removeAt(0);
  }
}
