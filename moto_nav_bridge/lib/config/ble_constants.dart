/// BLE identifiers — must match the ESP32 navigation display firmware
/// (firmware/esp32_nav_display/esp32_nav_display.ino, "BLE contract").
///
/// The navigation characteristic is write-only and accepts only packets
/// signed by [PacketSigner](../services/packet_signer.dart). A separate
/// read/write pairing characteristic confirms a physical BOOT press, issues
/// the signing key, and reports each connection's session nonce.
class BleConstants {
  const BleConstants._();

  /// Legacy advertised name; current boards advertise NAV-<12 hex digits>.
  static const String deviceName = 'ESP32_NAV';

  static const String serviceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String characteristicUuid =
      'abcd1234-5678-1234-5678-abcdef123456';
  static const String pairingCharacteristicUuid =
      'abcd1234-5678-1234-5678-abcdef123457';

  /// Write with response: the firmware exposes both WRITE and WRITE_NR, and
  /// an acknowledged write lets the drain loop detect failures and retry the
  /// newest state.
  static const bool writeWithoutResponse = false;
}
