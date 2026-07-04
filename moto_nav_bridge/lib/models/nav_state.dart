import 'device_direction.dart';

/// The navigation payload sent to the ESP32 over BLE.
///
/// Serializes to exactly `{"dir":"LEFT","dist":200}` — the contract the
/// firmware parses with `doc["dir"]` / `doc["dist"]`. The firmware reads
/// `dist` as an `int`, so [distanceMeters] is emitted without a fractional
/// part. Keep the payload small: the firmware buffer is `StaticJsonDocument<200>`.
class NavState {
  const NavState({
    required this.direction,
    required this.distanceMeters,
  });

  final DeviceDirection direction;

  /// Distance to the next maneuver, in whole meters. Never negative.
  final int distanceMeters;

  /// A safe idle/paused state (matches the firmware's STOP icon).
  static const NavState stopped =
      NavState(direction: DeviceDirection.stop, distanceMeters: 0);

  Map<String, dynamic> toJson() => {
        'dir': direction.wire,
        'dist': distanceMeters,
      };

  /// The exact bytes written to the BLE characteristic.
  /// Uses no whitespace to stay well under the firmware's 200-byte buffer.
  String toWire() => '{"dir":"${direction.wire}","dist":$distanceMeters}';

  NavState copyWith({DeviceDirection? direction, int? distanceMeters}) =>
      NavState(
        direction: direction ?? this.direction,
        distanceMeters: distanceMeters ?? this.distanceMeters,
      );

  @override
  bool operator ==(Object other) =>
      other is NavState &&
      other.direction == direction &&
      other.distanceMeters == distanceMeters;

  @override
  int get hashCode => Object.hash(direction, distanceMeters);

  @override
  String toString() => 'NavState($direction, ${distanceMeters}m)';
}
