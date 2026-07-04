/// BLE identifiers — must match the ESP32_NAV firmware exactly.
///
/// Source of truth is the Arduino sketch:
///   BLEDevice::init("ESP32_NAV");
///   #define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
///   #define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"
///   ...createCharacteristic(CHARACTERISTIC_UUID, PROPERTY_WRITE)
///
/// The characteristic is WRITE-only (with response). There is no notify/read
/// channel, so the app cannot receive an application-level ACK from the device.
class BleConstants {
  const BleConstants._();

  /// Advertised device name — used to filter scan results.
  static const String deviceName = 'ESP32_NAV';

  static const String serviceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String characteristicUuid =
      'abcd1234-5678-1234-5678-abcdef123456';

  /// The firmware exposes PROPERTY_WRITE (write-with-response), so we write
  /// with `withoutResponse: false`.
  static const bool writeWithoutResponse = false;
}
