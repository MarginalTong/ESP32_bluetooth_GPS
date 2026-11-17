import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/lat_lng.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';
import 'directions_exception.dart';
import 'navigation_ports.dart';
import 'valhalla/polyline6.dart';
import 'valhalla/valhalla_lanes.dart';
import 'valhalla/valhalla_route_parser.dart';
import 'valhalla/valhalla_speed_limits.dart';
import 'waypoint_plan.dart';

/// Direction-aware route planning against an explicitly configured Valhalla server.
/// No coordinates are sent to a public demo server or a fallback provider.
/// Protocol: https://valhalla.github.io/valhalla/api/route/api-reference/
class ValhallaDirectionsService implements WaypointRouteProvider {
  ValhallaDirectionsService({
    http.Client? client,
    String? routeUrl,
    Duration timeout = const Duration(seconds: 8),
    this.routePreferences,
    this.laneGuidance = true,
    this.speedLimits = true,
  }) : _client = client ?? http.Client(),
       _routeUrl = routeUrl ?? ApiConfig.valhallaRouteUrl,
       // Preserve the public `timeout` constructor parameter.
       // ignore: prefer_initializing_formals
       _timeout = timeout;

  final http.Client _client;
  final Map<String, Object> Function()? routePreferences;

  /// Also ask for the OSRM-format response, the only one with lane data.
  final bool laneGuidance;

  /// Also ask `trace_attributes` for the posted limits along each route.
  final bool speedLimits;
  final String _routeUrl;
  final Duration _timeout;
  final Set<Completer<void>> _pending = {};
  bool _disposed = false;

  /// Parses a native Valhalla route response; see [ValhallaRouteParser].
  static List<RouteCandidate> parseRoutesJson(
    String body, {
    int expectedLegs = 1,
  }) => ValhallaRouteParser.parse(body, expectedLegs: expectedLegs);

  @override
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async =>
      (await fetchRoutes(origin: origin, destination: destination)).first.steps;

  @override
  Future<List<RouteCandidate>> fetchWaypointRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
  }) => fetchRoutes(
    origin: origin,
    destination: destination,
    waypoints: waypoints,
  );

  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> waypoints = const [],
  }) async {
    if (_disposed) throw DirectionsException('Valhalla service is disposed');
    final uri = _endpoint();
    _checkCoordinate(origin);
    _checkCoordinate(destination);
    if (waypoints.length > WaypointPlan.maxStops) {
      throw DirectionsException('Too many waypoints');
    }
    waypoints = List.unmodifiable(waypoints);
    for (final waypoint in waypoints) {
      _checkCoordinate(waypoint);
    }
    if (_timeout <= Duration.zero) {
      throw DirectionsException('Invalid Valhalla timeout');
    }

    final body = _requestBody(origin, destination, waypoints);
    // Lanes are optional: a failed or slow lane request never fails or
    // noticeably delays the route.
    final Future<String?> lanes = laneGuidance
        ? _post(uri, {
            ...body,
            'format': 'osrm',
          }).then<String?>((value) => value, onError: (_) => null)
        : Future.value(null);
    final routes = parseRoutesJson(
      await _post(uri, body),
      expectedLegs: waypoints.length + 1,
    );
    // Limits need the route's shape, so they are asked for once it is known,
    // while the lane response is still being awaited.
    final limited = Future.wait([
      for (final route in routes) _withSpeedLimits(uri, route),
    ]);
    final osrm = await lanes.timeout(_laneGrace, onTimeout: () => null);
    final withLimits = await limited;
    if (_disposed) throw DirectionsException('Valhalla service is disposed');
    return ValhallaLanes.attach(withLimits, osrm);
  }

  /// Extra wait for the speed limits of a route that has arrived. Like
  /// lanes they are optional and never fail the route.
  static const _limitGrace = Duration(seconds: 2);

  Future<RouteCandidate> _withSpeedLimits(Uri route, RouteCandidate candidate) {
    if (!speedLimits) return Future.value(candidate);
    // Same server and path prefix as /route.
    final uri = route.replace(
      path:
          '${route.path.substring(0, route.path.length - '/route'.length)}'
          '/trace_attributes',
    );
    return Future.wait([
      for (final leg in ValhallaSpeedLimits.legs(candidate))
        _limitResponse(uri, ValhallaSpeedLimits.request(leg)),
    ]).then((bodies) => ValhallaSpeedLimits.attach(candidate, bodies));
  }

  Future<String?> _limitResponse(Uri uri, Map<String, Object>? request) {
    if (request == null) return Future.value(null);
    return _post(uri, request)
        .then<String?>((value) => value, onError: (_) => null)
        .timeout(_limitGrace, onTimeout: () => null);
  }

  /// Extra wait for the lane response once the route has arrived.
  static const _laneGrace = Duration(seconds: 2);

  Future<String> _post(Uri uri, Map<String, Object> payload) async {
    final abort = Completer<void>();
    _pending.add(abort);
    final request =
        http.AbortableRequest('POST', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'application/json'
          ..body = jsonEncode(payload);
    try {
      final body = await _readResponse(request).timeout(_timeout);
      if (_disposed) throw DirectionsException('Valhalla service is disposed');
      return body;
    } on TimeoutException {
      throw DirectionsException('Valhalla route planning timed out');
    } on DirectionsException {
      rethrow;
    } catch (_) {
      // Client exceptions can contain auth-bearing URLs or coordinates. Never
      // surface the raw URL, request body, response body or network exception.
      throw DirectionsException('Valhalla network request failed');
    } finally {
      if (!abort.isCompleted) abort.complete();
      _pending.remove(abort);
    }
  }

  Map<String, Object> _requestBody(
    LatLng origin,
    LatLng destination,
    List<LatLng> waypoints,
  ) => {
    'locations': [
      _start(origin),
      for (final point in waypoints)
        {'lat': point.latitude, 'lon': point.longitude, 'type': 'break'},
      {'lat': destination.latitude, 'lon': destination.longitude},
    ],
    // Preserve the existing Apple automobile transport contract. Motorcycle
    // costing is a separate product choice, not an incidental provider swap.
    'costing': 'auto',
    if (routePreferences != null)
      'costing_options': {'auto': routePreferences!()},
    'units': 'kilometers',
    'format': 'json',
    'directions_type': 'maneuvers',
    // Valhalla alternates are supported for two-location routes only.
    'alternates': waypoints.isEmpty ? 2 : 0,
  };

  /// Reuse measured travel course, not the phone's physical orientation. A
  /// stopped, stale, future-dated or inaccurate fix must not constrain routing.
  static Map<String, Object> _start(LatLng origin) {
    final start = <String, Object>{
      'lat': origin.latitude,
      'lon': origin.longitude,
    };
    if (origin is NavigationFix &&
        origin.reliableCourse &&
        origin.speed.isFinite) {
      final age = DateTime.now().difference(origin.timestamp);
      if (age >= Duration.zero && age <= const Duration(seconds: 10)) {
        start['heading'] = origin.heading.round() % 360;
        // Degrees either side of the course that the first edge may differ.
        start['heading_tolerance'] = 60;
      }
    }
    return start;
  }

  Uri _endpoint() {
    if (_routeUrl.trim().isEmpty) {
      throw DirectionsException(
        'Valhalla route endpoint is empty. Check ApiConfig.',
      );
    }
    final uri = Uri.tryParse(_routeUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        !uri.path.endsWith('/route')) {
      throw DirectionsException('Invalid Valhalla HTTPS /route endpoint');
    }
    return uri;
  }

  Future<String> _readResponse(http.BaseRequest request) async {
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw DirectionsException('Valhalla HTTP ${response.statusCode}');
    }
    const limit = ValhallaRouteParser.maxResponseBytes;
    if ((response.contentLength ?? 0) > limit) {
      throw DirectionsException('Valhalla response is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > limit) {
        throw DirectionsException('Valhalla response is too large');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  static void _checkCoordinate(LatLng point) {
    if (!Polyline6.isValid(point)) {
      throw DirectionsException('Invalid Valhalla coordinate');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    _pending.clear();
    _client.close();
  }
}
