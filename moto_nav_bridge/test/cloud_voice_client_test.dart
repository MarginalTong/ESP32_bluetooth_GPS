import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moto_nav_bridge/services/cloud_voice_client.dart';

void main() {
  const url = 'https://nav.williamligallery.uk/v1/intent-test';
  final token = 'x' * 32;

  test('conversation sends authenticated audio and bounded trip context',
      () async {
    final client = CloudVoiceClient(client: MockClient((request) async {
      expect(request.url.path, '/v1/voice');
      expect(request.followRedirects, false);
      expect(request.headers['Authorization'], 'Bearer $token');
      expect(jsonDecode(request.body), {
        'audio': 'AQID',
        'context': 'request',
        'trip_access': true,
        'route_snapshot': 'Turn right in 200 metres',
        'saved_slots': ['home'],
        'history': [
          {'user': 'Hi', 'assistant': 'Hello!'}
        ],
      });
      return http.Response(
          '{"utterance":"hello","reply":"Hi there!","action":"none","argument":"","decision":"none"}',
          200);
    }));
    final result = await client.converse(
        url, token, Uint8List.fromList([1, 2, 3]),
        tripAccess: true,
        routeSnapshot: 'Turn right in 200 metres',
        savedSlots: [
          'home'
        ],
        history: [
          {'user': 'Hi', 'assistant': 'Hello!'}
        ]);
    expect(result['reply'], 'Hi there!');
    expect(result['action'], 'none');
    client.close();
  });

  test('rejects other hosts, short tokens and excessive history', () async {
    final client = CloudVoiceClient();
    await expectLater(
        client.converse('https://example.com/v1/voice', token, Uint8List(3)),
        throwsFormatException);
    await expectLater(
        client.converse(url, 'short', Uint8List(3)), throwsFormatException);
    await expectLater(
        client.converse(url, token, Uint8List(3), history: [
          for (var i = 0; i < 4; i++) {'user': 'hi', 'assistant': 'hello'}
        ]),
        throwsFormatException);
    client.close();
  });

  test('rejects invented actions and malformed responses', () async {
    final client = CloudVoiceClient(
        client: MockClient((_) async => http.Response(
            '{"utterance":"hi","reply":"Hi","action":"turn_now","argument":"","decision":"none"}',
            200)));
    await expectLater(
        client.converse(url, token, Uint8List(3)), throwsFormatException);
    client.close();
  });
}
