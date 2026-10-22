import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';

import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/road_segment.dart';
import '../services/nearby_places.dart';
import '../models/nav_state.dart';
import '../models/device_direction.dart';
import '../models/route_candidate.dart';
import '../services/directions_exception.dart';
import '../services/location_service.dart';
import '../services/navigation_ports.dart';
import '../services/navigation_engine.dart';
import '../services/side_road_service.dart';
import '../services/route_alignment.dart';
import '../services/voice_navigation_query.dart';
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
    SharedPreferences? preferences,
  })  : _preferences = preferences,
        _location = location ?? LocationService(),
        _sideRoads = sideRoads ?? SideRoadService() {
    _directions = directions ??
        ValhallaDirectionsService(routePreferences: () => _tripPreferences);
    _rerouteDirections = rerouteDirections ?? _directions;
    final saved = _preferences?.getString(_preferencesKey);
    if (saved != null) {
      try {
        final value = jsonDecode(saved) as Map<String, dynamic>;
        avoidHighways = value['highways'] == true;
        avoidTolls = value['tolls'] == true;
        avoidFerries = value['ferries'] == true;
        avoidTunnels = value['tunnels'] == true;
      } catch (_) {
        // Invalid local data falls back to defaults.
      }
    }
  }

  final SharedPreferences? _preferences;
  // Keep the existing storage key so upgrading preserves previous choices.
  // The obsolete testUnlock field is deliberately ignored.
  static const _preferencesKey = 'route_preferences_test_v1';

  Future<void> savePreferences(
      {required bool highways,
      required bool tolls,
      required bool ferries,
      bool tunnels = false}) async {
    if (!canEditPreferences) throw StateError('Navigation is active');
    final store = _preferences ?? await SharedPreferences.getInstance();
    final saved = await store.setString(
        _preferencesKey,
        jsonEncode({
          'highways': highways,
          'tolls': tolls,
          'ferries': ferries,
          'tunnels': tunnels,
        }));
    if (!saved) throw StateError('Preferences could not be saved');
    if (_disposed) return;
    updatePreferences(
        highways: highways, tolls: tolls, ferries: ferries, tunnels: tunnels);
  }

  final NavigationBlePort ble;
  late final RouteProvider _directions;
  bool avoidHighways = false, avoidTolls = false, avoidFerries = false;
  bool avoidTunnels = false;
  Map<String, Object> _tripPreferences = const {};
  bool get canEditPreferences =>
      !_previewingRoute &&
      (_phase == NavPhase.idle || _phase == NavPhase.error);

  void updatePreferences(
      {required bool highways,
      required bool tolls,
      required bool ferries,
      bool tunnels = false}) {
    if (!canEditPreferences) return;
    avoidHighways = highways;
    avoidTolls = tolls;
    avoidFerries = ferries;
    avoidTunnels = tunnels;
    // A preview made with old preferences must not remain selectable.
    if (_sideRoads is RouteSideRoadProvider) {
      (_sideRoads as RouteSideRoadProvider).cancelPrefetch();
    }
    _routeOptions = const [];
    _selectedRouteIndex = 0;
    _engine = null;
    notifyListeners();
  }

  void _snapshotPreferences() {
    _tripPreferences = {
      if (avoidHighways) 'use_highways': 0.0,
      if (avoidTolls) 'use_tolls': 0.0,
      if (avoidFerries) 'use_ferry': 0.0,
      if (avoidTunnels) 'exclude_tunnels': true,
    };
  }

  /// Place search needs a measured location, not a valid turn announcement.
  /// These are different safety checks: a stationary phone can stop receiving
  /// stream callbacks while the active route itself remains valid.
  LatLng? get voiceSearchOrigin {
    if (_disposed ||
        _phase != NavPhase.navigating ||
        _destination == null ||
        _rerouting ||
        _awaitingValidRoute) {
      return null;
    }
    final fix = _latestPosition;
    return _usableVoiceFix(fix) ? fix : null;
  }

  bool _usableVoiceFix(LatLng? value) =>
      value is NavigationFix &&
      value.accuracy.isFinite &&
      value.accuracy >= 0 &&
      value.accuracy <= 50 &&
      DateTime.now().difference(value.timestamp).abs() <
          const Duration(seconds: 45);

  /// Refresh only when the navigation stream has gone quiet. A one-shot fix
  /// is never used to advance a maneuver or silently replace the route.
  Future<LatLng?> refreshVoiceSearchOrigin() async {
    final existing = voiceSearchOrigin;
    if (existing != null) return existing;
    if (_disposed ||
        _phase != NavPhase.navigating ||
        _destination == null ||
        _rerouting ||
        _awaitingValidRoute) {
      return null;
    }
    final destination = _destination;
    try {
      final measured =
          await _location.currentPosition().timeout(const Duration(seconds: 8));
      if (_disposed ||
          _phase != NavPhase.navigating ||
          !identical(destination, _destination) ||
          _rerouting ||
          _awaitingValidRoute ||
          !_usableVoiceFix(measured)) {
        return null;
      }
      // A newer stream fix wins; do not overwrite it with an older snapshot.
      final latest = _latestPosition;
      if (latest is NavigationFix &&
          latest.timestamp.isAfter((measured as NavigationFix).timestamp)) {
        return voiceSearchOrigin;
      }
      _latestPosition = measured;
      return measured;
    } catch (_) {
      return null;
    }
  }

  Future<List<NearbyChoice>> rankNearbyPlaces(List<PlaceResult> places,
      LatLng origin, bool Function() isCurrent) async {
    final destination = _destination;
    bool valid() =>
        !_disposed &&
        isCurrent() &&
        identical(destination, _destination) &&
        voiceSearchOrigin != null &&
        origin.distanceTo(voiceSearchOrigin!) <= 250;
    final ranked = <NearbyChoice>[];
    for (final place in places.take(5)) {
      if (!valid()) return const [];
      try {
        final routes = await _directions
            .fetchRoutes(origin: origin, destination: place.location)
            .timeout(const Duration(seconds: 8));
        if (!valid()) return const [];
        final usable = routes
            .where((r) =>
                r.steps.isNotEmpty &&
                r.steps.last.end.distanceTo(place.location) <= 200 &&
                !RouteAlignment.conflictsWithCourse(r, origin) &&
                !NavigationEngine(r.steps).isOffRoute(origin) &&
                r.expectedTravelTimeSeconds != null &&
                r.expectedTravelTimeSeconds! > 0)
            .toList();
        if (usable.isEmpty) continue;
        final route =
            usable[preferredRouteIndex(usable, avoidEarlyUTurns: true)];
        ranked.add(NearbyChoice(place, route.expectedTravelTimeSeconds!));
      } catch (_) {/* Unreachable or timed out: never invent an ETA. */}
    }
    ranked.sort((a, b) => a.seconds.compareTo(b.seconds));
    return valid() ? ranked : const [];
  }

  late final RouteProvider _rerouteDirections;
  final PositionProvider _location;
  final SideRoadProvider _sideRoads;

  NavPhase _phase = NavPhase.idle;
  NavPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  NavState? _current;
  NavState? _lastReliableNavState;
  NavState? get current => _current;
  bool get voiceGuidanceReliable {
    final fix = _latestPosition;
    return !_disposed &&
        _phase == NavPhase.navigating &&
        _current?.direction != DeviceDirection.stop &&
        !_rerouting &&
        !_awaitingValidRoute &&
        _current != null &&
        fix is NavigationFix &&
        fix.accuracy.isFinite &&
        fix.accuracy >= 0 &&
        fix.accuracy <= 50 &&
        DateTime.now().difference(fix.timestamp).abs() <
            const Duration(seconds: 10);
  }

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
  int get voiceStepIndex => _engine?.currentStepIndex ?? 0;
  int? get voiceRemainingSeconds {
    final position = _latestPosition;
    final route = selectedRoute;
    if (_disposed ||
        _phase != NavPhase.navigating ||
        _rerouting ||
        _awaitingValidRoute ||
        position is! NavigationFix ||
        route == null ||
        !position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > 75 ||
        DateTime.now().difference(position.timestamp).abs() >=
            const Duration(seconds: 60)) {
      return null;
    }
    return estimateRemainingRouteSeconds(route, position, voiceStepIndex,
        maxDistanceMeters: (position.accuracy * 2).clamp(25, 120).toDouble());
  }

  StreamSubscription<LatLng>? _posSub;
  Timer? _gpsRestartTimer;
  Timer? _heartbeatTimer;
  bool _heartbeatBusy = false;

  /// The stream's distance filter emits nothing while the bike is stopped, and
  /// the display flags guidance as stale after 8 s without a packet. A
  /// one-shot fix proves positioning is still live before the current state is
  /// re-sent, so a genuinely stalled GPS still shows as stale.
  ///
  /// Heartbeat fixes are liveness evidence only. They never reach the
  /// off-route matcher or advance a maneuver: stationary GPS jitter, which the
  /// distance filter used to absorb, must not trigger a reroute at a red light.
  static const Duration _heartbeatInterval = Duration(seconds: 2);
  static const Duration _heartbeatFixTimeout = Duration(seconds: 4);
  static const double _heartbeatMinDriftMeters = 30;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(_heartbeatInterval, (_) => unawaited(_heartbeat()));
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _heartbeat() async {
    final last = _lastAcceptedFixAt;
    if (_heartbeatBusy ||
        _disposed ||
        _phase != NavPhase.navigating ||
        _posSub == null ||
        _engine == null ||
        _rerouting ||
        _awaitingValidRoute ||
        (last != null &&
            DateTime.now().difference(last) < _heartbeatInterval)) {
      return;
    }
    // Identify this trip so a result arriving after stop/start or a route
    // change is discarded instead of being applied to the new trip.
    final engine = _engine;
    final subscription = _posSub;
    _heartbeatBusy = true;
    try {
      final fix =
          await _location.currentPosition().timeout(_heartbeatFixTimeout);
      final anchor = _latestPosition;
      final state = _current;
      if (_disposed ||
          _phase != NavPhase.navigating ||
          !identical(_engine, engine) ||
          !identical(_posSub, subscription) ||
          _rerouting ||
          _awaitingValidRoute ||
          fix is! NavigationFix ||
          !_usableVoiceFix(fix) ||
          DateTime.now().difference(fix.timestamp).abs() >
              const Duration(seconds: 10) ||
          anchor == null ||
          state == null ||
          state.rerouting ||
          state.direction == DeviceDirection.stop) {
        return;
      }
      // Beyond jitter the bike has really moved: leave that to the stream,
      // which applies the full matcher. Sending nothing keeps the display
      // honest if the stream has stalled while moving.
      final drift = math.max(_heartbeatMinDriftMeters, fix.accuracy * 2);
      if (fix.distanceTo(anchor) > drift) return;
      await ble.send(state);
    } catch (_) {
      // No fresh fix: send nothing, so the display reports stale guidance.
    } finally {
      _heartbeatBusy = false;
    }
  }

  bool _rerouting = false;
  bool _awaitingValidRoute = false;
  Timer? _recoveryTimer;
  final List<String> _diagnostics = [];
  String get diagnostics => _diagnostics.join('\n');
  void clearDiagnostics() => _diagnostics.clear();
  void recordMapDiagnostic(String event) {
    if (event == 'tap_received' ||
        event == 'region_changed' ||
        const {
          'route_preview_started',
          'route_preview_stopped',
          'fit_skipped_active_gesture',
          'fit_requested',
        }.contains(event) ||
        RegExp(r'^update_ms=\d{1,9}$').hasMatch(event)) {
      _log('map $event');
    }
  }

  void recordAgentDiagnostic(String event) {
    if (const {
      'opened',
      'closed',
      'wake_started',
      'wake_stopped',
      'wake_paused_background',
      'wake_paused_interruption',
      'wake_paused_route',
      'wake_resume_foreground',
      'wake_resume_interruption',
      'wake_resume_route',
      'wake_listening_en',
      'wake_listening_zh',
      'wake_unavailable'
    }.contains(event)) {
      _log('agent $event phase=${_phase.name}');
    }
  }

  void _log(String event) {
    _diagnostics.add('${DateTime.now().toUtc().toIso8601String()} $event');
    if (_diagnostics.length > 200) _diagnostics.removeAt(0);
  }

  String _fixDetails(LatLng pos) => pos is NavigationFix
      ? 'accuracy=${pos.accuracy} speed=${pos.speed} heading=${pos.heading} ageMs=${DateTime.now().difference(pos.timestamp).inMilliseconds}'
      : 'quality=unknown';

  void _scheduleRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(_minRerouteInterval, () async {
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
        _offRouteSamples = _offRouteSamplesBeforeReroute;
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
      _current = _engine?.update(pos);
      notifyListeners();
      if (_current != null) {
        _lastReliableNavState = _current;
        await ble.send(_current!);
      }
    }
  }

  bool _disposed = false;
  int _rerouteRequestId = 0;
  String? _rerouteFailure;
  int _offRouteSamples = 0;
  DateTime? _startedNavigationAt;
  DateTime? _lastRerouteAt;
  DateTime? _rerouteNoticeUntil;
  Timer? _rerouteNoticeTimer;
  bool _refreshingSideRoads = false;
  LatLng? _sideRoadRefreshPosition;
  DateTime? _lastSideRoadRefreshAt;
  int _lastSideRoadCacheVersion = -1;
  List<RoadSegment> _lastAppliedSideRoads = const [];

  static const int _offRouteSamplesBeforeReroute = 2;
  static const Duration _startMatchGrace = Duration(seconds: 15);
  DateTime? _lastAcceptedFixAt;
  static const Duration _minRerouteInterval = Duration(seconds: 10);
  static const Duration _rerouteNoticeDuration = Duration(seconds: 3);
  static const Duration _sideRoadRefreshInterval = Duration(seconds: 20);
  static const double _sideRoadRefreshDistanceMeters = 80;

  // Retain geometry only: an old turn or distance is unsafe after deviation.
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

    if (_sideRoads is RouteSideRoadProvider) {
      (_sideRoads as RouteSideRoadProvider).cancelPrefetch();
    }

    // A newer preview, Start or stop supersedes this request. Its late result
    // must never replace the active engine or another destination's routes.
    final requestId = ++_previewRequestId;
    bool current() =>
        !_disposed &&
        requestId == _previewRequestId &&
        (_phase == NavPhase.idle || _phase == NavPhase.error);

    _destination = destination;
    _previewingRoute = true;
    _snapshotPreferences();
    _error = null;
    notifyListeners();

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
      final routes = await _directions.fetchRoutes(
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
        notifyListeners();
      }
    }
  }

  int _previewRequestId = 0;

  /// Builds a route from the current location to [destination] and starts
  /// streaming navigation updates to the device.
  Future<void> startNavigation(LatLng destination) async {
    // A route picked on the preview map is an explicit user choice. Keep it
    // across the fresh route request made when the trip starts.
    final previewSelection = _phase == NavPhase.idle &&
            _destination != null &&
            _destination!.distanceTo(destination) < 5 &&
            _routeOptions.isNotEmpty
        ? _selectedRouteIndex
        : null;
    await stopNavigation();
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
      _destination = destination;
      notifyListeners();
      final routes = await _directions.fetchRoutes(
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

  void _listenForPositions() {
    if (_disposed || _phase != NavPhase.navigating || _posSub != null) return;
    try {
      _posSub = _location.positionStream().listen(
            _onPosition,
            onError: _onPositionError,
            onDone: () => _onPositionError(StateError('GPS stream ended')),
          );
      _log('gps_stream_started');
    } catch (error) {
      _onPositionError(error);
    }
  }

  void _scheduleGpsRestart() {
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = Timer(const Duration(seconds: 2), () async {
      _gpsRestartTimer = null;
      if (_disposed || _phase != NavPhase.navigating) return;
      _listenForPositions();
      if (_posSub == null) return;
      // A fresh one-shot fix can restore guidance even when the bike is still
      // and the restarted stream's distance filter has not emitted yet.
      try {
        final fix = await _location
            .currentPosition()
            .timeout(const Duration(seconds: 8));
        if (!_disposed &&
            _phase == NavPhase.navigating &&
            fix is NavigationFix &&
            _usableVoiceFix(fix)) {
          _log('gps_stream_recovered ${_fixDetails(fix)}');
          await _onPosition(fix);
        }
      } catch (_) {
        _log('gps_recovery_waiting_for_stream');
      }
    });
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

    if (_sideRoads is RouteSideRoadProvider) {
      (_sideRoads as RouteSideRoadProvider).advancePrefetch(pos);
      _applyCachedSideRoads(pos);
    } else {
      unawaited(_maybeRefreshSideRoads(pos));
    }

    final navState = engine.update(pos);
    _current = navState;
    if (_offRouteSamples == 0 && !_awaitingValidRoute) {
      _lastReliableNavState = navState;
    }

    if (engine.isFinished) {
      _set(NavPhase.arrived);
    } else if (_error == AppText.system.gpsSignalLost) {
      _set(NavPhase.navigating);
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
        _recoveryTimer?.cancel();
        _log('recovered_on_previous_route');
        _rerouteFailure = null;
        _clearRerouteNotice();
        _error = null;
      }
      return false;
    }

    // The first stream fix can differ from the fix used to request the route.
    // Near the origin at low speed, give GPS and road snapping time to settle.
    final started = _startedNavigationAt;
    final start = _origin;
    if (!_awaitingValidRoute &&
        started != null &&
        start != null &&
        DateTime.now().difference(started) < _startMatchGrace &&
        pos is NavigationFix &&
        pos.speed.isFinite &&
        pos.speed >= 0 &&
        pos.speed < 3 &&
        pos.distanceTo(start) <= (pos.accuracy * 3).clamp(40.0, 100.0)) {
      _offRouteSamples = 0;
      return false;
    }

    _offRouteSamples++;
    if (_offRouteSamples < _offRouteSamplesBeforeReroute) {
      if (_awaitingValidRoute) return true;
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
        _current = _temporaryRouteState();
        await ble.send(_current!);
      }
      return true;
    }

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
    notifyListeners();

    try {
      unawaited(ble.send(_current!));
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
      _log(
          'reroute_response elapsedMs=${DateTime.now().difference(requestStarted).inMilliseconds} candidates=${routes.length} movedM=${pos.distanceTo(latest).round()} ${_fixDetails(latest)}');
      var anyDistanceRejected = false;
      var anyDirectionRejected = false;
      final selected = preferredRouteIndex(alignedRoutes,
          avoidEarlyUTurns: true, eligible: (route) {
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
            'candidate startReverse=$reverse matchedReverse=${matcher.reverseTravel} distanceM=${matcher.lastRouteDistanceMeters?.toStringAsFixed(1)} thresholdM=${matcher.lastOffRouteThresholdMeters?.toStringAsFixed(1)} courseDeltaDeg=${matcher.lastCourseDeltaDegrees?.toStringAsFixed(1) ?? "ignored"} courseReliable=${latest is NavigationFix && latest.reliableCourse} distanceRejected=$distanceRejected directionRejected=$directionRejected rejected=${distanceRejected || directionRejected}');
        return !distanceRejected && !directionRejected;
      });
      if (selected < 0) {
        final reason = anyDistanceRejected && !anyDirectionRejected
            ? 'No reroute is close enough to the current position'
            : anyDirectionRejected && !anyDistanceRejected
                ? 'No reroute matches the current travel direction'
                : 'No reroute matches the current position and travel direction';
        throw DirectionsException(reason);
      }
      _origin = latest;
      _setRouteOptions(alignedRoutes, selectedIndex: selected);
      _awaitingValidRoute = false;
      _log('reroute_success selected=$selected');
      _clearRerouteNotice();
      _lastSideRoadRefreshAt = null;
      _sideRoadRefreshPosition = null;
      _set(NavPhase.navigating);
      _startRouteSideRoadPrefetch();

      final navState = _engine!.update(_latestPosition ?? pos);
      _current = navState;
      _lastReliableNavState = navState;
      notifyListeners();
      await ble.send(navState);
      return true;
    } catch (e) {
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
        final navState = engine.update(latest);
        _current = navState;
        _lastReliableNavState = navState;
        _set(NavPhase.navigating);
        await ble.send(navState);
        return true;
      }
      // Keep the last known route shape visible while a replacement is sought,
      // but do not revive a known-bad maneuver or distance.
      _rerouteFailure = text.rerouteFailed(e);
      // Avoid retaining exception URLs or coordinates in diagnostic logs.
      _log(
          'reroute_failed type=${e.runtimeType} elapsedMs=${DateTime.now().difference(requestStarted).inMilliseconds}');
      _scheduleRecovery();
      _clearRerouteNotice();
      _current = _temporaryRouteState();
      _set(NavPhase.navigating, error: _rerouteFailure);
      await ble.send(_current!);
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
    _recoveryTimer?.cancel();
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
    final preview = _phase == NavPhase.idle && _destination != null;
    if (!preview && _phase != NavPhase.navigating) return;

    _invalidateReroute();
    _error = null;
    _selectedRouteIndex = index;
    _engine = NavigationEngine(
      _routeOptions[index].steps,
      sideRoads: _routeOptions[index].sideRoads,
    );
    _lastReliableNavState =
        _engine!.update(_routeOptions[index].polyline.first);
    _offRouteSamples = 0;
    _lastSideRoadRefreshAt = null;
    _sideRoadRefreshPosition = null;

    if (preview) {
      // Selecting a preview never starts guidance or writes to the device.
      _current = null;
      notifyListeners();
      _warmPreviewSideRoads();
      return;
    }

    final origin = _latestPosition ?? _origin;
    if (origin != null) {
      final navState = _engine!.update(origin);
      _current = navState;
      _lastReliableNavState = navState;
      notifyListeners();
      await ble.send(navState);
      _startRouteSideRoadPrefetch();
      return;
    }

    notifyListeners();
  }

  bool _changingDestination = false;

  /// Transactional switch. Old guidance keeps running while the new route is
  /// fetched. Stop/pause/reroute/cancel invalidates this pending result.
  Future<bool> changeDestination(
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
        final measured = await _location
            .currentPosition()
            .timeout(const Duration(seconds: 8));
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
      final routes = await _directions
          .fetchRoutes(origin: start, destination: destination)
          .timeout(const Duration(seconds: 25));
      if (!valid()) return false;
      final latest = await currentFreshFix();
      if (latest == null) return false;
      final aligned = routes
          .where((route) => route.steps.isNotEmpty)
          .map((route) => RouteAlignment.trim(route, start, latest))
          .toList();
      final selected = preferredRouteIndex(aligned, avoidEarlyUTurns: true,
          eligible: (route) {
        if (route.steps.isEmpty ||
            route.steps.last.end.distanceTo(destination) > 200) {
          return false;
        }
        return !RouteAlignment.conflictsWithCourse(route, latest) &&
            !NavigationEngine(route.steps).isOffRoute(latest);
      });
      if (selected < 0 || !valid()) return false;
      // Build everything before touching the active trip.
      final nextEngine = NavigationEngine(aligned[selected].steps,
          sideRoads: aligned[selected].sideRoads);
      final nextState = nextEngine.update(latest);
      _invalidateReroute();
      _origin = latest;
      _destination = destination;
      _routeOptions = List.unmodifiable(aligned);
      _selectedRouteIndex = selected;
      _engine = nextEngine;
      _current = nextState;
      _error = null;
      _offRouteSamples = 0;
      _lastRerouteAt = null;
      _lastSideRoadRefreshAt = null;
      _sideRoadRefreshPosition = null;
      _log('voice_destination_changed');
      notifyListeners();
      _startRouteSideRoadPrefetch();
      // Routing success is separate from BLE availability. Send the new state,
      // but do not claim the route failed after it has already been committed.
      unawaited(Future<bool>.sync(() => ble.send(nextState))
          .catchError((_) => false));
      return true;
    } catch (_) {
      if (!_disposed) _log('voice_destination_change_failed');
      return false;
    } finally {
      _changingDestination = false;
    }
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
    _lastReliableNavState = _engine!.update(selected.polyline.first);
  }

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
        route.polyline, _latestPosition ?? route.polyline.first, (loadedNear) {
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
        notifyListeners();
        unawaited(ble.send(refreshed));
      }
    });
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
        route.polyline, _latestPosition ?? route.polyline.first, (_) {});
  }

  bool _applyCachedSideRoads(LatLng position) {
    final provider = _sideRoads;
    final engine = _engine;
    if (provider is! RouteSideRoadProvider || engine == null) return false;
    final moved = _sideRoadRefreshPosition == null ||
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
    _log('gps_stream_error type=${e.runtimeType}');
    final failedSubscription = _posSub;
    _posSub = null;
    unawaited(failedSubscription?.cancel() ?? Future<void>.value());
    _invalidateReroute();
    // Lost the GPS fix — tell the device to show STOP so the rider isn't given
    // a stale/misleading instruction.
    _current = NavState.stopped;
    _set(NavPhase.navigating, error: AppText.system.gpsSignalLost);
    ble.send(NavState.stopped);
    _scheduleGpsRestart();
  }

  /// Temporarily pause navigation: park the device on STOP and stop consuming
  /// positions, but keep the route/destination so the rider can start again
  /// without re-searching.
  Future<void> pause() async {
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = null;
    _stopHeartbeat();
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
    _gpsRestartTimer?.cancel();
    _gpsRestartTimer = null;
    _stopHeartbeat();
    _invalidateReroute();
    _previewRequestId++;
    _previewingRoute = false;
    if (_sideRoads is RouteSideRoadProvider) {
      (_sideRoads as RouteSideRoadProvider).cancelPrefetch();
    }
    await _posSub?.cancel();
    _posSub = null;
    if (sendStopToDevice) {
      await ble.send(NavState.stopped);
    }
    _engine = null;
    _current = null;
    _lastReliableNavState = null;
    _origin = null;
    _latestPosition = null;
    _destination = null;
    _routeOptions = const [];
    _selectedRouteIndex = 0;
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

  @override
  void dispose() {
    _disposed = true;
    _gpsRestartTimer?.cancel();
    _stopHeartbeat();
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
