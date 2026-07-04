import '../models/device_direction.dart';

/// Pure mapping from a Google Directions `maneuver` string to the device
/// protocol direction understood by the ESP32_NAV firmware.
///
/// This is intentionally free of any Flutter/plugin dependency so the protocol
/// contract can be locked down with plain Dart unit tests.
///
/// Google's full maneuver vocabulary (as of the Directions API):
///   turn-slight-left, turn-sharp-left, uturn-left, turn-left,
///   turn-slight-right, turn-sharp-right, uturn-right, turn-right,
///   straight, ramp-left, ramp-right, merge, fork-left, fork-right,
///   ferry, ferry-train, roundabout-left, roundabout-right,
///   keep-left, keep-right
///
/// A step may also have NO maneuver field (typically the first "head ..." step
/// or plain continuations) — that maps to UP (straight ahead).
class ManeuverMapper {
  const ManeuverMapper._();

  /// Maps a raw Google maneuver to a [DeviceDirection].
  ///
  /// [maneuver] may be null/empty (no maneuver on the step). Matching is
  /// case-insensitive and trims surrounding whitespace. Unknown values fall
  /// back to [DeviceDirection.up] so the rider always gets a sane "go straight"
  /// rather than a blank/UNKNOWN screen.
  static DeviceDirection fromGoogle(String? maneuver) {
    final m = (maneuver ?? '').trim().toLowerCase();
    if (m.isEmpty) return DeviceDirection.up;

    switch (m) {
      // Hard u-turns.
      case 'uturn-left':
      case 'uturn-right':
        return DeviceDirection.uturn;

      // Slight/soft lefts and left forks/keeps -> BEAR_LEFT.
      case 'turn-slight-left':
      case 'fork-left':
      case 'keep-left':
      case 'roundabout-left':
        return DeviceDirection.bearLeft;

      // Slight/soft rights and right forks/keeps -> BEAR_RIGHT.
      case 'turn-slight-right':
      case 'fork-right':
      case 'keep-right':
      case 'roundabout-right':
        return DeviceDirection.bearRight;

      // Regular and sharp lefts, plus left on-ramps -> LEFT.
      case 'turn-left':
      case 'turn-sharp-left':
      case 'ramp-left':
        return DeviceDirection.left;

      // Regular and sharp rights, plus right on-ramps -> RIGHT.
      case 'turn-right':
      case 'turn-sharp-right':
      case 'ramp-right':
        return DeviceDirection.right;

      // Straight-ahead continuations.
      case 'straight':
      case 'merge':
      case 'ferry':
      case 'ferry-train':
        return DeviceDirection.up;

      default:
        return DeviceDirection.up;
    }
  }
}
