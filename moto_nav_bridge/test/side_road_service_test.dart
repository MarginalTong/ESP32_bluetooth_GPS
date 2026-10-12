import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/side_road_service.dart';

void main() {
  test('parses drivable OSM ways into road segments', () {
    const body = '''
{
  "elements": [
    {
      "type": "way",
      "tags": {"highway": "residential"},
      "geometry": [
        {"lat": -33.0, "lon": 151.0},
        {"lat": -33.0002, "lon": 151.0},
        {"lat": -33.0004, "lon": 151.0}
      ]
    },
    {
      "type": "way",
      "tags": {"highway": "footway"},
      "geometry": [
        {"lat": -33.0, "lon": 151.1},
        {"lat": -33.0002, "lon": 151.1}
      ]
    }
  ]
}
''';

    final segments = SideRoadService.parseOverpassJson(body);

    expect(segments, hasLength(2));
    expect(segments.first.start.latitude, -33.0);
    expect(segments.first.end.latitude, -33.0002);
  });

  test('requests nearby roads as JSON with an encoded GET query', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        '{"elements":[{"type":"way","tags":{"highway":"residential"},'
        '"geometry":[{"lat":-33.0,"lon":151.0},'
        '{"lat":-33.0002,"lon":151.0}]}]}',
        200,
      );
    });
    final service = SideRoadService(client: client);

    final roads = await service.fetchSideRoadsNear(
      const LatLng(-33.88855, 151.19355),
    );

    expect(captured.method, 'GET');
    expect(captured.headers['accept'], 'application/json');
    expect(captured.url.queryParameters['data'], contains('way[highway]'));
    final bounds = RegExp(r'way\[highway\]\(([^)]+)\)')
        .firstMatch(captured.url.queryParameters['data']!)!
        .group(1)!
        .split(',')
        .map(double.parse)
        .toList();
    // The query reaches 200 m north and south, matching the mini-map.
    expect((-33.88855 - bounds[0]) * 111320, closeTo(200, 0.01));
    expect((bounds[2] + 33.88855) * 111320, closeTo(200, 0.01));
    expect(roads, hasLength(1));
    service.dispose();
  });
}
