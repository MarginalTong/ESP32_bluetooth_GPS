import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CloudVoiceClient {
  CloudVoiceClient({http.Client? client}) : _client = client ?? http.Client();

  http.Client _client;

  void cancel() {
    _client.close();
    _client = http.Client();
  }

  void close() => _client.close();

  Future<Map<String, String>> converse(
      String endpoint, String token, Uint8List audio,
      {List<Map<String, String>> history = const [],
      String context = 'request',
      String routeSnapshot = '',
      bool tripAccess = false,
      List<String> savedSlots = const []}) async {
    final uri = Uri.parse(endpoint);
    if (uri.scheme != 'https' ||
        uri.host != 'nav.williamligallery.uk' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token.length < 32 ||
        audio.length > 320044 ||
        !{'request', 'choose_place', 'confirm_destination'}.contains(context) ||
        routeSnapshot.length > 600 ||
        savedSlots.length > 3 ||
        savedSlots.any((slot) => !{'home', 'work', 'school'}.contains(slot)) ||
        history.length > 3 ||
        history.any((turn) =>
            turn.length != 2 ||
            turn['user'] == null ||
            turn['assistant'] == null ||
            turn['user']!.length > 160 ||
            turn['assistant']!.length > 240)) {
      throw const FormatException('Invalid voice settings');
    }
    final request = http.Request('POST', uri.replace(path: '/v1/voice'))
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      })
      ..body = jsonEncode({
        'audio': base64Encode(audio),
        'context': context,
        'trip_access': tripAccess,
        if (routeSnapshot.isNotEmpty) 'route_snapshot': routeSnapshot,
        if (savedSlots.isNotEmpty) 'saved_slots': savedSlots,
        if (history.isNotEmpty) 'history': history,
      });
    try {
      return await (() async {
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          throw StateError('Gateway HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 4096) {
            throw const FormatException('Oversized response');
          }
        }
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map ||
            value['reply'] is! String ||
            (value['reply'] as String).length > 350 ||
            value['utterance'] is! String ||
            (value['utterance'] as String).length > 160 ||
            !{'none', 'destination_query', 'saved_place', 'read_saved_place'}
                .contains(value['action']) ||
            value['argument'] is! String ||
            (value['argument'] as String).length > 120 ||
            !{
              'none',
              'confirm',
              'cancel',
              'select_one',
              'select_two',
              'select_three'
            }.contains(value['decision'])) {
          throw const FormatException('Invalid voice response');
        }
        return {
          'reply': value['reply'] as String,
          'utterance': value['utterance'] as String,
          'action': value['action'] as String,
          'argument': value['argument'] as String,
          'decision': value['decision'] as String,
        };
      })()
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      cancel();
      rethrow;
    }
  }
}
