import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/route_candidate.dart';
import '../services/directions_service.dart';
import '../services/location_service.dart';
import '../services/navigation_ports.dart';
import '../services/navigation_engine.dart';
import '../services/side_road_service.dart';
import '../services/route_alignment.dart';
import '../services/route_preference.dart';
import '../services/valhalla_directions_service.dart';

enum NavPhase { idle, routing, navigating, paused, arrived, error }

/// Orchestrates the full data flow:
///   location -> ValhallaDirectionsService -> NavigationEngine -> BleService.
///
/// Exposes state to the UI via [ChangeNotifier].
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.ble,
    RouteProvider? directions,
    RouteProvider? rerouteDirections,
    PositionProvider? location,
    SideRoadProvider? sideRoads,
  })  : _directions = directions ?? ValhallaDirectionsService(),
        _location = location ?? LocationService(),
        _sideRoads = sideRoads ?? SideRoadService() {
    _rerouteDirections = rerouteDirections ?? _directions;
  }

  final NavigationBlePort ble;
  final RouteProvider _directions;
  late final RouteProvider _rerouteDirections;
  final PositionProvider _location;
  final SideRoadProvider _sideRoads;

  NavPhase _phase = NavPhase.idle;
  NavPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  NavState? _current;
  NavState? get current => _current;

  LatLng? _origin;
  LatLng? get origin => _origin;

  LatLng? _latestPosition;

  LatLng? _destination;
  LatLng? get destination => _destination;

  List<RouteCandidate> _routeOptions = const [];
  List<RouteCandidate> get routeOptions => _routeOptions;

  int _selectedRouteIndex = 0;
  int get selectedRouteIndex => _selectedRouteIndex;

  RouteCandidate? get selectedRoute =>
      _routeOptions.isEmpty ? null : _routeOptions[_selectedRouteIndex];

  bool _previewingRoute = false;
  bool get previewingRoute => _previewingRoute;

  NavigationEngine? _engine;
  StreamSubscription<LatLng>? _posSub;
  bool _rerouting = false;
  bool _awaitingValidRoute = false;
  bool _disposed = false;
  int _rerouteRequestId = 0;
  String? _rerouteFailure;
  int _offRouteSamples = 0;
  DateTime? _lastRerouteAt;
  DateTime? _rerouteNoticeUntil;
  Timer? _rerouteNoticeTimer;
  bool _refreshingSideRoads = false;
  LatLng? _sideRoadRefreshPosition;
  DateTime? _lastSideRoadRefreshAt;

  static const int _offRouteSamplesBeforeReroute = 2;
  DateTime? _lastAcceptedFixAt;
  static const Duration _minRerouteInterval = Duration(seconds: 10);
  static const Duration _rerouteNoticeDuration = Duration(seconds: 3);
  static const Duration _sideRoadRefreshInterval = Duration(seconds: 20);
  static const double _sideRoadRefreshDistanceMeters = 80;

  void _set(NavPhase p, {String? error}) {
    if (_disposed) return;
    _phase = p;
    _error = error;
    notifyListeners();
  }

  /// Builds route options for the destination panel without starting live
  /// navigation or writing instructions to the ESP32.
  Future<void> previewDestination(LatLng destination) async {
    if (_phase != NavPhase.idle && _phase != NavPhase.error) return;

    _destination = destination;
    _previewingRoute = true;
    _error = null;
    notifyListeners();

    if (!await _location.ensurePermission()) {
      _previewingRoute = false;
      _set(NavPhase.error, error: 'Location permission/service unavailable');
      return;
    }

    try {
      final origin = await _location.currentPosition();
      _origin = origin;
      _latestPosition = origin;
      final routes = await _directions.fetchRoutes(
        origin: origin,
        destination: destination,
      );
      _setRouteOptions(routes, selectedIndex: preferredRouteIndex(routes));
    } catch (e) {
      _error = e.toString();
    } finally {
      _previewingRoute = false;
      notifyListeners();
    }
  }

  /// Builds a route from the current location to [destination] and starts
  /// streaming navigation updates to the device.
  Future<void> startNavigation(LatLng destination) async {
    await stopNavigation();

    if (!await _location.ensurePermission()) {
      _set(NavPhase.error, error: 'Location permission/service unavailable');
      return;
    }

    _set(NavPhase.routing);
    try {
      final origin = await _location.currentPosition();
      _origin = origin;
      _latestPosition = origin;
      _destination = destination;
      notifyListeners();
      final routes = await _directions.fetchRoutes(
        origin: origin,
        destination: destination,
      );
      // Route planning must not wait for supplementary map context. Nearby
      // junctions are fetched in the background after navigation starts.
      _setRouteOptions(routes, selectedIndex: preferredRouteIndex(routes));
    } catch (e) {
      _set(NavPhase.error, error: e.toString());
      return;
    }

    _set(NavPhase.navigating);
    _posSub = _location.positionStream().listen(
          _onPosition,
          onError: (Object e) => _onPositionError(e),
        );
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

    unawaited(_maybeRefreshSideRoads(pos));

    final navState = engine.update(pos);
    _current = navState;

    if (engine.isFinished) {
      _set(NavPhase.arrived);
    } else {
      notifyListeners();
    }

    await ble.send(navState);

    if (engine.isFinished) {
      await _posSub?.cancel();
      _posSub = null;
    }
  }

  Future<bool> _maybeReroute(LatLng pos) async {
    final engine = _engine;
    final destination = _destination;
    final text = AppText.system;
    if (engine == null || destination == null) return false;
    if (_rerouting) {
      _showRerouteNotice(text.rerouting);
      return true;
    }

    if (pos is NavigationFix &&
        (!pos.accuracy.isFinite || pos.accuracy < 0 || pos.accuracy > 50)) {
      _offRouteSamples = 0;
      return _awaitingValidRoute;
    }

    if (!engine.isOffRoute(pos)) {
      _offRouteSamples = 0;
      if (_awaitingValidRoute) {
        // Recovery onto the old route is allowed only after a fresh position
        // matches it again, never merely because the HTTP request failed.
        _awaitingValidRoute = false;
        _rerouteFailure = null;
        _clearRerouteNotice();
        _error = null;
      }
      return false;
    }

    _offRouteSamples++;
    if (_offRouteSamples < _offRouteSamplesBeforeReroute) {
      if (_awaitingValidRoute) return true;
      _showRerouteNotice(text.offRouteRerouting);
      // Treat the first couple of off-route samples as confirmation only.
      // GPS drift and simplified route geometry can briefly look off-route; if
      // we block normal updates here, the ESP32 freezes on an old instruction
      // exactly when the rider may be approaching a real turn.
      return false;
    }

    final now = DateTime.now();
    final last = _lastRerouteAt;
    if (last != null && now.difference(last) < _minRerouteInterval) {
      if (_rerouteFailure == null) {
        _showRerouteNotice(text.rerouting);
        _current = NavState.recalculating;
        await ble.send(NavState.recalculating);
      }
      return true;
    }

    _rerouting = true;
    _awaitingValidRoute = true;
    _rerouteFailure = null;
    final requestId = ++_rerouteRequestId;
    _lastRerouteAt = now;
    _offRouteSamples = 0;
    _showRerouteNotice(text.offRouteRerouting);
    _current = NavState.recalculating;
    notifyListeners();

    try {
      unawaited(ble.send(NavState.recalculating));
      final routes = await _rerouteDirections.fetchRoutes(
        origin: pos,
        destination: destination,
      );
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
      final alignedRoutes =
          routes.map((r) => RouteAlignment.trim(r, pos, latest)).toList();
      final selected = preferredRouteIndex(alignedRoutes, eligible: (route) {
        // Heading on the API request is a preference, not a guarantee. Reject
        // stale/distant or reverse-going starts rather than silently falling
        // back to a route which points back at the missed junction.
        return !RouteAlignment.conflictsWithCourse(route, latest) &&
            !NavigationEngine(route.steps).isOffRoute(latest);
      });
      if (selected < 0) {
        throw DirectionsException(
            'No reroute matches the current position and travel direction');
      }
      _origin = latest;
      _setRouteOptions(alignedRoutes, selectedIndex: selected);
      _awaitingValidRoute = false;
      _clearRerouteNotice();
      _lastSideRoadRefreshAt = null;
      _sideRoadRefreshPosition = null;
      unawaited(_maybeRefreshSideRoads(pos));
      _set(NavPhase.navigating);

      final navState = _engine!.update(_latestPosition ?? pos);
      _current = navState;
      notifyListeners();
      await ble.send(navState);
      return true;
    } catch (e) {
      if (!_isCurrentReroute(requestId, engine, destination)) return true;
      // Do not remain on an endless "updating" screen or revive a known-bad
      // maneuver. Keep the route visible for context, but withdraw guidance.
      _rerouteFailure = text.rerouteFailed(e);
      _clearRerouteNotice();
      _current = NavState.stopped;
      _set(NavPhase.navigating, error: _rerouteFailure);
      await ble.send(NavState.stopped);
      return true;
    } finally {
      if (_rerouteRequestId == requestId) _rerouting = false;
    }
  }

  bool _isCurrentReroute(
          int requestId, NavigationEngine engine, LatLng destination) =>
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
    _rerouteRequestId++;
    _rerouting = false;
    _awaitingValidRoute = false;
    _rerouteFailure = null;
    _clearRerouteNotice();
  }

  Future<void> selectRoute(int index) async {
    if (_disposed || _phase == NavPhase.paused) return;
    if (index < 0 || index >= _routeOptions.length) return;
    if (index == _selectedRouteIndex) return;
    if (_phase == NavPhase.idle || _phase == NavPhase.error) return;

    _invalidateReroute();
    _error = null;
    _selectedRouteIndex = index;
    _engine = NavigationEngine(
      _routeOptions[index].steps,
      sideRoads: _routeOptions[index].sideRoads,
    );
    _offRouteSamples = 0;
    _lastSideRoadRefreshAt = null;
    _sideRoadRefreshPosition = null;

    final origin = _latestPosition ?? _origin;
    if (origin != null) {
      final navState = _engine!.update(origin);
      _current = navState;
      await ble.send(navState);
      unawaited(_maybeRefreshSideRoads(origin));
    }

    notifyListeners();
  }

  void _setRouteOptions(
    List<RouteCandidate> routes, {
    required int selectedIndex,
  }) {
    if (routes.isEmpty) {
      throw DirectionsException('No usable routes returned');
    }
    _routeOptions = List.unmodifiable(routes);
    _selectedRouteIndex = selectedIndex.clamp(0, routes.length - 1);
    final selected = _routeOptions[_selectedRouteIndex];
    _engine = NavigationEngine(selected.steps, sideRoads: selected.sideRoads);
  }

  Future<void> _maybeRefreshSideRoads(LatLng position) async {
    if (_disposed || _refreshingSideRoads) return;
    final now = DateTime.now();
    final lastAt = _lastSideRoadRefreshAt;
    final lastPosition = _sideRoadRefreshPosition;
    final isRecent =
        lastAt != null && now.difference(lastAt) < _sideRoadRefreshInterval;
    final hasNotMovedFar = lastPosition != null &&
        lastPosition.distanceTo(position) < _sideRoadRefreshDistanceMeters;
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
          notifyListeners();
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

  void _showRerouteNotice(String message) {
    final now = DateTime.now();
    final until = _rerouteNoticeUntil;
    if (until != null && now.isBefore(until)) return;

    _rerouteNoticeUntil = now.add(_rerouteNoticeDuration);
    _set(NavPhase.navigating, error: message);

    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = Timer(_rerouteNoticeDuration, () {
      _rerouteNoticeUntil = null;
      if (_phase == NavPhase.navigating && _error == message) {
        _set(NavPhase.navigating);
      }
    });
  }

  void _onPositionError(Object e) {
    if (_disposed || _phase != NavPhase.navigating) return;
    _invalidateReroute();
    // Lost the GPS fix — tell the device to show STOP so the rider isn't given
    // a stale/misleading instruction.
    _current = NavState.stopped;
    _set(NavPhase.navigating, error: AppText.system.gpsSignalLost);
    ble.send(NavState.stopped);
  }

  /// Temporarily pause navigation: park the device on STOP and stop consuming
  /// positions, but keep the route/destination so the rider can start again
  /// without re-searching.
  Future<void> pause() async {
    _invalidateReroute();
    await _posSub?.cancel();
    _posSub = null;
    _current = NavState.stopped;
    await ble.send(NavState.stopped);
    _set(NavPhase.paused);
  }

  Future<void> stopNavigation() async {
    await _clearNavigationState(sendStopToDevice: false);
  }

  /// Fully end the current trip. This is intentionally stronger than [pause]:
  /// it clears route/navigation state and can release the BLE link so the next
  /// session starts from a clean scan/connect cycle.
  Future<void> endNavigation({bool disconnectDevice = true}) async {
    await _clearNavigationState(sendStopToDevice: true);
    if (disconnectDevice) {
      await ble.disconnect();
    }
  }

  Future<void> _clearNavigationState({required bool sendStopToDevice}) async {
    _invalidateReroute();
    await _posSub?.cancel();
    _posSub = null;
    if (sendStopToDevice) {
      await ble.send(NavState.stopped);
    }
    _engine = null;
    _current = null;
    _origin = null;
    _latestPosition = null;
    _destination = null;
    _routeOptions = const [];
    _selectedRouteIndex = 0;
    _rerouting = false;
    _offRouteSamples = 0;
    _lastRerouteAt = null;
    _lastAcceptedFixAt = null;
    _rerouteNoticeUntil = null;
    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = null;
    _refreshingSideRoads = false;
    _sideRoadRefreshPosition = null;
    _lastSideRoadRefreshAt = null;
    _set(NavPhase.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateReroute();
    _posSub?.cancel();
    _rerouteNoticeTimer?.cancel();
    _directions.dispose();
    if (!identical(_directions, _rerouteDirections)) {
      _rerouteDirections.dispose();
    }
    _sideRoads.dispose();
    super.dispose();
  }
}
