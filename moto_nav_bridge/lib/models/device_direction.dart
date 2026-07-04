/// The navigation directions understood by the ESP32_NAV firmware.
///
/// The `wire` value is the exact string the firmware compares against in its
/// `if (nav.direction == "...")` render chain, so these must match the firmware
/// byte-for-byte. See the ESP32 sketch's `loop()` draw dispatch.
enum DeviceDirection {
  up('UP'),
  left('LEFT'),
  right('RIGHT'),
  bearLeft('BEAR_LEFT'),
  bearRight('BEAR_RIGHT'),
  uturn('UTURN'),
  stop('STOP'),
  arrived('ARRIVED');

  const DeviceDirection(this.wire);

  /// The on-wire token sent in the `"dir"` JSON field.
  final String wire;

  @override
  String toString() => wire;
}
