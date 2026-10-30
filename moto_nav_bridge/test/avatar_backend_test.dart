import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:moto_nav_bridge/services/avatar_backend.dart';
import 'package:moto_nav_bridge/services/supabase_rider_backend.dart';
import 'avatar_test_fakes.dart';

void main() {
  test(
    'own photo RPCs use expected identity and only a small JPEG payload',
    () async {
      final jpeg = avatarJpeg();
      final version = sampleAvatar().id;
      final calls = <String>[];
      final client = SupabaseClient(
        'https://avatar-test.invalid',
        'public-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final method = request.url.pathSegments.last;
          calls.add(method);
          final body = jsonDecode(request.body);
          final result = switch (method) {
            'navio_get_profile_avatar' => {
              'id': version,
              'jpeg_base64': base64Encode(jpeg),
            },
            'navio_set_profile_avatar' => version,
            _ => null,
          };
          if (method == 'navio_set_profile_avatar') {
            expect(
              (body as Map).keys,
              unorderedEquals(['p_expected_user', 'p_jpeg_base64']),
            );
            expect(body['p_expected_user'], 'current-user');
            expect(
              base64Decode(body['p_jpeg_base64'] as String),
              orderedEquals(jpeg),
            );
          }
          if (method == 'navio_remove_profile_avatar') {
            expect(body, {'p_expected_user': 'current-user'});
          }
          return http.Response(
            jsonEncode(result),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final backend = SupabaseAvatarBackend(client);
      expect((await backend.fetchOwn())?.id, version);
      expect((await backend.upload('current-user', jpeg)).id, version);
      await backend.remove('current-user');
      expect(calls, [
        'navio_get_profile_avatar',
        'navio_set_profile_avatar',
        'navio_remove_profile_avatar',
      ]);
      await client.dispose();
    },
  );
  test(
    'rider photo requests expose rotating identifiers but no private account ID',
    () async {
      final client = SupabaseClient(
        'https://avatar-test.invalid',
        'public-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.pathSegments.last, 'navio_get_rider_avatar');
          expect(jsonDecode(request.body), {
            'p_public_id': 'public-rider',
            'p_avatar_id': 'rotating-avatar',
          });
          return http.Response(
            jsonEncode(base64Encode(avatarJpeg())),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      expect(
        await SupabaseRiderBackend(
          client,
        ).fetchAvatar('public-rider', 'rotating-avatar'),
        isNotNull,
      );
      await client.dispose();
    },
  );
}
