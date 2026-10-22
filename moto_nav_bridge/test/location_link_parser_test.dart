import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/location_link_parser.dart';

void main() {
  LocationLinkParser parser({MapUrlResolver? resolver}) => LocationLinkParser(
      resolver: resolver,
      geocode: (q) async => [
            PlaceResult(
                name: q,
                address: 'First candidate',
                location: const LatLng(-33, 151)),
            PlaceResult(
                name: q,
                address: 'Second candidate',
                location: const LatLng(-34, 150)),
          ]);
  for (final url in [
    '-33.8,151.2',
    'https://www.google.com/maps?q=-33.8,151.2',
    'https://www.google.com/maps/search/?api=1&query=-33.8,151.2',
    'https://maps.apple.com/?daddr=-33.8,151.2',
    'https://maps.apple.com/?ll=-33.8,151.2&q=Pin',
  ]) {
    test('coordinates: $url', () async {
      final result = (await parser().parse(url)).single;
      expect(result.location.latitude, -33.8);
      expect(result.location.longitude, 151.2);
    });
  }
  test('explicit destination overrides viewport', () async {
    final result = await parser()
        .parse('https://www.google.com/maps/@1,2,15z?destination=-33,151');
    expect(result.single.location.latitude, -33);
  });
  test('place name overrides viewport and preserves ambiguous candidates',
      () async {
    final result = await parser()
        .parse('https://www.google.com/maps/place/Some+Cafe/@1,2,15z');
    expect(result.length, 2);
    expect(result.first.name, 'Some Cafe');
    expect(result.first.resolutionStatus, 'geocoded');
    expect(result.first.sourceUrl, contains('/place/'));
  });
  test('viewport requires explicit confirmation status', () async {
    final result = await parser().parse('https://www.google.com/maps/@1,2,15z');
    expect(result.single.resolutionStatus, 'viewport');
  });
  for (final input in [
    'https://evil.test/maps?q=1,2',
    'http://maps.apple.com/?ll=1,2',
    'https://www.google.com.evil.test/maps',
    'https://user@maps.apple.com/?ll=1,2',
    'https://maps.apple.com:8000/?ll=1,2',
    '91,181',
    'https://[',
    'https://www.google.com/maps/?query_place_id=abc',
    'https://www.google.com/maps/dir/@1,2,15z'
  ]) {
    test('reject $input', () async {
      await expectLater(
          parser().parse(input), throwsA(isA<LocationLinkException>()));
    });
  }
  test('short link resolves with manual redirects disabled', () async {
    final resolver = MapUrlResolver(
        clientFactory: () => MockClient((request) async {
              expect(request.followRedirects, isFalse);
              return request.url.host == 'maps.app.goo.gl'
                  ? http.Response('', 302, headers: {
                      'location': 'https://www.google.com/maps?q=1,2'
                    })
                  : http.Response('', 200);
            }));
    expect(
        (await parser(resolver: resolver).parse('https://maps.app.goo.gl/test'))
            .single
            .location
            .latitude,
        1);
  });
  for (final target in [
    'https://maps.app.goo.gl/test',
    'https://127.0.0.1/maps',
    'http://www.google.com/maps'
  ]) {
    test('reject unsafe or looping redirect $target', () async {
      final resolver = MapUrlResolver(
          clientFactory: () => MockClient((_) async =>
              http.Response('', 302, headers: {'location': target})));
      await expectLater(
          resolver.resolve(Uri.parse('https://maps.app.goo.gl/test')),
          throwsA(isA<LocationLinkException>()));
    });
  }
  test('redirect limit', () async {
    var count = 0;
    final resolver = MapUrlResolver(
        maxRedirects: 2,
        clientFactory: () => MockClient((_) async => http.Response('', 302,
            headers: {'location': 'https://maps.app.goo.gl/${count++}'})));
    await expectLater(
        resolver.resolve(Uri.parse('https://maps.app.goo.gl/test')),
        throwsA(isA<LocationLinkException>()));
    expect(count, 3);
  });
  test('timeout', () async {
    final resolver = MapUrlResolver(
        timeout: const Duration(milliseconds: 1),
        clientFactory: () =>
            MockClient((_) => Completer<http.Response>().future));
    await expectLater(
        resolver.resolve(Uri.parse('https://maps.app.goo.gl/test')),
        throwsA(isA<LocationLinkException>()));
  });
  test('no geocoding match fails rather than using viewport', () async {
    final p = LocationLinkParser(geocode: (_) async => []);
    await expectLater(
        p.parse('https://www.google.com/maps/place/Missing/@1,2,15z'),
        throwsA(isA<LocationLinkException>()));
  });
}
