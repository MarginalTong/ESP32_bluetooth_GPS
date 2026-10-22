import 'dart:typed_data';

import 'packet_signer.dart';

/// The display this phone paired with by a physical BOOT press, and the key
/// the display issued then. Without the key the display ignores every
/// navigation write, so a binding saved before signed packets is invalid.
class DisplayBinding {
  const DisplayBinding(this.remote, this.identity, this.key);
  final String remote;
  final String identity;
  final Uint8List key;

  factory DisplayBinding.fromJson(Map<String, dynamic> data) {
    final remote = data['remote'];
    final identity = data['identity'];
    final key = PacketSigner.parseHex(data['key'], PacketSigner.keyBytes);
    if (remote is! String ||
        remote.isEmpty ||
        identity is! String ||
        !RegExp(r'^[0-9A-F]{12}$').hasMatch(identity) ||
        key == null) {
      throw const FormatException('Invalid saved display binding');
    }
    return DisplayBinding(remote, identity, key);
  }

  Map<String, String> toJson() => {
        'remote': remote,
        'identity': identity,
        'key': key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };

  bool matches(String remoteId, String screenId) =>
      remote == remoteId && identity == screenId;
}
