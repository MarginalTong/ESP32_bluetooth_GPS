import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../services/ble_service.dart';
import '../services/directions_service.dart';
import '../services/location_service.dart';
import '../services/navigation_engine.dart';

enum NavPhase { idle, routing, navigating, arrived, error }

/// Orchestrates the full data flow:
///   location -> DirectionsService -> NavigationEngine -> BleService.
///
/// Exposes state to the UI via [ChangeNotifier].
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.ble,
    DirectionsService? directions,
    LocationService? location,
  })  : _directions = directions ?? DirectionsService(),
        _location = location ?? LocationService();

  final BleService ble;
  final DirectionsService _directions;
  final LocationService _location;

  NavPhase _phase = NavPhase.idle;
  NavPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  NavState? _current;
  NavState? get current => _current;

  LatLng? _origin;
  LatLng? get origin => _origin;

  LatLng? _destination;
  LatLng? get destination => _destination;

  NavigationEngine? _engine;
  StreamSubscription<LatLng>? _posSub;
  bool _rerouting = false;
  int _offRouteSamples = 0;
  DateTime? _lastRerouteAt;

  static const int _offRouteSamplesBeforeReroute = 3;
  static const Duration _minRerouteInterval = Duration(seconds: 15);

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
      _destination = destination;
      notifyListeners();
      final steps = await _directions.fetchRoute(
        origin: origin,
        destination: destination,
      );
      _engine = NavigationEngine(steps);
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
  }

  Future<bool> _maybeReroute(LatLng pos) async {
    final engine = _engine;
    final destination = _destination;
    if (engine == null || destination == null || _rerouting) return false;

    if (!engine.isOffRoute(pos)) {
      _offRouteSamples = 0;
      return false;
    }

    _offRouteSamples++;
    if (_offRouteSamples < _offRouteSamplesBeforeReroute) return false;

    final now = DateTime.now();
    final last = _lastRerouteAt;
    if (last != null && now.difference(last) < _minRerouteInterval) {
      return false;
    }

    _rerouting = true;
    _lastRerouteAt = now;
    _offRouteSamples = 0;
    _set(NavPhase.routing);

    try {
      final steps = await _directions.fetchRoute(
        origin: pos,
        destination: destination,
      );
      _origin = pos;
      _engine = NavigationEngine(steps);
      _set(NavPhase.navigating);

      final navState = _engine!.update(pos);
      _current = navState;
      notifyListeners();
      await ble.send(navState);
      return true;
    } catch (e) {
      _set(NavPhase.navigating, error: '重新规划失败: $e');
      return false;
    } finally {
      _rerouting = false;
    }
  }

  void _onPositionError(Object e) {
    // Lost the GPS fix — tell the device to show STOP so the rider isn't given
    // a stale/misleading instruction.
    _current = NavState.stopped;
    _set(NavPhase.navigating, error: 'GPS signal lost');
    ble.send(NavState.stopped);
  }

  /// Manually pause: park the device on STOP and stop consuming positions.
  Future<void> pause() async {
    await _posSub?.cancel();
    _posSub = null;
    _current = NavState.stopped;
    await ble.send(NavState.stopped);
    _set(NavPhase.idle);
  }

  Future<void> stopNavigation() async {
    await _posSub?.cancel();
    _posSub = null;
    _engine = null;
    _current = null;
    _origin = null;
    _destination = null;
    _rerouting = false;
    _offRouteSamples = 0;
    _lastRerouteAt = null;
    _set(NavPhase.idle);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _directions.dispose();
    super.dispose();
  }
}
