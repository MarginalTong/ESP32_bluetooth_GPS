import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/controllers/rider_map_controller.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/supabase_rider_backend.dart';
import 'rider_map_controller_test.dart' show RiderNav;

/// Test-only HTTP fixture. Exercises the real Supabase SDK RPC/JSON boundary,
/// but is NOT PostgreSQL/PostgREST or evidence of a hosted provider E2E pass.
/// SQL/RLS behavior is separately exercised by supabase/tests.
class PresenceFixture {
  PresenceFixture(this.now);
  final DateTime Function() now;
  int tokens = 0;
  final rows = <String, Map<String, dynamic>>{};
  final payloads = <Map<String, dynamic>>[];
  Future<http.Response> handle(http.Request request) async {
    final actor = switch (request.headers['Authorization'] ??
        request.headers['authorization']) {
      'Bearer local-a' => 'a',
      'Bearer local-b' => 'b',
      _ => null,
    };
    if (actor == null) {
      return http.Response(
        '{"code":"42501","message":"Authentication required"}',
        401,
        request: request,
      );
    }
    expect(request.headers['apikey'], 'sb_publishable_local_test');
    final decoded = request.body.isEmpty ? null : jsonDecode(request.body);
    final body = decoded == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(decoded as Map);
    Object? result;
    switch (request.url.pathSegments.last) {
      case 'navio_begin_rider_sharing':
        final token = 'session-${++tokens}';
        rows[actor] = {
          'session': token,
          'id': '10000000-0000-4000-8000-${tokens.toString().padLeft(12, '0')}',
          'expires_at': now()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        };
        result = token;
      case 'navio_publish_rider_position':
        payloads.add(body);
        expect(
          body.keys,
          unorderedEquals([
            'p_session',
            'p_sequence',
            'p_latitude',
            'p_longitude',
            'p_accuracy',
            'p_fix_at',
          ]),
        );
        final row = rows[actor];
        result = row != null && row['session'] == body['p_session'];
        if (result == true) {
          row!['latitude'] = body['p_latitude'];
          row['longitude'] = body['p_longitude'];
          row['updated_at'] = now().toIso8601String();
          row['expires_at'] = now()
              .add(const Duration(seconds: 30))
              .toIso8601String();
        }
      case 'navio_list_riders':
        result = {
          'riders': [
            for (final entry in rows.entries)
              if (entry.key != actor &&
                  entry.value['latitude'] != null &&
                  DateTime.parse(
                    entry.value['expires_at'] as String,
                  ).isAfter(now()))
                Map.of(entry.value)..remove('session'),
          ],
          'truncated': false,
        };
      case 'navio_stop_rider_sharing':
        if (rows[actor]?['session'] == body['p_session']) rows.remove(actor);
        result = null;
      default:
        return http.Response('{"message":"Unknown RPC"}', 404);
    }
    return http.Response(
      jsonEncode(result),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

class LocalRiderBackend extends SupabaseRiderBackend {
  LocalRiderBackend(super.client, this.actor);
  final String actor;
  @override
  String? get userId => actor;
  @override
  Stream<String?> get userChanges => const Stream.empty();
}

void main() {
  test(
    'two local clients exchange only coarse live positions and withdraw on arrival',
    () async {
      var now = DateTime.now().toUtc();
      final fixture = PresenceFixture(() => now);
      final clientA = SupabaseClient(
        'https://local-a.invalid',
        'sb_publishable_local_test',
        accessToken: () async => 'local-a',
        httpClient: MockClient(fixture.handle),
      );
      final clientB = SupabaseClient(
        'https://local-b.invalid',
        'sb_publishable_local_test',
        accessToken: () async => 'local-b',
        httpClient: MockClient(fixture.handle),
      );
      final nav = RiderNav();
      final publisher = RiderMapController(
        LocalRiderBackend(clientA, 'a'),
        now: () => now,
        tick: false,
      )..bindNavigation(nav);
      final viewer = RiderMapController(
        LocalRiderBackend(clientB, 'b'),
        now: () => now,
        tick: false,
      );
      addTearDown(() async {
        publisher.dispose();
        viewer.dispose();
        nav.dispose();
        await pumpEventQueue();
        await clientA.dispose();
        await clientB.dispose();
      });
      NavigationFix fix(double lat) => NavigationFix(
        lat,
        151.1234567,
        accuracy: 5,
        heading: 45,
        speed: 4,
        timestamp: now,
      );
      publisher.setSharing(true);
      nav.change(NavPhase.navigating, fix(-33.888888));
      await pumpEventQueue();
      expect(fixture.payloads.single['p_latitude'], -33.889);
      expect(fixture.payloads.single['p_longitude'], 151.123);
      viewer.setViewing(true);
      await pumpEventQueue();
      expect(viewer.riders, hasLength(1));
      expect(viewer.sharing, isFalse);
      final publicId = viewer.riders.single.id;
      expect(viewer.riders.single.location.latitude, -33.889);
      expect(
        viewer.riders.single.toMap().keys,
        unorderedEquals(['id', 'latitude', 'longitude']),
      );
      now = now.add(const Duration(seconds: 6));
      nav.change(NavPhase.navigating, fix(-33.889888));
      await pumpEventQueue();
      viewer.pulse();
      await pumpEventQueue();
      expect(viewer.riders.single.id, publicId);
      expect(viewer.riders.single.location.latitude, -33.890);
      nav.change(NavPhase.arrived, fix(-33.889888));
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 5));
      viewer.pulse();
      await pumpEventQueue();
      expect(fixture.rows, isEmpty);
      expect(viewer.riders, isEmpty);
      expect(publisher.error, isNull);
      expect(viewer.error, isNull);
    },
  );

  test(
    'real SDK adapter rejects malformed or out-of-region response data',
    () async {
      for (final data in [
        {
          'id': 'not-an-id',
          'latitude': -33.88,
          'longitude': 151.12,
          'expires_at': DateTime.now().toIso8601String(),
        },
        {
          'id': '10000000-0000-4000-8000-000000000001',
          'latitude': -35,
          'longitude': 151.12,
          'expires_at': DateTime.now().toIso8601String(),
        },
      ]) {
        final client = SupabaseClient(
          'https://local.invalid',
          'sb_publishable_local_test',
          accessToken: () async => 'local-test',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'riders': [data],
                'truncated': false,
              }),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(client.dispose);
        await expectLater(
          SupabaseRiderBackend(client).fetch(),
          throwsFormatException,
        );
      }
    },
  );
}
