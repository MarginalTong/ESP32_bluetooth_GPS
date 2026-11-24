import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';

import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/road_segment.dart';
import '../models/nav_state.dart';
import '../models/device_direction.dart';
import '../models/route_candidate.dart';
import '../models/place_result.dart';
import '../services/directions_exception.dart';
import '../services/location_service.dart';
import '../services/navigation_ports.dart';
import '../services/navigation_engine.dart';
import '../services/side_road_service.dart';
import '../services/route_alignment.dart';
import '../services/route_preference.dart';
import '../services/valhalla_directions_service.dart';
import '../services/waypoint_plan.dart';
import '../services/settings_store.dart';
import '../services/offline_trip.dart';
import '../services/navigation_session_store.dart';

part 'navigation_planning.dart';
part 'navigation_positions.dart';
part 'navigation_recovery.dart';
part 'navigation_context.dart';
part 'navigation_destination.dart';
part 'navigation_lifecycle.dart';
part 'navigation_persistence.dart';

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
    NavigationSessionStore? sessions,
    // Preserve the public `preferences` constructor parameter.
    // ignore: prefer_initializing_formals
  }) : _preferences = preferences,
       // Keep the injected persistence port distinct from platform storage.
       // ignore: prefer_initializing_formals
       _sessions = sessions,
       _location = location ?? LocationService(),
       _sideRoads = sideRoads ?? SideRoadService() {
    _directions =
        directions ??
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

  Future<void> savePreferences({
    required bool highways,
    required bool tolls,
    required bool ferries,
    bool tunnels = false,
  }) => _savePreferences(
    highways: highways,
    tolls: tolls,
    ferries: ferries,
    tunnels: tunnels,
  );

  final NavigationBlePort ble;
  late final RouteProvider _directions;
  bool avoidHighways = false, avoidTolls = false, avoidFerries = false;
  bool avoidTunnels = false;
  Map<String, Object> _tripPreferences = const {};
  bool get canEditPreferences =>
      !_previewingRoute &&
      (_phase == NavPhase.idle || _phase == NavPhase.error);

  void updatePreferences({
    required bool highways,
    required bool tolls,
    required bool ferries,
    bool tunnels = false,
  }) => _updatePreferences(
    highways: highways,
    tolls: tolls,
    ferries: ferries,
    tunnels: tunnels,
  );

  bool _usableVoiceFix(LatLng? value) =>
      value is NavigationFix &&
      value.accuracy.isFinite &&
      value.accuracy >= 0 &&
      value.accuracy <= 50 &&
      DateTime.now().difference(value.timestamp).abs() <
          const Duration(seconds: 45);

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

  WaypointPlan _waypointPlan = WaypointPlan(const []);
  List<PlaceResult> get waypoints => _waypointPlan.stops;
  int get completedWaypoints => _waypointPlan.completed;

  List<RouteCandidate> _routeOptions = const [];
  List<RouteCandidate> get routeOptions => _routeOptions;

  int _selectedRouteIndex = 0;
  int get selectedRouteIndex => _selectedRouteIndex;
  bool _previewRouteExplicitlySelected = false;

  RouteCandidate? get selectedRoute =>
      _routeOptions.isEmpty ? null : _routeOptions[_selectedRouteIndex];

  bool _previewingRoute = false;
  bool get previewingRoute => _previewingRoute;

  NavigationEngine? _engine;
  int get voiceStepIndex => _routeStepOffset + (_engine?.currentStepIndex ?? 0);

  /// The newest stream fix, for voice timing (speed, accuracy); null when the
  /// position carries no fix details.
  NavigationFix? get voiceFix {
    final fix = _latestPosition;
    return fix is NavigationFix ? fix : null;
  }

  /// The last reroute attempt failed and an automatic retry is pending.
  bool get rerouteFailed => _rerouteFailure != null;
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

  bool _rerouting = false;
  bool _awaitingValidRoute = false;
  Timer? _recoveryTimer;
  final List<String> _diagnostics = [];
  String get diagnostics => _diagnostics.join('\n');
  void clearDiagnostics() => _diagnostics.clear();
  void recordMapDiagnostic(String event) => _recordMapDiagnostic(event);

  String _fixDetails(LatLng pos) => pos is NavigationFix
      ? 'accuracy=${pos.accuracy} speed=${pos.speed} heading=${pos.heading} ageMs=${DateTime.now().difference(pos.timestamp).inMilliseconds}'
      : 'quality=unknown';

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
  // Recent stream fixes, oldest first. A bike that has not moved cannot have
  // left the route: an off-route fix then is GPS drift (indoors, beside tall
  // buildings, waiting at lights), and rerouting from it cannot succeed.
  final List<NavigationFix> _recentFixes = [];
  static const int _recentFixLimit = 20;
  static const Duration _stationaryEvidence = Duration(seconds: 20);
  static const double _movingSpeedMetersPerSecond = 2.0;
  static const Duration _startMatchGrace = Duration(seconds: 15);
  DateTime? _lastAcceptedFixAt;
  static const Duration _minRerouteInterval = Duration(seconds: 10);
  static const Duration _rerouteNoticeDuration = Duration(seconds: 3);
  static const Duration _sideRoadRefreshInterval = Duration(seconds: 20);
  static const double _sideRoadRefreshDistanceMeters = 80;

  // Retain geometry only: an old turn or distance is unsafe after deviation.

  void _set(NavPhase p, {String? error}) {
    if (_disposed) return;
    _phase = p;
    _error = error;
    notifyListeners();
  }

  /// Builds route options for the destination panel without starting live
  /// navigation or writing instructions to the ESP32.
  Future<void> previewDestination(
    LatLng destination, {
    List<PlaceResult> waypoints = const [],
  }) => _previewDestination(destination, waypoints: waypoints);

  int _previewRequestId = 0;

  /// Builds a route from the current location to [destination] and starts
  /// streaming navigation updates to the device.
  Future<void> startNavigation(
    LatLng destination, {
    List<PlaceResult>? waypoints,
  }) => _startNavigation(destination, waypoints: waypoints);

  /// Whether every fix of the last [_stationaryEvidence] lies within the two
  /// fixes' combined accuracy of [pos]. The stream only reports moves over
  /// its distance filter, so an older fix still marks where a still bike was.

  bool _changingDestination = false;

  final NavigationSessionStore? _sessions;
  OfflineTrip? _savedTrip;
  String? _cachedRouteId;
  int _routeStepOffset = 0;
  DateTime? _lastCheckpointAt;
  Future<void> _routeSave = Future.value();
  bool _restoringTrip = false;
  bool get hasSavedTrip => _savedTrip != null;
  Future<bool> restoreSavedNavigation() => _restoreSavedNavigation();
  Future<bool> resumeSavedNavigation() => _resumeSavedNavigation();
  Future<void> flushSavedNavigation() async => _sessions?.flush();

  Future<void> selectRoute(int index) => _selectRoute(index);

  /// Transactional switch. Old guidance keeps running while the new route is
  /// fetched. Stop/pause/reroute/cancel invalidates this pending result.
  Future<bool> changeDestination(
    LatLng destination, {
    required LatLng expectedDestination,
    required bool Function() stillConfirmed,
  }) => _changeDestination(
    destination,
    expectedDestination: expectedDestination,
    stillConfirmed: stillConfirmed,
  );

  /// Temporarily pause navigation: park the device on STOP and stop consuming
  /// positions, but keep the route/destination so the rider can start again
  /// without re-searching.
  Future<void> pause() => _pause();

  Future<void> stopNavigation() => _stopNavigation();

  /// Fully end the current trip. This is intentionally stronger than [pause]:
  /// it clears route/navigation state and can release the BLE link so the next
  /// session starts from a clean scan/connect cycle.
  Future<void> endNavigation({bool disconnectDevice = true}) =>
      _endNavigation(disconnectDevice: disconnectDevice);

  void _notify() => notifyListeners();

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
