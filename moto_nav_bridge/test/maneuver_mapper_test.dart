import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/services/maneuver_mapper.dart';

void main() {
  group('ManeuverMapper.fromGoogle', () {
    // Full Google maneuver vocabulary -> expected device direction.
    const cases = <String, DeviceDirection>{
      'turn-left': DeviceDirection.left,
      'turn-sharp-left': DeviceDirection.left,
      'ramp-left': DeviceDirection.left,
      'turn-right': DeviceDirection.right,
      'turn-sharp-right': DeviceDirection.right,
      'ramp-right': DeviceDirection.right,
      'turn-slight-left': DeviceDirection.bearLeft,
      'fork-left': DeviceDirection.bearLeft,
      'keep-left': DeviceDirection.bearLeft,
      'roundabout-left': DeviceDirection.bearLeft,
      'turn-slight-right': DeviceDirection.bearRight,
      'fork-right': DeviceDirection.bearRight,
      'keep-right': DeviceDirection.bearRight,
      'roundabout-right': DeviceDirection.bearRight,
      'uturn-left': DeviceDirection.uturn,
      'uturn-right': DeviceDirection.uturn,
      'straight': DeviceDirection.up,
      'merge': DeviceDirection.up,
      'ferry': DeviceDirection.up,
      'ferry-train': DeviceDirection.up,
    };

    cases.forEach((maneuver, expected) {
      test('"$maneuver" -> ${expected.wire}', () {
        expect(ManeuverMapper.fromGoogle(maneuver), expected);
      });
    });

    test('null maneuver -> UP', () {
      expect(ManeuverMapper.fromGoogle(null), DeviceDirection.up);
    });

    test('empty maneuver -> UP', () {
      expect(ManeuverMapper.fromGoogle(''), DeviceDirection.up);
    });

    test('unknown maneuver falls back to UP', () {
      expect(ManeuverMapper.fromGoogle('teleport'), DeviceDirection.up);
    });

    test('is case-insensitive and trims whitespace', () {
      expect(ManeuverMapper.fromGoogle('  TURN-LEFT '), DeviceDirection.left);
    });
  });
}
