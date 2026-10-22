import 'dart:async';
import 'package:http/http.dart' as http;
import '../models/lat_lng.dart';
import '../models/place_result.dart';

class LocationLinkException implements Exception {
  const LocationLinkException(this.code);
  final String code;
}

/// Only response headers are inspected. No map HTML is downloaded or scraped.
class MapUrlResolver {
  MapUrlResolver(
      {http.Client Function()? clientFactory,
      this.timeout = const Duration(seconds: 10),
      this.maxRedirects = 5})
      : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  final Duration timeout;
  final int maxRedirects;

  static bool safe(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host == 'maps.app.goo.gl' || host == 'maps.apple.com') return true;
    if (host == 'goo.gl') return uri.path.startsWith('/maps/');
    return const {
          'google.com',
          'www.google.com',
          'maps.google.com',
          'google.com.au',
          'www.google.com.au',
          'maps.google.com.au'
        }.contains(host) &&
        (host.startsWith('maps.') ||
            uri.path == '/maps' ||
            uri.path.startsWith('/maps/'));
  }

  Future<Uri> resolve(Uri initial) async {
    final client = _clientFactory();
    final seen = <String>{};
    Future<Uri> follow() async {
      var uri = initial;
      for (var i = 0; i <= maxRedirects; i++) {
        if (!safe(uri)) throw const LocationLinkException('unsafe');
        if (!seen.add(uri.toString())) {
          throw const LocationLinkException('redirect');
        }
        final response = await client
            .send(http.Request('GET', uri)..followRedirects = false);
        await response.stream.listen((_) {}).cancel();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null) throw const LocationLinkException('unresolved');
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const LocationLinkException('network');
        }
        return uri;
      }
      throw const LocationLinkException('redirect');
    }

    try {
      return await follow().timeout(timeout);
    } on TimeoutException {
      throw const LocationLinkException('timeout');
    } on LocationLinkException {
      rethrow;
    } catch (_) {
      throw const LocationLinkException('network');
    } finally {
      client.close();
    }
  }
}

class LocationLinkParser {
  LocationLinkParser({required this.geocode, MapUrlResolver? resolver})
      : resolver = resolver ?? MapUrlResolver();
  final Future<List<PlaceResult>> Function(String) geocode;
  final MapUrlResolver resolver;
  static final _pair =
      RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$');
  static bool accepts(String input) =>
      input.trim().contains('://') ||
      _pair.hasMatch(input.trim()) ||
      input.trim().startsWith('www.');

  static LatLng? coordinates(String text) {
    final m = _pair.firstMatch(text);
    if (m == null) return null;
    final lat = double.parse(m[1]!);
    final lon = double.parse(m[2]!);
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      throw const LocationLinkException('coordinates');
    }
    return LatLng(lat, lon);
  }

  Future<List<PlaceResult>> parse(String input) async {
    final source = input.trim();
    PlaceResult point(LatLng p, {String? name, bool viewport = false}) =>
        PlaceResult(
            name: name ?? '${p.latitude}, ${p.longitude}',
            address: '${p.latitude}, ${p.longitude}',
            location: p,
            sourceUrl: source.contains('://') ? source : null,
            resolutionStatus: viewport ? 'viewport' : 'coordinates');
    final plain = coordinates(source);
    if (plain != null) return [point(plain)];
    try {
      var uri = Uri.parse(source);
      if (!MapUrlResolver.safe(uri)) {
        throw const LocationLinkException('unsafe');
      }
      if (uri.host == 'maps.app.goo.gl' ||
          uri.host == 'goo.gl' ||
          (uri.host == 'maps.apple.com' && uri.path.startsWith('/p/'))) {
        uri = await resolver.resolve(uri);
      }
      final q = uri.queryParameters;
      String? query;
      String? name;
      final apple = uri.host == 'maps.apple.com';
      // Destination parameters outrank camera/viewport coordinates.
      query = q['destination'] ?? q['daddr'];
      if (query == null && apple) {
        final pin = q['coordinate'] ?? q['ll'];
        if (pin != null) {
          final p = coordinates(pin);
          if (p != null) return [point(p, name: q['name'] ?? q['q'])];
        }
        query = q['address'] ?? q['q'];
      }
      query ??= q['query'] ?? q['q'];
      if (query == null) {
        final segments = uri.pathSegments;
        final place = segments.indexOf('place');
        if (place >= 0 && place + 1 < segments.length) {
          name = segments[place + 1].replaceAll('+', ' ');
          query = name;
        }
      }
      if (query != null && query.trim().isNotEmpty) {
        final p = coordinates(query);
        if (p != null) return [point(p)];
        if (query.startsWith('place_id:')) {
          throw const LocationLinkException('identifier');
        }
        final results =
            await geocode(query).timeout(const Duration(seconds: 12));
        if (results.isEmpty) throw const LocationLinkException('unresolved');
        return results
            .map((p) => PlaceResult(
                name: p.name,
                address: p.address,
                location: p.location,
                sourceUrl: source,
                resolutionStatus: 'geocoded'))
            .toList();
      }
      if (q.containsKey('query_place_id') ||
          q.containsKey('destination_place_id') ||
          q.containsKey('cid')) {
        throw const LocationLinkException('identifier');
      }
      // Directions without a destination must not become their camera centre.
      if (uri.path.contains('/dir/') || q['map_action'] == 'pano') {
        throw const LocationLinkException('unresolved');
      }
      final viewport = RegExp(r'@([+-]?\d+(?:\.\d+)?),([+-]?\d+(?:\.\d+)?)')
          .firstMatch(uri.path);
      if (viewport != null) {
        return [
          point(coordinates('${viewport[1]},${viewport[2]}')!, viewport: true)
        ];
      }
      throw const LocationLinkException('unresolved');
    } on LocationLinkException {
      rethrow;
    } on TimeoutException {
      throw const LocationLinkException('timeout');
    } on FormatException {
      throw const LocationLinkException('malformed');
    }
  }
}
