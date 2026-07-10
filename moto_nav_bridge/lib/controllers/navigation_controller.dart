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

    final navState = engine.update(pos);
    _current = navState;

    if (engine.isFinished) {
      _set(NavPhase.arrived);
    } else {
      notifyListeners();
    }

    await ble.send(navState);
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
    _set(NavPhase.idle);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _directions.dispose();
    super.dispose();
  }
}
