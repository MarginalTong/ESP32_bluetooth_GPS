import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/config/ble_constants.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/nav_state.dart';
import 'package:moto_nav_bridge/services/navigation_engine.dart';
import 'package:moto_nav_bridge/services/packet_signer.dart';

void main() {
  // Reference vectors from Python's hmac module; the firmware's host test
  // (firmware/tests/packet_auth_test.cpp) checks the same values.
  final key = Uint8List.fromList(List.generate(16, (i) => i));
  final nonce = Uint8List.fromList(List.generate(8, (i) => 0xa0 + i));

  test('matches the reference tag shared with the firmware', () {
    final signer = PacketSigner(key: key, sessionNonce: nonce);
    expect(signer.sign('{"dir":"LEFT","dist":200}'),
        '{"dir":"LEFT","dist":200,"n":1}|acdb15653d20ac00');
  });

  test('clock packets are signed the same way', () {
    final signer = PacketSigner(key: key, sessionNonce: nonce);
    expect(signer.sign('{"clock":1761200000}'),
        '{"clock":1761200000,"n":1}|2c663afa65eb024b');
  });

  test('the counter increases with every packet', () {
    final signer = PacketSigner(key: key, sessionNonce: nonce);
    signer.sign('{"dir":"UP","dist":10}');
    expect(signer.sign('{"dir":"UP","dist":10}'), contains('"n":2}|'));
  });

  test('a different session nonce changes the tag', () {
    final other = Uint8List.fromList(List.generate(8, (i) => 0xb0 + i));
    final a = PacketSigner(key: key, sessionNonce: nonce)
        .sign('{"dir":"UP","dist":10}');
    final b = PacketSigner(key: key, sessionNonce: other)
        .sign('{"dir":"UP","dist":10}');
    expect(a.split('|').first, b.split('|').first);
    expect(a.split('|').last, isNot(b.split('|').last));
  });

  test('rejects malformed keys, nonces and bodies', () {
    expect(() => PacketSigner(key: Uint8List(15), sessionNonce: nonce),
        throwsArgumentError);
    expect(() => PacketSigner(key: key, sessionNonce: Uint8List(7)),
        throwsArgumentError);
    expect(() => PacketSigner(key: key, sessionNonce: nonce).sign('[]'),
        throwsArgumentError);
  });

  test('the largest navigation packet fits the firmware limit', () {
    // Every field at its widest: four-digit coordinates, all preview points
    // and side roads, rerouting, a 4-digit distance and a huge counter. The
    // firmware drops anything longer, so this must hold for any NavState.
    final widest = NavState(
      direction: DeviceDirection.bearRight,
      distanceMeters: 9999,
      rerouting: true,
      routePreviewPoints:
          List.filled(NavigationEngine.routePreviewMaxPoints * 2, 1270),
      sideRoadPreviewPoints:
          List.filled(NavigationEngine.sideRoadPreviewMaxSegments * 4, 1270),
    );
    final signer = PacketSigner(key: key, sessionNonce: nonce);
    for (var i = 0; i < 999999; i++) {
      signer.sign('{}'); // Push the counter to 7 digits.
    }
    final wire = utf8.encode(signer.sign(widest.toWire()));
    expect(wire.length, lessThanOrEqualTo(BleConstants.maxSignedPacketBytes));
    // And within the 512-byte attribute limit Android enforces.
    expect(wire.length, lessThanOrEqualTo(512));
  });

  test('parses fixed-length hex only', () {
    expect(PacketSigner.parseHex('a0A1a2a3a4a5a6a7', 8), nonce);
    expect(PacketSigner.parseHex('a0a1', 8), isNull);
    expect(PacketSigner.parseHex('zz' * 8, 8), isNull);
    expect(PacketSigner.parseHex(null, 8), isNull);
  });
}
