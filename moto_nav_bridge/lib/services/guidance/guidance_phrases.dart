import '../../models/device_direction.dart';
import 'guidance_route.dart';

/// Deterministic announcement templates. Every word comes from a verified
/// maneuver: no road, lane, landmark or exit the route did not name.
class GuidancePhrases {
  const GuidancePhrases({required this.english});

  final bool english;

  /// "前方300米" / "In 300 metres, ", rounded so the number does not jitter.
  String distance(int meters) {
    if (meters >= 1000) {
      final km = (meters / 100).round() / 10;
      final text = km == km.roundToDouble()
          ? km.toStringAsFixed(0)
          : km.toStringAsFixed(1);
      return english ? 'In $text kilometres, ' : '前方$text公里';
    }
    final rounded = meters < 100
        ? ((meters / 10).round() * 10).clamp(10, 100)
        : (meters / 50).round() * 50;
    return english ? 'In $rounded metres, ' : '前方$rounded米';
  }

  /// The action alone, e.g. "左转" / "turn left". [direction] is what the
  /// display shows; [maneuver] adds detail only when it agrees with it.
  String action(DeviceDirection direction, GuidanceManeuver? maneuver) {
    final m = maneuver != null && maneuver.direction == direction
        ? maneuver
        : null;
    final left =
        direction == DeviceDirection.left ||
        direction == DeviceDirection.bearLeft;
    switch (m?.kind) {
      case ManeuverKind.sharpTurn:
        return english
            ? 'make a sharp ${left ? 'left' : 'right'}'
            : '向${left ? '左' : '右'}急转';
      case ManeuverKind.rampStraight:
        return english ? 'take the ramp straight ahead' : '直行进入匝道';
      case ManeuverKind.ramp:
        return english
            ? 'take the ramp on the ${left ? 'left' : 'right'}'
            : '靠${left ? '左' : '右'}进入匝道';
      case ManeuverKind.exit:
        return english
            ? 'take the exit on the ${left ? 'left' : 'right'}'
            : '靠${left ? '左' : '右'}从出口驶出';
      case ManeuverKind.forkStraight:
        return english ? 'keep straight at the fork' : '在岔路保持直行';
      case ManeuverKind.fork:
        return english
            ? 'keep ${left ? 'left' : 'right'} at the fork'
            : '在岔路靠${left ? '左' : '右'}';
      case ManeuverKind.merge:
        return english ? 'merge' : '汇入主路';
      case ManeuverKind.roundaboutEnter:
        final exit = m!.exitCount;
        if (exit == null) return english ? 'enter the roundabout' : '进入环岛';
        return english
            ? 'at the roundabout, take the ${_ordinal(exit)} exit'
            : '进入环岛，从第$exit个出口驶出';
      case ManeuverKind.roundaboutExit:
        return english ? 'exit the roundabout' : '驶出环岛';
      case ManeuverKind.destination:
        return english ? 'arrive at your destination' : '到达目的地';
      default:
        return basic(direction);
    }
  }

  /// The plain display direction, used when maneuver data is missing.
  String basic(DeviceDirection direction) => switch (direction) {
    DeviceDirection.left => english ? 'turn left' : '左转',
    DeviceDirection.right => english ? 'turn right' : '右转',
    DeviceDirection.bearLeft => english ? 'bear left' : '向左前方行驶',
    DeviceDirection.bearRight => english ? 'bear right' : '向右前方行驶',
    DeviceDirection.uturn =>
      english ? 'make a U-turn only where permitted and safe' : '在允许且安全的位置掉头',
    DeviceDirection.arrived => english ? 'arrive at your destination' : '到达目的地',
    _ => english ? 'continue straight' : '继续直行',
  };

  /// "，进入人民路" / " onto King Street" for maneuvers that join a road.
  String onto(GuidanceManeuver? maneuver, DeviceDirection direction) {
    if (maneuver == null || maneuver.direction != direction) return '';
    final name = maneuver.streetName;
    if (name == null) return '';
    const joinsRoad = {
      ManeuverKind.turn,
      ManeuverKind.sharpTurn,
      ManeuverKind.slightTurn,
      ManeuverKind.ramp,
      ManeuverKind.rampStraight,
      ManeuverKind.exit,
      ManeuverKind.fork,
      ManeuverKind.merge,
    };
    if (!joinsRoad.contains(maneuver.kind)) return '';
    return english ? ' onto $name' : '，进入$name';
  }

  /// "，随后立即右转" / ", then immediately turn right".
  String then(GuidanceManeuver next, double gapMeters) {
    final immediately = gapMeters <= 60;
    final action = this.action(next.direction, next);
    if (english) {
      return immediately ? ', then immediately $action' : ', then $action';
    }
    return immediately ? '，随后立即$action' : '，随后$action';
  }

  String sentence(String body) {
    if (!english) return '$body。';
    final text = body.trimLeft();
    if (text.isEmpty) return text;
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }

  String get rerouting =>
      english ? 'Off route. Finding a new route.' : '已偏离路线，正在重新规划。';
  String get rerouteFailed => english
      ? 'Could not find a new route yet. Retrying.'
      : '暂时无法重新规划路线，正在重试。';
  String get arrived => english ? 'You have arrived.' : '已到达目的地。';
  String get curves => english
      ? 'Series of sharp bends ahead. Watch the road.'
      : '前方连续急弯，请注意道路变化。';

  static String _ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    return switch (n % 10) {
      1 => '${n}st',
      2 => '${n}nd',
      3 => '${n}rd',
      _ => '${n}th',
    };
  }
}
