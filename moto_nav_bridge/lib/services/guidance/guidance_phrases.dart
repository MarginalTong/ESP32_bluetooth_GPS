import '../../models/device_direction.dart';
import '../../models/lane_guidance.dart';
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
        return switch (m!.arrivalSide) {
          null => english ? 'arrive at your destination' : '到达目的地',
          final side =>
            english
                ? 'arrive at your destination, on the ${_side(side)}'
                : '到达目的地，目的地在您${_side(side)}手边',
        };
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

  /// Which lanes to take, e.g. "走右侧两条车道" / ", using the right two
  /// lanes"; empty without lane data or when it is for another maneuver.
  String lanes(GuidanceManeuver? maneuver, DeviceDirection direction) {
    final lanes = maneuver != null && maneuver.direction == direction
        ? maneuver.lanes
        : null;
    if (lanes == null) return '';
    final text = english ? _lanesEnglish(lanes) : _lanesChinese(lanes);
    return english ? ', using $text' : '走$text';
  }

  /// One maneuver with its road and lanes, in each language's word order:
  /// "走右侧车道右转，进入人民路" / "turn right onto King Street, using the
  /// right lane".
  String clause(String action, String onto, String lanes) =>
      english ? '$action$onto$lanes' : '$lanes$action$onto';

  String _lanesChinese(LaneGuidance lanes) {
    final k = lanes.count;
    final run = k == 1 ? '车道' : '${_chineseCount(k)}条车道';
    if (lanes.fromRight == 0) return k == 1 ? '最右侧车道' : '右侧$run';
    if (lanes.fromLeft == 0) return k == 1 ? '最左侧车道' : '左侧$run';
    if (lanes.fromLeft == lanes.fromRight) return '中间$run';
    final (side, offset) = _nearerEdge(lanes);
    final from = side == RoadSide.right ? '右数' : '左数';
    final a = _chineseNumber(offset + 1);
    if (k == 1) return '$from第$a条车道';
    return '$from第$a到第${_chineseNumber(offset + k)}条车道';
  }

  String _lanesEnglish(LaneGuidance lanes) {
    final k = lanes.count;
    final run = k == 1 ? 'lane' : '${_englishCount(k)} lanes';
    if (lanes.fromRight == 0) return 'the right $run';
    if (lanes.fromLeft == 0) return 'the left $run';
    if (lanes.fromLeft == lanes.fromRight) return 'the middle $run';
    final (side, offset) = _nearerEdge(lanes);
    final from = 'from the ${_side(side)}';
    if (k == 1) return 'the ${_englishOrdinal(offset + 1)} lane $from';
    return 'lanes ${offset + 1} to ${offset + k} $from';
  }

  /// Counted from the closer edge, so the rider has fewer lanes to count.
  static (RoadSide, int) _nearerEdge(LaneGuidance lanes) =>
      lanes.fromRight < lanes.fromLeft
      ? (RoadSide.right, lanes.fromRight)
      : (RoadSide.left, lanes.fromLeft);

  String _side(RoadSide side) => english
      ? (side == RoadSide.left ? 'left' : 'right')
      : (side == RoadSide.left ? '左' : '右');

  // Lane numbers stay within LaneGuidance.maxLanes.
  static String _chineseNumber(int n) => '零一二三四五六七八'[n];
  static String _chineseCount(int n) => n == 2 ? '两' : _chineseNumber(n);
  static String _englishCount(int n) =>
      const ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven'][n];
  static String _englishOrdinal(int n) => const [
    '',
    'first',
    'second',
    'third',
    'fourth',
    'fifth',
    'sixth',
    'seventh',
    'eighth',
  ][n];

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
  String arrived(RoadSide? side) => switch (side) {
    null => english ? 'You have arrived.' : '已到达目的地。',
    final side =>
      english
          ? 'You have arrived. Your destination is on the ${_side(side)}.'
          : '已到达目的地，目的地在您${_side(side)}手边。',
  };
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
