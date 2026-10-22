/// BLE identifiers — must match the ESP32 navigation display firmware.
///
/// Source of truth is the Arduino sketch:
///   BLEDevice::init("NAV-<chip identity>");
///   #define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
///   #define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"
///   ...createCharacteristic(CHARACTERISTIC_UUID, PROPERTY_WRITE)
///
/// Navigation is write-only; a separate read/write pairing characteristic
/// reports physical BOOT confirmation before the phone saves a new binding.
class BleConstants {
  const BleConstants._();

  /// Legacy advertised name; current boards advertise NAV-<12 hex digits>.
  static const String deviceName = 'ESP32_NAV';

  static const String serviceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String characteristicUuid =
      'abcd1234-5678-1234-5678-abcdef123456';

  /// The firmware exposes PROPERTY_WRITE (write-with-response), so we write
  /// with `withoutResponse: false`.
  static const bool writeWithoutResponse = false;
}
