import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/route_candidate.dart';
import '../services/directions_service.dart';
import '../services/location_service.dart';
import '../services/navigation_ports.dart';
import '../services/navigation_engine.dart';

enum NavPhase { idle, routing, navigating, paused, arrived, error }

/// Orchestrates the full data flow:
///   location -> DirectionsService -> NavigationEngine -> BleService.
///
/// Exposes state to the UI via [ChangeNotifier].
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.ble,
    RouteProvider? directions,
    PositionProvider? location,
  })  : _directions = directions ?? DirectionsService(),
        _location = location ?? LocationService();

  final NavigationBlePort ble;
  final RouteProvider _directions;
  final PositionProvider _location;

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

  NavigationEngine? _engine;
  StreamSubscription<LatLng>? _posSub;
  bool _rerouting = false;
  int _offRouteSamples = 0;
  DateTime? _lastRerouteAt;
  DateTime? _rerouteNoticeUntil;
  Timer? _rerouteNoticeTimer;

  static const int _offRouteSamplesBeforeReroute = 3;
  static const Duration _minRerouteInterval = Duration(seconds: 10);
  static const Duration _rerouteNoticeDuration = Duration(seconds: 3);

  void _set(NavPhase p, {String? error}) {
    _phase = p;
    _error = error;
    notifyListeners();
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
      _setRouteOptions(routes, selectedIndex: 0);
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
    if (_phase == NavPhase.arrived || _phase == NavPhase.paused) return;
    _latestPosition = pos;

    final engine = _engine;
    if (engine == null) return;

    if (await _maybeReroute(pos)) return;

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
    if (engine == null || destination == null) return false;
    if (_rerouting) {
      _showRerouteNotice('正在重新规划路线');
      return true;
    }

    if (!engine.isOffRoute(pos)) {
      _offRouteSamples = 0;
      return false;
    }

    _offRouteSamples++;
    if (_offRouteSamples < _offRouteSamplesBeforeReroute) {
      _showRerouteNotice('已偏离路线，正在重新规划');
      // Treat the first couple of off-route samples as confirmation only.
      // GPS drift and simplified route geometry can briefly look off-route; if
      // we block normal updates here, the ESP32 freezes on an old instruction
      // exactly when the rider may be approaching a real turn.
      return false;
    }

    final now = DateTime.now();
    final last = _lastRerouteAt;
    if (last != null && now.difference(last) < _minRerouteInterval) {
      _showRerouteNotice('正在重新规划路线');
      return true;
    }

    _rerouting = true;
    _lastRerouteAt = now;
    _offRouteSamples = 0;
    _showRerouteNotice('已偏离路线，正在重新规划');

    try {
      final routes = await _directions.fetchRoutes(
        origin: pos,
        destination: destination,
      );
      _origin = pos;
      _setRouteOptions(routes, selectedIndex: 0);
      _set(NavPhase.navigating);

      final navState = _engine!.update(pos);
      _current = navState;
      notifyListeners();
      await ble.send(navState);
      return true;
    } catch (e) {
      _set(NavPhase.navigating, error: '重新规划失败: $e');
      return true;
    } finally {
      _rerouting = false;
    }
  }

  Future<void> selectRoute(int index) async {
    if (index < 0 || index >= _routeOptions.length) return;
    if (index == _selectedRouteIndex) return;
    if (_phase == NavPhase.idle || _phase == NavPhase.error) return;

    _selectedRouteIndex = index;
    _engine = NavigationEngine(_routeOptions[index].steps);
    _offRouteSamples = 0;

    final origin = _latestPosition ?? _origin;
    if (origin != null) {
      final navState = _engine!.update(origin);
      _current = navState;
      await ble.send(navState);
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
    _engine = NavigationEngine(_routeOptions[_selectedRouteIndex].steps);
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
    // Lost the GPS fix — tell the device to show STOP so the rider isn't given
    // a stale/misleading instruction.
    _current = NavState.stopped;
    _set(NavPhase.navigating, error: 'GPS signal lost');
    ble.send(NavState.stopped);
  }

  /// Temporarily pause navigation: park the device on STOP and stop consuming
  /// positions, but keep the route/destination so the rider can start again
  /// without re-searching.
  Future<void> pause() async {
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
    _rerouteNoticeUntil = null;
    _rerouteNoticeTimer?.cancel();
    _rerouteNoticeTimer = null;
    _set(NavPhase.idle);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _rerouteNoticeTimer?.cancel();
    _directions.dispose();
    super.dispose();
  }
}
