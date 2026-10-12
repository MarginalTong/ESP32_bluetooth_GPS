import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';
import 'directions_service.dart';
import 'navigation_ports.dart';

/// Direction-aware route planning against an explicitly configured Valhalla server.
/// No coordinates are sent to a public demo server or a fallback provider.
/// Protocol: https://valhalla.github.io/valhalla/api/route/api-reference/
class ValhallaDirectionsService implements RouteProvider {
  ValhallaDirectionsService({
    http.Client? client,
    String? routeUrl,
    Duration timeout = const Duration(seconds: 8),
  })  : _client = client ?? http.Client(),
        _routeUrl = routeUrl ?? ApiConfig.valhallaRouteUrl,
        _timeout = timeout;

  final http.Client _client;
  final String _routeUrl;
  final Duration _timeout;
  final Set<Completer<void>> _pending = {};
  bool _disposed = false;
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _maxShapePoints = 150000;

  @override
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async =>
      (await fetchRoutes(origin: origin, destination: destination)).first.steps;

  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async {
    if (_disposed) throw DirectionsException('Valhalla service is disposed');
    final uri = _endpoint();
    _checkCoordinate(origin);
    _checkCoordinate(destination);
    if (_timeout <= Duration.zero) {
      throw DirectionsException('Invalid Valhalla timeout');
    }

    final start = <String, Object>{
      'lat': origin.latitude,
      'lon': origin.longitude,
    };
    // Reuse measured travel course, not the phone's physical orientation. A
    // stopped, stale, future-dated or inaccurate fix must not constrain routing.
    if (origin is NavigationFix &&
        origin.reliableCourse &&
        origin.speed.isFinite) {
      final age = DateTime.now().difference(origin.timestamp);
      if (age >= Duration.zero && age <= const Duration(seconds: 10)) {
        start['heading'] = origin.heading.round() % 360;
        start['heading_tolerance'] = 60;
      }
    }

    final abort = Completer<void>();
    _pending.add(abort);
    final request =
        http.AbortableRequest('POST', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'application/json'
          ..body = jsonEncode({
            'locations': [
              start,
              {'lat': destination.latitude, 'lon': destination.longitude},
            ],
            // Preserve the existing Apple automobile transport contract. Motorcycle
            // costing is a separate product choice, not an incidental provider swap.
            'costing': 'auto',
            'units': 'kilometers',
            'format': 'json',
            'directions_type': 'maneuvers',
            'alternates': 2,
          });

    try {
      final body = await _readResponse(request).timeout(_timeout);
      if (_disposed) throw DirectionsException('Valhalla service is disposed');
      return parseRoutesJson(body);
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
    if ((response.contentLength ?? 0) > _maxResponseBytes) {
      throw DirectionsException('Valhalla response is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        throw DirectionsException('Valhalla response is too large');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  /// Parses native Valhalla JSON (polyline6), not its optional OSRM format.
  /// Destination maneuvers are not travel legs: dropping their zero-length
  /// step prevents the engine from announcing ARRIVED before the destination.
  static List<RouteCandidate> parseRoutesJson(String body) {
    if (body.length > _maxResponseBytes) {
      throw DirectionsException('Valhalla response is too large');
    }
    try {
      final root = _object(jsonDecode(body));
      if (root.containsKey('error') ||
          root.containsKey('error_code') ||
          (root.containsKey('status_code') && root['status_code'] != 200)) {
        throw const FormatException();
      }
      final alternatives = root['alternates'];
      if (alternatives != null && alternatives is! List) {
        throw const FormatException();
      }
      final output = [_parseTrip(_object(root['trip']), 0)];
      if (alternatives is List) {
        for (var i = 0; i < math.min(alternatives.length, 2); i++) {
          output.add(
              _parseTrip(_object(_object(alternatives[i])['trip']), i + 1));
        }
      }
      return List.unmodifiable(output);
    } catch (_) {
      throw DirectionsException('Invalid or unusable Valhalla route response');
    }
  }

  static RouteCandidate _parseTrip(Map<String, dynamic> trip, int index) {
    if (trip['status'] != 0) throw const FormatException();
    final double metersPerUnit;
    switch (trip['units']) {
      case 'kilometers':
        metersPerUnit = 1000;
      case 'miles':
        metersPerUnit = 1609.344;
      default:
        throw const FormatException();
    }
    // This adapter requests exactly two break locations, hence exactly one
    // leg. Reject a proxy returning an unrelated/multipoint itinerary.
    final legs = trip['legs'];
    if (legs is! List || legs.length != 1) throw const FormatException();
    final leg = _object(legs.single);
    final shape = _decodeShape(leg['shape']);
    final maneuvers = leg['maneuvers'];
    if (maneuvers is! List ||
        maneuvers.length < 2 ||
        maneuvers.length > 10000) {
      throw const FormatException();
    }
    final steps = <RouteStep>[];
    var previousEnd = 0;
    var foundDestination = false;
    for (var i = 0; i < maneuvers.length; i++) {
      final maneuver = _object(maneuvers[i]);
      final type = _integer(maneuver['type']);
      final begin = _integer(maneuver['begin_shape_index']);
      final end = _integer(maneuver['end_shape_index']);
      final length = _nonnegative(maneuver['length']);
      if (begin != previousEnd || end < begin || end >= shape.length) {
        throw const FormatException();
      }
      previousEnd = end;
      if (type >= 4 && type <= 6) {
        if (i != maneuvers.length - 1 ||
            begin != end ||
            end != shape.length - 1 ||
            length != 0) {
          throw const FormatException();
        }
        foundDestination = true;
        continue;
      }
      if (end == begin) throw const FormatException();
      final mode = maneuver['travel_mode'];
      if (mode != null && mode != 'drive') throw const FormatException();
      steps.add(RouteStep(
        direction: _direction(type, shape, begin, end),
        start: shape[begin],
        end: shape[end],
        distanceMeters: (length * metersPerUnit).round(),
        geometry: List.unmodifiable(shape.sublist(begin, end + 1)),
        rawManeuver: 'valhalla:$type',
      ));
    }
    if (!foundDestination || steps.isEmpty) throw const FormatException();
    final summary = _object(trip['summary']);
    return RouteCandidate(
      steps: List.unmodifiable(steps),
      name: 'Valhalla ${index + 1}',
      distanceMeters: (_nonnegative(summary['length']) * metersPerUnit).round(),
      expectedTravelTimeSeconds: _nonnegative(summary['time']).round(),
      attribution: '© OpenStreetMap contributors',
      attributionUrl: 'https://www.openstreetmap.org/copyright',
    );
  }

  static DeviceDirection _direction(
      int type, List<LatLng> shape, int begin, int end) {
    switch (type) {
      case 0:
      case 1:
      case 2:
      case 3:
      case 7:
      case 8:
      case 17:
      case 22:
      case 28:
      case 29:
        return DeviceDirection.up;
      case 9:
      case 18:
      case 20:
      case 23:
      case 37:
        return DeviceDirection.bearRight;
      case 10:
      case 11:
        return DeviceDirection.right;
      case 12:
      case 13:
        return DeviceDirection.uturn;
      case 14:
      case 15:
        return DeviceDirection.left;
      case 16:
      case 19:
      case 21:
      case 24:
      case 38:
        return DeviceDirection.bearLeft;
      case 25:
      case 26:
      case 27:
        // Firmware has no roundabout/merge glyph. For entry use the net turn
        // from the approach to the exit, not the first curved ring segment.
        // Keep both real maneuvers/geometry; never invent an exit number.
        return _geometricDirection(shape, begin, type == 26 ? end : begin);
      default:
        // Do not disguise transit, stairs, or unknown maneuvers as straight.
        throw const FormatException();
    }
  }

  static DeviceDirection _geometricDirection(
      List<LatLng> shape, int entry, int exit) {
    var before = entry - 1;
    var after = exit + 1;
    while (before >= 0 && shape[before].distanceTo(shape[entry]) < 1) {
      before--;
    }
    while (after < shape.length && shape[exit].distanceTo(shape[after]) < 1) {
      after++;
    }
    // Starting inside a junction has no incoming tangent to infer a turn.
    if (before < 0 || after >= shape.length) return DeviceDirection.up;
    final incoming = _bearing(shape[before], shape[entry]);
    final outgoing = _bearing(shape[exit], shape[after]);
    final angle = (outgoing - incoming + 540) % 360 - 180;
    if (angle.abs() >= 165) return DeviceDirection.uturn;
    if (angle.abs() < 25) return DeviceDirection.up;
    if (angle.abs() < 60) {
      return angle > 0 ? DeviceDirection.bearRight : DeviceDirection.bearLeft;
    }
    return angle > 0 ? DeviceDirection.right : DeviceDirection.left;
  }

  static double _bearing(LatLng a, LatLng b) =>
      math.atan2(
          (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180),
          b.latitude - a.latitude) *
      180 /
      math.pi;

  static List<LatLng> _decodeShape(dynamic value) {
    if (value is! String || value.isEmpty) throw const FormatException();
    final output = <LatLng>[];
    var cursor = 0;
    var latitude = 0;
    var longitude = 0;
    int delta() {
      var result = 0;
      for (var shift = 0; shift <= 30; shift += 5) {
        if (cursor >= value.length) throw const FormatException();
        final byte = value.codeUnitAt(cursor++) - 63;
        if (byte < 0 || byte > 63) throw const FormatException();
        result |= (byte & 31) << shift;
        if (byte < 32) return result.isOdd ? ~(result >> 1) : result >> 1;
      }
      throw const FormatException();
    }

    while (cursor < value.length) {
      if (output.length >= _maxShapePoints) throw const FormatException();
      latitude += delta();
      longitude += delta();
      final point = LatLng(latitude / 1e6, longitude / 1e6);
      _checkCoordinate(point);
      output.add(point);
    }
    if (output.length < 2 ||
        !output.any((point) => output.first.distanceTo(point) > 0.1)) {
      throw const FormatException();
    }
    return output;
  }

  static Map<String, dynamic> _object(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  static int _integer(dynamic value) {
    if (value is! int || value < 0) throw const FormatException();
    return value;
  }

  static double _nonnegative(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 1e9) {
      throw const FormatException();
    }
    return value.toDouble();
  }

  static void _checkCoordinate(LatLng point) {
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude.abs() > 90 ||
        point.longitude.abs() > 180) {
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
