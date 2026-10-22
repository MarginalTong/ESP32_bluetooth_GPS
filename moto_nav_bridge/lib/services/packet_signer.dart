import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Authenticates every write to the display's navigation characteristic.
///
/// The display only accepts `<json>|<tag>` where the JSON carries a strictly
/// increasing counter `n` and `tag` is the first 8 bytes of
/// HMAC-SHA256(key, sessionNonce ‖ json), in hex. The key is created by the
/// display during a BOOT-confirmed pairing; the nonce is new on every
/// connection, so packets recorded in one session are useless in the next.
///
/// Must match the firmware's PACKET AUTH block byte for byte.
class PacketSigner {
  PacketSigner({required Uint8List key, required Uint8List sessionNonce})
      : _hmac = Hmac(sha256, key),
        _nonce = sessionNonce {
    if (key.length != keyBytes || sessionNonce.length != nonceBytes) {
      throw ArgumentError('Invalid display key or session nonce');
    }
  }

  static const keyBytes = 16;
  static const nonceBytes = 8;
  static const _tagBytes = 8;

  final Hmac _hmac;
  final Uint8List _nonce;
  int _counter = 0;

  /// Adds the next counter to [json] (a compact JSON object) and appends its
  /// tag. Every call consumes a counter value, even if the write later fails.
  String sign(String json) {
    if (!json.startsWith('{') || !json.endsWith('}') || json.length < 2) {
      throw ArgumentError('Expected a JSON object');
    }
    _counter++;
    final separator = json == '{}' ? '' : ',';
    final body =
        '${json.substring(0, json.length - 1)}$separator"n":$_counter}';
    final digest = _hmac.convert([..._nonce, ...utf8.encode(body)]);
    return '$body|${_hex(digest.bytes.sublist(0, _tagBytes))}';
  }

  /// Parses fixed-length lowercase or uppercase hex from the display.
  static Uint8List? parseHex(Object? value, int bytes) {
    if (value is! String ||
        value.length != bytes * 2 ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
      return null;
    }
    return Uint8List.fromList([
      for (var i = 0; i < bytes; i++)
        int.parse(value.substring(i * 2, i * 2 + 2), radix: 16),
    ]);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
